# main.tf
# Bootstrap for sovereign-rag on AWS-hosted RHOAI.
#
# Scope is deliberately narrow — the RHOAI cluster itself is assumed to be
# already provisioned (e.g. via ROSA). This module handles only the AWS-side
# prerequisites needed to support the use case.
#
# What this creates:
#   - IAM user for programmatic access (Ansible seeding, optional S3 tiering)
#   - IAM policy scoped to the minimum required permissions
#   - SSM parameters to store credentials for retrieval by Ansible
#
# What this deliberately does NOT create:
#   - The RHOAI/ROSA cluster (assumed pre-provisioned)
#   - MinIO itself (managed by OpenShift GitOps + MinIO Operator)
#   - S3 buckets (MinIO is the object store — no native S3 buckets needed)

terraform {
  required_version = ">= 1.6.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Remote state — recommended for any shared or repeatable environment.
  # Comment out for purely local runs.
  # backend "s3" {
  #   bucket = "your-tfstate-bucket"
  #   key    = "sovereign-rag/terraform.tfstate"
  #   region = "us-east-1"
  # }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "rhoai-presales-lab"
      UseCase     = "sovereign-rag"
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}

# ---------------------------------------------------------------------------
# IAM — scoped user for Ansible post-deploy tasks
# In a production scenario this would be an IAM role + IRSA.
# For a disposable demo environment, a scoped IAM user is pragmatic.
# ---------------------------------------------------------------------------

resource "aws_iam_user" "minio_admin" {
  name = "${var.cluster_name}-minio-admin"
  path = "/presales-lab/"
}

resource "aws_iam_access_key" "minio_admin" {
  user = aws_iam_user.minio_admin.name
}

resource "aws_iam_user_policy" "minio_admin" {
  name = "${var.cluster_name}-minio-admin-policy"
  user = aws_iam_user.minio_admin.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Scoped only to what Ansible needs for post-deploy configuration.
        # MinIO itself handles object storage — no S3 permissions needed here.
        Sid    = "AllowSSMParameterAccess"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:PutParameter"
        ]
        Resource = "arn:aws:ssm:${var.aws_region}:*:parameter/presales-lab/${var.cluster_name}/*"
      }
    ]
  })
}

# ---------------------------------------------------------------------------
# SSM Parameter Store — credential storage for Ansible consumption
# Ansible retrieves these at runtime; nothing sensitive in the repo.
# ---------------------------------------------------------------------------

resource "aws_ssm_parameter" "minio_access_key" {
  name        = "/presales-lab/${var.cluster_name}/minio/access-key"
  description = "MinIO admin access key for post-deploy Ansible tasks"
  type        = "SecureString"
  value       = "CHANGEME_ON_FIRST_APPLY" # Ansible rotates this post-deploy

  lifecycle {
    ignore_changes = [value] # Ansible owns the value after initial creation
  }
}

resource "aws_ssm_parameter" "minio_secret_key" {
  name        = "/presales-lab/${var.cluster_name}/minio/secret-key"
  description = "MinIO admin secret key for post-deploy Ansible tasks"
  type        = "SecureString"
  value       = "CHANGEME_ON_FIRST_APPLY"

  lifecycle {
    ignore_changes = [value]
  }
}

resource "aws_ssm_parameter" "minio_endpoint" {
  name        = "/presales-lab/${var.cluster_name}/minio/endpoint"
  description = "MinIO service endpoint — populated after GitOps deployment"
  type        = "String"
  value       = "POPULATED_BY_GITOPS"

  lifecycle {
    ignore_changes = [value]
  }
}
