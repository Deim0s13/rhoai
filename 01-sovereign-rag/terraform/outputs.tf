# outputs.tf
# Values surfaced after terraform apply.
# Used to inform the GitOps and Ansible layers.

output "iam_user_name" {
  description = "IAM user created for Ansible post-deploy tasks"
  value       = aws_iam_user.minio_admin.name
}

output "ssm_parameter_prefix" {
  description = "SSM parameter path prefix — reference this in Ansible inventory"
  value       = "/presales-lab/${var.cluster_name}"
}

output "aws_region" {
  description = "AWS region — pass to Ansible for SSM retrieval"
  value       = var.aws_region
}

# Access key output is marked sensitive — will not display in plan output
# Retrieve with: terraform output -raw minio_access_key_id
output "minio_access_key_id" {
  description = "Access key ID for the MinIO admin IAM user"
  value       = aws_iam_access_key.minio_admin.id
  sensitive   = true
}

output "minio_secret_access_key" {
  description = "Secret access key for the MinIO admin IAM user"
  value       = aws_iam_access_key.minio_admin.secret
  sensitive   = true
}
