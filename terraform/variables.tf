variable "aws_region" {
  description = "Region de AWS del laboratorio"
  type        = string
  default     = "us-east-2"
}

variable "prefijo" {
  description = "Prefijo de los recursos del laboratorio"
  type        = string
  default     = "lab09-shopperu"
}

variable "entorno" {
  description = "Entorno de despliegue"
  type        = string
  default     = "dev"
}
