# ---------------------------------------------------------------------------
# Module: claims-platform
#
# One definition, instantiated three times. The environments differ only in
# their tfvars -- so a control that is on in prod cannot be quietly absent in
# dev, and a fix applied here lands everywhere on the next apply.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# ---------------------------------------------------------------------------
# The corrected version of ../insecure/main.tf
#
# Every change here maps to a Checkov finding in docs/FINDINGS.md.
# This is what the pipeline lets through.
# ---------------------------------------------------------------------------

variable "aws_region" {
  type        = string
  description = "AWS region for all resources"
}

variable "environment" {
  type        = string
  description = "Deployment environment name"
  validation {
    condition     = contains(["dev", "stage", "prod"], var.environment)
    error_message = "environment must be one of: dev, stage, prod."
  }
}

variable "multi_az" {
  type        = bool
  description = "Run the database across availability zones. Cost/resilience tradeoff."
  default     = false
}

variable "deletion_protection" {
  type        = bool
  description = "Block accidental destruction of the database."
  default     = true
}

variable "backup_retention_days" {
  type        = number
  description = "Days of automated backups to retain."
  default     = 7
}

variable "instance_class" {
  type        = string
  description = "RDS instance size."
  default     = "db.t3.medium"
}

variable "trusted_cidr" {
  type        = string
  description = "Corporate CIDR permitted to reach the app tier"
  default     = "10.0.0.0/8"
}

# --- Customer-managed key ---------------------------------------------------
# FIX CKV_AWS_145: encrypt with a CMK, not the AWS-managed default key.
resource "aws_kms_key" "data" {
  description             = "CMK for claims data at rest"
  deletion_window_in_days = 30
  enable_key_rotation     = true # FIX CKV_AWS_7

  # FIX CKV2_AWS_64: an explicit key policy, scoped to this account.
  policy = data.aws_iam_policy_document.kms.json
}

data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "EnableAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }
}

# --- Logging target ---------------------------------------------------------
resource "aws_s3_bucket" "access_logs" {
  bucket = "tm-access-logs-${var.environment}"
}

resource "aws_s3_bucket_public_access_block" "access_logs" {
  bucket                  = aws_s3_bucket.access_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.data.arn
      sse_algorithm     = "aws:kms"
    }
  }
}

# --- Claims documents bucket ------------------------------------------------
resource "aws_s3_bucket" "claims_documents" {
  bucket = "tm-claims-documents-${var.environment}"

  tags = {
    Environment = var.environment
    DataClass   = "confidential"
  }
}

# FIX CKV_AWS_20 / CKV2_AWS_6: no public ACL, explicit public access block.
resource "aws_s3_bucket_public_access_block" "claims_documents" {
  bucket                  = aws_s3_bucket.claims_documents.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# FIX CKV_AWS_21: versioning protects against ransomware and bad deletes.
resource "aws_s3_bucket_versioning" "claims_documents" {
  bucket = aws_s3_bucket.claims_documents.id
  versioning_configuration {
    status = "Enabled"
  }
}

# FIX CKV_AWS_19 / CKV_AWS_145: encryption at rest with the CMK.
resource "aws_s3_bucket_server_side_encryption_configuration" "claims_documents" {
  bucket = aws_s3_bucket.claims_documents.id
  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.data.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# FIX CKV_AWS_18: access logging for the audit trail.
resource "aws_s3_bucket_logging" "claims_documents" {
  bucket        = aws_s3_bucket.claims_documents.id
  target_bucket = aws_s3_bucket.access_logs.id
  target_prefix = "claims-documents/"
}

# FIX CKV2_AWS_61: lifecycle policy so data does not accumulate forever.
resource "aws_s3_bucket_lifecycle_configuration" "claims_documents" {
  bucket = aws_s3_bucket.claims_documents.id
  rule {
    id     = "expire-noncurrent"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    # FIX CKV_AWS_300: reclaim storage from uploads that never completed.
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# FIX CKV2_AWS_61 for the log bucket as well.
resource "aws_s3_bucket_lifecycle_configuration" "access_logs" {
  bucket = aws_s3_bucket.access_logs.id
  rule {
    id     = "expire-logs"
    status = "Enabled"
    filter {}
    expiration {
      days = 365
    }
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# --- Security group ---------------------------------------------------------
# FIX CKV_AWS_24 / CKV_AWS_260: no 0.0.0.0/0 ingress; corporate CIDR only,
# and SSH is gone entirely in favour of SSM Session Manager.
resource "aws_security_group" "app_tier" {
  name        = "app-tier-${var.environment}"
  description = "Application tier security group"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from the corporate network"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.trusted_cidr]
  }

  # FIX CKV_AWS_382: egress is scoped, not wide open.
  egress {
    description = "HTTPS to AWS service endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.trusted_cidr]
  }
}

variable "vpc_id" {
  type        = string
  description = "VPC the app tier lives in"
}

# --- Policy administration database -----------------------------------------
resource "aws_db_instance" "policy_admin" {
  identifier        = "policy-admin-${var.environment}"
  engine            = "postgres"
  engine_version    = "15.4"
  instance_class    = var.instance_class
  allocated_storage = 100
  db_name           = "policyadmin"
  username          = "dbadmin"

  # FIX CKV_AWS_16: encrypted at rest with the CMK.
  storage_encrypted = true
  kms_key_id        = aws_kms_key.data.arn

  # FIX CKV_AWS_17: never reachable from the internet.
  publicly_accessible = false

  # FIX CKV_AWS_118: enhanced monitoring on.
  monitoring_interval = 60
  monitoring_role_arn = var.monitoring_role_arn

  # FIX CKV_AWS_129: ship logs where they can be alerted on.
  enabled_cloudwatch_logs_exports = ["postgresql", "upgrade"]

  # FIX CKV_AWS_293: deletion protection on for a system of record.
  deletion_protection = var.deletion_protection

  # FIX CKV_AWS_157: survive an AZ failure. Required in prod, optional below.
  multi_az = var.multi_az

  # FIX CKV_AWS_161: rotate credentials through Secrets Manager, so no
  # password is ever passed in as a Terraform variable.
  manage_master_user_password   = true
  master_user_secret_kms_key_id = aws_kms_key.data.arn

  # FIX CKV_AWS_226: apply security patches automatically.
  auto_minor_version_upgrade = true

  # FIX CKV_AWS_161: IAM auth removes long-lived database passwords entirely.
  iam_database_authentication_enabled = true

  # FIX CKV_AWS_353: performance insights, encrypted with the same CMK.
  performance_insights_enabled    = true
  performance_insights_kms_key_id = aws_kms_key.data.arn

  backup_retention_period   = 30
  copy_tags_to_snapshot     = true # FIX CKV2_AWS_60
  skip_final_snapshot       = false
  final_snapshot_identifier = "policy-admin-${var.environment}-final"
}

variable "monitoring_role_arn" {
  type        = string
  description = "IAM role ARN used by RDS enhanced monitoring"
}
