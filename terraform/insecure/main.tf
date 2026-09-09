# ---------------------------------------------------------------------------
# DEMO: This file contains DELIBERATE misconfigurations.
# It exists so the security pipeline has something real to catch.
# The corrected version lives in ../secure/main.tf
#
# Every finding below is a real Checkov policy ID, listed in docs/FINDINGS.md
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

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-2"
}

variable "environment" {
  description = "Deployment environment name"
  type        = string
  default     = "dev"
}

# --- Finding 1: claims documents bucket -------------------------------------
# CKV_AWS_19  no server-side encryption
# CKV_AWS_21  no versioning
# CKV_AWS_18  no access logging
# CKV_AWS_145 not encrypted with KMS CMK
resource "aws_s3_bucket" "claims_documents" {
  bucket = "tm-claims-documents-${var.environment}"

  tags = {
    Environment = var.environment
    DataClass   = "confidential"
  }
}

# CKV_AWS_20  bucket allows public read
resource "aws_s3_bucket_acl" "claims_documents" {
  bucket = aws_s3_bucket.claims_documents.id
  acl    = "public-read"
}

# --- Finding 2: security group ----------------------------------------------
# CKV_AWS_24  SSH open to the world
# CKV_AWS_260 HTTP open to the world on port 80
resource "aws_security_group" "app_tier" {
  name        = "app-tier-${var.environment}"
  description = "Application tier security group"

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# --- Finding 3: policy administration database ------------------------------
# CKV_AWS_16   storage not encrypted
# CKV_AWS_17   publicly accessible
# CKV_AWS_118  enhanced monitoring disabled
# CKV_AWS_129  no CloudWatch log exports
# CKV_AWS_293  deletion protection disabled
resource "aws_db_instance" "policy_admin" {
  identifier          = "policy-admin-${var.environment}"
  engine              = "postgres"
  engine_version      = "15.4"
  instance_class      = "db.t3.medium"
  allocated_storage   = 100
  db_name             = "policyadmin"
  username            = "dbadmin"
  password            = var.db_password
  publicly_accessible = true
  storage_encrypted   = false
  skip_final_snapshot = true
}

variable "db_password" {
  description = "Database master password, supplied at apply time"
  type        = string
  sensitive   = true
}
