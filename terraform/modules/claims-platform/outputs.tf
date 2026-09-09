output "claims_bucket" {
  description = "Name of the claims document bucket"
  value       = aws_s3_bucket.claims_documents.id
}

output "database_endpoint" {
  description = "Connection endpoint for the policy administration database"
  value       = aws_db_instance.policy_admin.endpoint
  sensitive   = true
}

output "kms_key_arn" {
  description = "ARN of the CMK protecting data at rest"
  value       = aws_kms_key.data.arn
}
