aws_region   = "us-east-1"
project_name = "sre-challenge"
vpc_cidr     = "10.20.0.0/16"

redis_node_type   = "cache.t3.micro"
redis_ttl_seconds = 60

lambda_timeout     = 15
lambda_memory_size = 256

api_throttle_rate  = 100
api_throttle_burst = 50

log_retention_days = 3


secret_recovery_days = 0
bucket_force_destroy = true
admin_principal_arns = ["arn:aws:iam::xxxxxxxxxxx:user/xxxxxxxx"]
