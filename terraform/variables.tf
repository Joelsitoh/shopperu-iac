variable "aws_region" {
  description = "Region de AWS del laboratorio"
  type        = string
  default     = "sa-east-1"
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

variable "region_respaldo" {
  description = "Region de respaldo (replica y API en espera)"
  type        = string
  default     = "us-east-1"
}

variable "dominio" {
  description = "Dominio de la tienda"
  type        = string
  default     = "shopperu.pe"
}

variable "correo_alertas" {
  description = "Correo del equipo tecnico para las alarmas"
  type        = string
  default     = "equipo@shopperu.pe"
}
