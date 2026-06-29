# variables.tf
# Input variables for the sovereign-rag bootstrap.
# Values should be provided via a .tfvars file or environment variables.
# Never commit actual values to git.

variable "aws_region" {
  description = "AWS region where the RHOAI cluster is deployed"
  type        = string
}

variable "cluster_name" {
  description = "Name of the OpenShift cluster — used for resource tagging"
  type        = string
}

variable "environment" {
  description = "Environment label — e.g. presales-lab, demo, poc"
  type        = string
  default     = "presales-lab"
}

variable "minio_storage_size_gi" {
  description = "Storage size in GiB for MinIO PVCs — Granite 3.1 8B needs ~20Gi minimum"
  type        = number
  default     = 50
}
