output "api_url" {
  description = "URL del endpoint POST /process"
  value       = "https://${aws_api_gateway_rest_api.main.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_api_gateway_stage.prod.stage_name}/process"
}

output "s3_bucket" {
  description = "Bucket de resultados"
  value       = aws_s3_bucket.results.id
}

output "lambda_function_name" {
  description = "Nombre de la Lambda (para ver logs)"
  value       = aws_lambda_function.processor.function_name
}

output "redis_endpoint" {
  description = "Endpoint primario de Redis"
  value       = aws_elasticache_replication_group.redis.primary_endpoint_address
}

output "redis_secret_arn" {
  description = "ARN del secreto con el auth token (el valor no se expone)"
  value       = aws_secretsmanager_secret.redis.arn
}
