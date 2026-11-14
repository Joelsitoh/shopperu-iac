# KMS: cifra DynamoDB, S3, la clave de la pasarela y los respaldos
data "aws_caller_identity" "cuenta" {}

resource "aws_kms_key" "datos" {
  description             = "Cifrado de datos de ShopPeru"
  deletion_window_in_days = 7

  # La cuenta administra la llave y CloudWatch Logs puede usarla para cifrar los registros
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Cuenta"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.cuenta.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.aws_region}.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource  = "*"
      }
    ]
  })
}

# Llave de la region de respaldo para los registros de la API en espera
resource "aws_kms_key" "logs_respaldo" {
  provider                = aws.respaldo
  description             = "Cifrado de registros en la region de respaldo"
  deletion_window_in_days = 7

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Cuenta"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.cuenta.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "CloudWatchLogs"
        Effect    = "Allow"
        Principal = { Service = "logs.${var.region_respaldo}.amazonaws.com" }
        Action    = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource  = "*"
      }
    ]
  })
}

resource "aws_kms_alias" "datos" {
  name          = "alias/${local.nombre}-datos"
  target_key_id = aws_kms_key.datos.key_id
}

# DynamoDB: Productos, Carritos y Pedidos
resource "aws_dynamodb_table" "productos" {
  name         = "${local.nombre}-productos"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "productoId"

  attribute {
    name = "productoId"
    type = "S"
  }

  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.datos.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  # Global Tables: replica en la region de respaldo
  replica {
    region_name = var.region_respaldo
  }
}

resource "aws_dynamodb_table" "carritos" {
  name         = "${local.nombre}-carritos"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "clienteId"
  range_key    = "itemId"

  attribute {
    name = "clienteId"
    type = "S"
  }

  attribute {
    name = "itemId"
    type = "S"
  }

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.datos.arn
  }

  point_in_time_recovery {
    enabled = true
  }
}

resource "aws_dynamodb_table" "pedidos" {
  name         = "${local.nombre}-pedidos"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pedidoId"

  attribute {
    name = "pedidoId"
    type = "S"
  }

  attribute {
    name = "clienteId"
    type = "S"
  }

  global_secondary_index {
    name            = "por-cliente"
    hash_key        = "clienteId"
    projection_type = "ALL"
  }

  # Streams: cada cambio de un pedido sale hacia EventBridge Pipes
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.datos.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  replica {
    region_name = var.region_respaldo
  }
}
