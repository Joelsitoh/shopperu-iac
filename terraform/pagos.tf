# VPC de pagos en dos zonas: la Lambda de pagos sale a la pasarela por su NAT
data "aws_availability_zones" "zonas" {
  state = "available"
}

resource "aws_vpc" "pagos" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true

  tags = { Name = "${local.nombre}-pagos" }
}

resource "aws_internet_gateway" "pagos" {
  vpc_id = aws_vpc.pagos.id
}

resource "aws_subnet" "publica" {
  count             = 2
  vpc_id            = aws_vpc.pagos.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.zonas.names[count.index]

  tags = { Name = "${local.nombre}-publica-${count.index}" }
}

resource "aws_subnet" "privada" {
  count             = 2
  vpc_id            = aws_vpc.pagos.id
  cidr_block        = "10.0.${count.index + 10}.0/24"
  availability_zone = data.aws_availability_zones.zonas.names[count.index]

  tags = { Name = "${local.nombre}-privada-${count.index}" }
}

resource "aws_route_table" "publica" {
  vpc_id = aws_vpc.pagos.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.pagos.id
  }
}

resource "aws_route_table_association" "publica" {
  count          = 2
  subnet_id      = aws_subnet.publica[count.index].id
  route_table_id = aws_route_table.publica.id
}

# Un NAT Gateway por zona
resource "aws_eip" "nat" {
  count  = 2
  domain = "vpc"
}

resource "aws_nat_gateway" "pagos" {
  count         = 2
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.publica[count.index].id
}

resource "aws_route_table" "privada" {
  count  = 2
  vpc_id = aws_vpc.pagos.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.pagos[count.index].id
  }
}

resource "aws_route_table_association" "privada" {
  count          = 2
  subnet_id      = aws_subnet.privada[count.index].id
  route_table_id = aws_route_table.privada[count.index].id
}

resource "aws_security_group" "pagos" {
  name        = "${local.nombre}-pagos"
  description = "Lambda de pagos: solo sale por HTTPS a la pasarela"
  vpc_id      = aws_vpc.pagos.id

  egress {
    description = "HTTPS hacia la pasarela"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Secrets Manager: clave de la pasarela
resource "aws_secretsmanager_secret" "pasarela" {
  name       = "${local.nombre}-pasarela"
  kms_key_id = aws_kms_key.datos.arn
}

# Lambda de pagos (subredes privadas A y B)
data "archive_file" "pagos" {
  type        = "zip"
  source_dir  = "${path.module}/src/pagos"
  output_path = "${path.module}/build/pagos.zip"
}

resource "aws_iam_role" "pagos" {
  name = "${local.nombre}-pagos"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudwatch_log_group" "pagos" {
  name              = "/aws/lambda/${local.nombre}-pagos"
  retention_in_days = 90
}

resource "aws_iam_role_policy" "pagos" {
  name = "${local.nombre}-pagos"
  role = aws_iam_role.pagos.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.pagos.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = "secretsmanager:GetSecretValue"
        Resource = aws_secretsmanager_secret.pasarela.arn
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.datos.arn
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "pagos" {
  #checkov:skip=CKV_AWS_117:Solo la Lambda de pagos va en la VPC; las demas usan servicios de AWS con IAM y no salen a internet
  tracing_config {
    mode = "Active"
  }

  #checkov:skip=CKV_AWS_116:Las fallas ya tienen DLQ en SQS y EventBridge o la Lambda responde sincrono a API Gateway
  function_name    = "${local.nombre}-pagos"
  role             = aws_iam_role.pagos.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.pagos.output_path
  source_code_hash = data.archive_file.pagos.output_base64sha256
  timeout          = 8

  vpc_config {
    subnet_ids         = aws_subnet.privada[*].id
    security_group_ids = [aws_security_group.pagos.id]
  }

  environment {
    variables = {
      SECRETO_PASARELA = aws_secretsmanager_secret.pasarela.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.pagos, aws_iam_role_policy.pagos]
}

# Step Functions: flujo de la compra
resource "aws_iam_role" "sfn" {
  name = "${local.nombre}-compra"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "states.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "sfn" {
  name = "${local.nombre}-compra"
  role = aws_iam_role.sfn.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = [aws_dynamodb_table.productos.arn, aws_dynamodb_table.pedidos.arn]
      },
      {
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = aws_lambda_function.pagos.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.datos.arn
      }
    ]
  })
}

resource "aws_sfn_state_machine" "compra" {
  name     = "${local.nombre}-compra"
  role_arn = aws_iam_role.sfn.arn

  definition = jsonencode({
    Comment = "ReservarStock, Cobrar y ConfirmarPedido"
    StartAt = "ReservarStock"
    States = {
      ReservarStock = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                 = aws_dynamodb_table.productos.name
          Key                       = { productoId = { "S.$" = "$.productoId" } }
          UpdateExpression          = "SET stock = stock - :c"
          ConditionExpression       = "stock >= :c"
          ExpressionAttributeValues = { ":c" = { "N.$" = "$.cantidad" } }
        }
        ResultPath = null
        Next       = "Cobrar"
      }
      Cobrar = {
        Type           = "Task"
        Resource       = "arn:aws:states:::lambda:invoke"
        Parameters     = { FunctionName = aws_lambda_function.pagos.arn, "Payload.$" = "$" }
        TimeoutSeconds = 8
        ResultPath     = "$.pago"
        Catch = [
          { ErrorEquals = ["States.Timeout"], ResultPath = "$.error", Next = "Pendiente" },
          { ErrorEquals = ["States.ALL"], ResultPath = "$.error", Next = "LiberarStock" }
        ]
        Next = "ConfirmarPedido"
      }
      ConfirmarPedido = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                 = aws_dynamodb_table.pedidos.name
          Key                       = { pedidoId = { "S.$" = "$.pedidoId" } }
          UpdateExpression          = "SET estado = :e"
          ExpressionAttributeValues = { ":e" = { S = "CONFIRMADO" } }
        }
        End = true
      }
      LiberarStock = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                 = aws_dynamodb_table.productos.name
          Key                       = { productoId = { "S.$" = "$.productoId" } }
          UpdateExpression          = "SET stock = stock + :c"
          ExpressionAttributeValues = { ":c" = { "N.$" = "$.cantidad" } }
        }
        End = true
      }
      Pendiente = {
        Type     = "Task"
        Resource = "arn:aws:states:::dynamodb:updateItem"
        Parameters = {
          TableName                 = aws_dynamodb_table.pedidos.name
          Key                       = { pedidoId = { "S.$" = "$.pedidoId" } }
          UpdateExpression          = "SET estado = :e"
          ExpressionAttributeValues = { ":e" = { S = "PENDIENTE" } }
        }
        End = true
      }
    }
  })
}
