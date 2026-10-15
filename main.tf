data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_partition" "current" {}

locals {
  name = var.project_name
  azs  = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets = {
    a = { cidr = "10.20.1.0/24", az = local.azs[0] }
    b = { cidr = "10.20.2.0/24", az = local.azs[1] }
  }

  private_subnets = {
    a = { cidr = "10.20.11.0/24", az = local.azs[0] }
    b = { cidr = "10.20.12.0/24", az = local.azs[1] }
  }
}

# ============================================================
# VPC y red
# ============================================================
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  for_each                = local.public_subnets
  vpc_id                  = aws_vpc.main.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name}-public-${each.key}" }
}

resource "aws_subnet" "private" {
  for_each          = local.private_subnets
  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value.cidr
  availability_zone = each.value.az
  tags              = { Name = "${local.name}-private-${each.key}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-public-rt" }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public["a"].id
  depends_on    = [aws_internet_gateway.main]
  tags          = { Name = "${local.name}-nat" }
}

resource "aws_route_table" "private" {
  for_each = local.private_subnets
  vpc_id   = aws_vpc.main.id
  tags     = { Name = "${local.name}-private-rt-${each.key}" }
}

resource "aws_route" "private_nat" {
  for_each               = aws_route_table.private
  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# VPC Endpoint Gateway S3 + policy: solo PutObject sobre results/*
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowPutResultsOnly"
      Effect    = "Allow"
      Principal = "*"
      Action    = ["s3:PutObject"]
      Resource  = "${aws_s3_bucket.results.arn}/results/*"
    }]
  })

  tags = { Name = "${local.name}-s3-endpoint" }
}

# VPC Endpoint Interface para Secrets Manager (Lambda lee el token sin salir a internet)
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = aws_vpc.main.id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for s in aws_subnet.private : s.id]
  security_group_ids  = [aws_security_group.secrets_endpoint.id]
  private_dns_enabled = true
  tags                = { Name = "${local.name}-secretsmanager-endpoint" }
}

# ============================================================
# Security Groups (mínimo privilegio)
# ============================================================
resource "aws_security_group" "lambda" {
  name                   = "${local.name}-lambda-sg"
  description            = "Lambda: egress solo a Redis, S3 endpoint y Secrets Manager endpoint"
  vpc_id                 = aws_vpc.main.id
  revoke_rules_on_delete = true
  tags                   = { Name = "${local.name}-lambda-sg" }
}

resource "aws_security_group" "redis" {
  name                   = "${local.name}-redis-sg"
  description            = "Redis acepta conexiones solo desde el SG de Lambda"
  vpc_id                 = aws_vpc.main.id
  revoke_rules_on_delete = true
  tags                   = { Name = "${local.name}-redis-sg" }
}

