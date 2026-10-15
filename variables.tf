variable "aws_region" {
  description = "Región de AWS donde se despliega el stack"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Prefijo para nombrar todos los recursos"
  type        = string
  default     = "sre-challenge"
}

variable "vpc_cidr" {
  description = "CIDR de la VPC (las subnets de main.tf asumen 10.20.0.0/16)"
  type        = string
  default     = "10.20.0.0/16"
}

# ---------------- Redis ----------------
variable "redis_node_type" {
  description = "Tipo de nodo ElastiCache"
  type        = string
  default     = "cache.t3.micro"
}

variable "redis_ttl_seconds" {
  description = "TTL de las keys en Redis"
  type        = number
  default     = 60

  validation {
    condition     = var.redis_ttl_seconds > 0
    error_message = "El TTL debe ser mayor a 0: no se permiten keys sin expiración."
  }
}

# ---------------- Lambda ----------------
variable "lambda_timeout" {
  description = "Timeout de Lambda en segundos"
  type        = number
  default     = 15
}

variable "lambda_memory_size" {
  description = "Memoria de Lambda en MB"
  type        = number
  default     = 256
}

# ---------------- API Gateway ----------------
variable "api_throttle_rate" {
  description = "Rate limit del stage (req/s)"
  type        = number
  default     = 100
}

variable "api_throttle_burst" {
  description = "Burst limit del stage"
  type        = number
  default     = 50
}

# ---------------- Logs / Secretos / S3 ----------------
variable "log_retention_days" {
  description = "Retención de logs en CloudWatch"
  type        = number
  default     = 7
}

variable "secret_recovery_days" {
  description = "Días de recuperación del secreto al borrarlo (0 = borrado inmediato, útil en pruebas)"
  type        = number
  default     = 7

  validation {
    condition     = var.secret_recovery_days == 0 || (var.secret_recovery_days >= 7 && var.secret_recovery_days <= 30)
    error_message = "Debe ser 0 o un valor entre 7 y 30."
  }
}

variable "bucket_force_destroy" {
  description = "Permite destruir el bucket con objetos dentro (solo para pruebas)"
  type        = bool
  default     = false
}

variable "admin_principal_arns" {
  description = "ARNs (usuario/rol) exentos del Deny del bucket, p. ej. el tuyo para hacer destroy"
  type        = list(string)
  default     = []
}
