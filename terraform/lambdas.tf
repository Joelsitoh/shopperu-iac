# Lambdas de la API: 3b carrito y 3c pedidos (3a catalogo esta en main.tf)
# Cada Lambda tiene su propio rol con permisos solo sobre lo que usa
locals {
  lambdas_api = {
    carrito = aws_dynamodb_table.carritos.arn
    pedidos = aws_dynamodb_table.pedidos.arn
  }
}

data "archive_file" "api" {
  for_each    = local.lambdas_api
  type        = "zip"
  source_dir  = "${path.module}/src/${each.key}"
  output_path = "${path.module}/build/${each.key}.zip"
}

resource "aws_iam_role" "api" {
  for_each = local.lambdas_api
  name     = "${local.nombre}-${each.key}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudwatch_log_group" "api" {
  for_each          = local.lambdas_api
  name              = "/aws/lambda/${local.nombre}-${each.key}"
  retention_in_days = 90
}

resource "aws_iam_role_policy" "api" {
  for_each = local.lambdas_api
  name     = "${local.nombre}-${each.key}"
  role     = aws_iam_role.api[each.key].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.api[each.key].arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
        Resource = [each.value, "${each.value}/index/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.datos.arn
      }
    ]
  })
}

# La Lambda de pedidos ademas inicia Step Functions
resource "aws_iam_role_policy" "pedidos_sfn" {
  name = "${local.nombre}-pedidos-sfn"
  role = aws_iam_role.api["pedidos"].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "states:StartExecution"
      Resource = aws_sfn_state_machine.compra.arn
    }]
  })
}

resource "aws_lambda_function" "api" {
  #checkov:skip=CKV_AWS_116:Las fallas ya tienen DLQ en SQS y EventBridge o la Lambda responde sincrono a API Gateway
  for_each         = local.lambdas_api
  function_name    = "${local.nombre}-${each.key}"
  role             = aws_iam_role.api[each.key].arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.api[each.key].output_path
  source_code_hash = data.archive_file.api[each.key].output_base64sha256

  environment {
    variables = {
      TABLA = each.value
    }
  }

  depends_on = [aws_cloudwatch_log_group.api, aws_iam_role_policy.api]
}

# La Lambda de catalogo lee y escribe la tabla Productos
resource "aws_iam_role_policy" "catalogo_dynamodb" {
  name = "${local.nombre}-catalogo-dynamodb"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Scan", "dynamodb:PutItem", "dynamodb:UpdateItem", "dynamodb:DeleteItem"]
        Resource = aws_dynamodb_table.productos.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.datos.arn
      }
    ]
  })
}

# Las 13 rutas de la API (Tabla 1 del informe)
locals {
  rutas = {
    "GET /productos"             = "catalogo"
    "GET /productos/{id}"        = "catalogo"
    "POST /productos"            = "catalogo"
    "PUT /productos/{id}"        = "catalogo"
    "DELETE /productos/{id}"     = "catalogo"
    "GET /carrito"               = "carrito"
    "POST /carrito/items"        = "carrito"
    "PUT /carrito/items/{id}"    = "carrito"
    "DELETE /carrito/items/{id}" = "carrito"
    "POST /pedidos"              = "pedidos"
    "GET /pedidos"               = "pedidos"
    "GET /pedidos/{id}"          = "pedidos"
    "PATCH /pedidos/{id}/estado" = "pedidos"
  }
}

resource "aws_apigatewayv2_integration" "api" {
  for_each               = local.lambdas_api
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api[each.key].invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "rutas" {
  for_each           = { for k, v in local.rutas : k => v if k != "GET /productos" }
  api_id             = aws_apigatewayv2_api.api.id
  route_key          = each.key
  target             = each.value == "catalogo" ? "integrations/${aws_apigatewayv2_integration.catalogo.id}" : "integrations/${aws_apigatewayv2_integration.api[each.value].id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_lambda_permission" "rutas" {
  for_each      = local.lambdas_api
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}