resource "aws_security_group" "secrets_endpoint" {
  name                   = "${local.name}-secrets-endpoint-sg"
  description            = "Endpoint de Secrets Manager accesible solo desde Lambda"
  vpc_id                 = aws_vpc.main.id
  revoke_rules_on_delete = true
  tags                   = { Name = "${local.name}-secrets-endpoint-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "redis_from_lambda" {
  security_group_id            = aws_security_group.redis.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  description                  = "Redis TLS desde Lambda unicamente"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_redis" {
  security_group_id            = aws_security_group.lambda.id
  referenced_security_group_id = aws_security_group.redis.id
  ip_protocol                  = "tcp"
  from_port                    = 6379
  to_port                      = 6379
  description                  = "Lambda hacia Redis unicamente"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_s3" {
  security_group_id = aws_security_group.lambda.id
  prefix_list_id    = aws_vpc_endpoint.s3.prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "HTTPS a S3 via Gateway endpoint"
}

resource "aws_vpc_security_group_egress_rule" "lambda_to_secrets_endpoint" {
  security_group_id            = aws_security_group.lambda.id
  referenced_security_group_id = aws_security_group.secrets_endpoint.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS al endpoint de Secrets Manager unicamente"
}

resource "aws_vpc_security_group_ingress_rule" "secrets_from_lambda" {
  security_group_id            = aws_security_group.secrets_endpoint.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "Endpoint acepta solo Lambda"
}

# ============================================================
# S3
# ============================================================
resource "aws_s3_bucket" "results" {
  bucket_prefix = "${local.name}-results-"
  force_destroy = var.bucket_force_destroy
  tags          = { Name = "${local.name}-results" }
}

resource "aws_s3_bucket_public_access_block" "results" {
  bucket                  = aws_s3_bucket.results.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "results" {
  bucket = aws_s3_bucket.results.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "results" {
  bucket = aws_s3_bucket.results.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_policy" "results" {
  bucket = aws_s3_bucket.results.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.results.arn, "${aws_s3_bucket.results.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      },
      {
        Sid       = "AllowLambdaWriteResults"
        Effect    = "Allow"
        Principal = { AWS = aws_iam_role.lambda.arn }
        Action    = ["s3:PutObject"]
        Resource  = "${aws_s3_bucket.results.arn}/results/*"
      },
      {
        # Solo el rol de Lambda admins explícitos pueden operar objetos
        Sid       = "DenyObjectAccessOutsideLambdaRole"
        Effect    = "Deny"
        Principal = "*"
        Action = [
          "s3:GetObject", "s3:GetObjectVersion",
          "s3:PutObject",
          "s3:DeleteObject", "s3:DeleteObjectVersion"
        ]
        Resource = "${aws_s3_bucket.results.arn}/*"
        Condition = {
          ArnNotEquals = {
            "aws:PrincipalArn" = concat([aws_iam_role.lambda.arn], var.admin_principal_arns)
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.results]
}

# ============================================================
# IAM Lambda
# ============================================================
resource "aws_iam_role" "lambda" {
  name = "${local.name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

resource "aws_iam_role_policy" "lambda_s3" {
  name = "${local.name}-s3-write-results"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["s3:PutObject"]
      Resource = "${aws_s3_bucket.results.arn}/results/*"
    }]
  })
}

resource "aws_iam_role_policy" "lambda_read_redis_secret" {
  name = "${local.name}-read-redis-secret"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.redis.arn
    }]
  })
}

# ============================================================
# Secreto de Redis (Secrets Manager)
# ============================================================
resource "random_password" "redis" {
  length      = 32
  special     = false
  min_lower   = 1
  min_upper   = 1
  min_numeric = 1
}

resource "aws_secretsmanager_secret" "redis" {
  name                    = "${local.name}/redis/auth-token"
  description             = "Auth token de ElastiCache Redis"
  recovery_window_in_days = var.secret_recovery_days
  tags                    = { Name = "${local.name}-redis-secret" }
}

resource "aws_secretsmanager_secret_version" "redis" {
  secret_id     = aws_secretsmanager_secret.redis.id
  secret_string = random_password.redis.result
}

# ============================================================
# ElastiCache Redis
# ============================================================
  resource "aws_elasticache_subnet_group" "redis" {
    name       = "${local.name}-redis-subnet-group"
    subnet_ids = [for s in aws_subnet.private : s.id]
    tags       = { Name = "${local.name}-redis-subnet-group" }
  }

  resource "aws_elasticache_replication_group" "redis" {
    replication_group_id = "${local.name}-redis"
    description          = "Redis privado con TLS y auth token"
    engine               = "redis"
    node_type            = var.redis_node_type
    num_cache_clusters   = 2
    port                 = 6379
    subnet_group_name    = aws_elasticache_subnet_group.redis.name
    security_group_ids   = [aws_security_group.redis.id]

    automatic_failover_enabled = true
    multi_az_enabled           = true

    transit_encryption_enabled = true
    at_rest_encryption_enabled = true
    auth_token                 = random_password.redis.result
    apply_immediately          = true

    tags = { Name = "${local.name}-redis-cluster" }
  }

# ============================================================
# Lambda
# ============================================================
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/lambda_function.zip"
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${local.name}-processor"
  retention_in_days = var.log_retention_days
}

