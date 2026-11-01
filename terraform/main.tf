provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Proyecto = "ShopPeru"
      Entorno  = var.entorno
      Curso    = "Infraestructura como Codigo"
    }
  }
}

locals {
  nombre = "${var.prefijo}-${var.entorno}"
}

# Cognito: login de compradores, vendedores y administradores
resource "aws_cognito_user_pool" "usuarios" {
  name = "${local.nombre}-usuarios"

  auto_verified_attributes = ["email"]
  username_attributes      = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_numbers   = true
    require_symbols   = false
    require_uppercase = true
  }
}

resource "aws_cognito_user_pool_client" "web" {
  name         = "${local.nombre}-web"
  user_pool_id = aws_cognito_user_pool.usuarios.id

  explicit_auth_flows = ["ALLOW_USER_SRP_AUTH", "ALLOW_REFRESH_TOKEN_AUTH"]
}

# Rol de ejecucion de la Lambda de catalogo
resource "aws_iam_role" "lambda" {
  name = "${local.nombre}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudwatch_log_group" "catalogo" {
  name              = "/aws/lambda/${local.nombre}-catalogo"
  retention_in_days = 7
}

resource "aws_iam_role_policy" "lambda_logs" {
  name = "${local.nombre}-lambda-logs"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.catalogo.arn}:*"
    }]
  })
}

# Lambda de catalogo (Node.js)
data "archive_file" "catalogo" {
  type        = "zip"
  source_dir  = "${path.module}/src/catalogo"
  output_path = "${path.module}/build/catalogo.zip"
}

resource "aws_lambda_function" "catalogo" {
  function_name    = "${local.nombre}-catalogo"
  role             = aws_iam_role.lambda.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.catalogo.output_path
  source_code_hash = data.archive_file.catalogo.output_base64sha256

  depends_on = [aws_cloudwatch_log_group.catalogo, aws_iam_role_policy.lambda_logs]
}

# API Gateway: entrada de la API, valida el token de Cognito
resource "aws_apigatewayv2_api" "api" {
  name          = "${local.nombre}-api"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.api.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.web.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.usuarios.id}"
  }
}

resource "aws_apigatewayv2_integration" "catalogo" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.catalogo.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "productos" {
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = "GET /productos"
  target             = "integrations/${aws_apigatewayv2_integration.catalogo.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "dev" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = var.entorno
  auto_deploy = true
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.catalogo.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}
