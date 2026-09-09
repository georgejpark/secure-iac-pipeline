# ---------------------------------------------------------------------------
# Environment: stage
# Pre-production. Mirrors prod's SECURITY posture exactly; differs
# only in scale. A control absent here is a control untested.
#
# This root is deliberately thin. All resources live in the shared module, so
# the three environments cannot drift apart in their security posture -- only
# in the knobs exposed as variables below.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # State is remote, encrypted, and locked. Commented out so the repository can
  # be planned without a real AWS account; uncomment on first real use.
  # backend "s3" {
  #   bucket         = "tm-terraform-state-stage"
  #   key            = "claims-platform/stage/terraform.tfstate"
  #   region         = "us-east-2"
  #   encrypt        = true
  #   dynamodb_table = "tm-terraform-locks"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Environment = "stage"
      ManagedBy   = "terraform"
      Repository  = "secure-iac-pipeline"
      DataClass   = "confidential"
    }
  }
}

variable "aws_region" {
  type        = string
  description = "AWS region for this environment"
  default     = "us-east-2"
}

variable "vpc_id" {
  type        = string
  description = "VPC the platform is deployed into"
}

variable "monitoring_role_arn" {
  type        = string
  description = "IAM role ARN used by RDS enhanced monitoring"
}

module "claims_platform" {
  source = "../../modules/claims-platform"

  environment         = "stage"
  aws_region          = var.aws_region
  vpc_id              = var.vpc_id
  monitoring_role_arn = var.monitoring_role_arn
  trusted_cidr        = "10.20.0.0/16"

  multi_az              = true
  deletion_protection   = true
  backup_retention_days = 14
  instance_class        = "db.t3.large"
}

output "claims_bucket" {
  description = "Name of the claims document bucket"
  value       = module.claims_platform.claims_bucket
}

output "kms_key_arn" {
  description = "ARN of the CMK protecting data at rest"
  value       = module.claims_platform.kms_key_arn
}
