output "state_bucket_name" {
  description = "S3 bucket used for Terraform remote state"
  value       = aws_s3_bucket.terraform_state.bucket
}

output "state_key" {
  description = "Key for the main stack state"
  value       = "sundevs/terraform.tfstate"
}