resource "aws_lambda_function" "processor" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${local.name}-processor"
  role             = aws_iam_role.lambda.arn
  handler          = "handler.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.11"
  timeout          = var.lambda_timeout
  memory_size      = var.lambda_memory_size

  vpc_config {
    subnet_ids         = [for s in aws_subnet.private : s.id]
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      REDIS_HOST        = aws_elasticache_replication_group.redis.primary_endpoint_address
      REDIS_PORT        = "6379"
      REDIS_SECRET_ARN  = aws_secretsmanager_secret.redis.arn # el token ya NO va en env vars
      S3_BUCKET         = aws_s3_bucket.results.id
      REDIS_TTL_SECONDS = tostring(var.redis_ttl_seconds)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.lambda,
    aws_iam_role_policy_attachment.lambda_logs,
    aws_iam_role_policy_attachment.lambda_vpc,
    aws_iam_role_policy.lambda_s3,
    aws_iam_role_policy.lambda_read_redis_secret,
    aws_vpc_endpoint.secretsmanager,
    aws_vpc_endpoint.s3,
  ]

  tags = { Name = "${local.name}-lambda" }
}

# ============================================================
# API Gateway (REST API) + CORS + logs + throttling
# ============================================================
resource "aws_api_gateway_rest_api" "main" {
  name        = "${local.name}-api"
  description = "API REST de entrada para el servicio de procesamiento"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "process" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "process"
}

resource "aws_api_gateway_method" "process_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.process.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.main.id
  resource_id             = aws_api_gateway_resource.process.id
  http_method             = aws_api_gateway_method.process_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.processor.invoke_arn
}


resource "aws_api_gateway_method" "options" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.process.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "options_mock" {
  rest_api_id       = aws_api_gateway_rest_api.main.id
  resource_id       = aws_api_gateway_resource.process.id
  http_method       = aws_api_gateway_method.options.http_method
  type              = "MOCK"
  request_templates = { "application/json" = "{\"statusCode\": 200}" }
}

resource "aws_api_gateway_method_response" "options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.process.id
  http_method = aws_api_gateway_method.options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "options_200" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.process.id
  http_method = aws_api_gateway_method.options.http_method
  status_code = aws_api_gateway_method_response.options_200.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,X-Amz-Date,X-Api-Key'"
    "method.response.header.Access-Control-Allow-Methods" = "'OPTIONS,POST'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [aws_api_gateway_integration.options_mock]
}

# Rol global de la cuenta para que API Gateway escriba en CloudWatch, si es por primera vez
resource "aws_iam_role" "api_gw_logs" {
  name = "${local.name}-api-gw-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "api_gw_logs" {
  role       = aws_iam_role.api_gw_logs.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.api_gw_logs.arn
  depends_on          = [aws_iam_role_policy_attachment.api_gw_logs]
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "API-Gateway-Access-Logs-${local.name}"
  retention_in_days = var.log_retention_days
}


resource "aws_cloudwatch_log_group" "api_gw_execution" {
  name              = "API-Gateway-Execution-Logs_${aws_api_gateway_rest_api.main.id}/prod"
  retention_in_days = var.log_retention_days
}

resource "aws_api_gateway_deployment" "main" {
  rest_api_id = aws_api_gateway_rest_api.main.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.process.id,
      aws_api_gateway_method.process_post.id,
      aws_api_gateway_integration.lambda_integration.id,
      aws_api_gateway_method.options.id,
      aws_api_gateway_integration.options_mock.id,
      aws_api_gateway_method_response.options_200.id,
      aws_api_gateway_integration_response.options_200.id,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.lambda_integration,
    aws_api_gateway_integration_response.options_200,
  ]
}

resource "aws_api_gateway_stage" "prod" {
  deployment_id = aws_api_gateway_deployment.main.id
  rest_api_id   = aws_api_gateway_rest_api.main.id
  stage_name    = "prod"

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceIp       = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      responseLength = "$context.responseLength"
    })
  }

  depends_on = [
    aws_api_gateway_account.main,
    aws_cloudwatch_log_group.api_gw_execution,
  ]
}

resource "aws_api_gateway_method_settings" "throttling" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = aws_api_gateway_stage.prod.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.api_throttle_rate
    throttling_burst_limit = var.api_throttle_burst
    logging_level          = "INFO"
    data_trace_enabled     = false 
    metrics_enabled        = true
  }
}

resource "aws_lambda_permission" "api_gw" {
  statement_id  = "AllowAPIGatewayInvokeProcessProd"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.main.execution_arn}/prod/POST/process"
}
