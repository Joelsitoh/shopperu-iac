# Monitoreo: CloudWatch avisa al equipo por SNS
resource "aws_cloudwatch_metric_alarm" "api_5xx" {
  alarm_name          = "${local.nombre}-api-5xx"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5xx"
  dimensions          = { ApiId = aws_apigatewayv2_api.api.id }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 10
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alertas.arn]
}

resource "aws_cloudwatch_metric_alarm" "api_latencia" {
  alarm_name          = "${local.nombre}-api-latencia"
  namespace           = "AWS/ApiGateway"
  metric_name         = "Latency"
  dimensions          = { ApiId = aws_apigatewayv2_api.api.id }
  extended_statistic  = "p95"
  period              = 300
  evaluation_periods  = 1
  threshold           = 500
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alertas.arn]
}

resource "aws_cloudwatch_metric_alarm" "lambda_errores" {
  for_each = {
    catalogo      = aws_lambda_function.catalogo.function_name
    carrito       = aws_lambda_function.api["carrito"].function_name
    pedidos       = aws_lambda_function.api["pedidos"].function_name
    pagos         = aws_lambda_function.pagos.function_name
    enviar-correo = aws_lambda_function.enviar_correo.function_name
  }
  alarm_name          = "${local.nombre}-${each.key}-errores"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = each.value }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 5
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alertas.arn]
}

resource "aws_cloudwatch_metric_alarm" "dlq" {
  for_each = {
    correos = aws_sqs_queue.dlq_correos.name
    eventos = aws_sqs_queue.dlq_eventos.name
  }
  alarm_name          = "${local.nombre}-dlq-${each.key}"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = each.value }
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 1
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alertas.arn]
}

resource "aws_cloudwatch_metric_alarm" "replica" {
  alarm_name          = "${local.nombre}-retraso-replica"
  namespace           = "AWS/DynamoDB"
  metric_name         = "ReplicationLatency"
  dimensions          = { TableName = aws_dynamodb_table.pedidos.name, ReceivingRegion = var.region_respaldo }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 1
  threshold           = 60000
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alertas.arn]
}

# AWS Backup: copia cada hora, 30 dias, con copia a la boveda de us-east-1
resource "aws_backup_vault" "principal" {
  name        = "${local.nombre}-principal"
  kms_key_arn = aws_kms_key.datos.arn
}

resource "aws_backup_vault" "respaldo" {
  provider = aws.respaldo
  name     = "${local.nombre}-respaldo"
}

resource "aws_backup_plan" "dynamodb" {
  name = "${local.nombre}-dynamodb"

  rule {
    rule_name         = "cada-hora"
    target_vault_name = aws_backup_vault.principal.name
    schedule          = "cron(0 * * * ? *)"

    lifecycle {
      delete_after = 30
    }

    copy_action {
      destination_vault_arn = aws_backup_vault.respaldo.arn

      lifecycle {
        delete_after = 30
      }
    }
  }
}

resource "aws_iam_role" "backup" {
  name = "${local.nombre}-backup"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "backup.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "backup" {
  role       = aws_iam_role.backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_backup_selection" "dynamodb" {
  name         = "${local.nombre}-tablas"
  plan_id      = aws_backup_plan.dynamodb.id
  iam_role_arn = aws_iam_role.backup.arn
  resources = [
    aws_dynamodb_table.productos.arn,
    aws_dynamodb_table.carritos.arn,
    aws_dynamodb_table.pedidos.arn
  ]
}

# Region de respaldo: API de consulta en espera (solo GET /productos* y GET /pedidos*)
data "archive_file" "consulta" {
  type        = "zip"
  source_dir  = "${path.module}/src/consulta"
  output_path = "${path.module}/build/consulta.zip"
}

resource "aws_iam_role" "consulta" {
  provider = aws.respaldo
  name     = "${local.nombre}-consulta-respaldo"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudwatch_log_group" "consulta" {
  provider          = aws.respaldo
  name              = "/aws/lambda/${local.nombre}-consulta-respaldo"
  retention_in_days = 90
}

resource "aws_iam_role_policy" "consulta" {
  provider = aws.respaldo
  name     = "${local.nombre}-consulta-respaldo"
  role     = aws_iam_role.consulta.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.consulta.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:Query", "dynamodb:Scan"]
        Resource = "arn:aws:dynamodb:${var.region_respaldo}:*:table/${local.nombre}-*"
      }
    ]
  })
}

resource "aws_lambda_function" "consulta" {
  provider         = aws.respaldo
  function_name    = "${local.nombre}-consulta-respaldo"
  role             = aws_iam_role.consulta.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.consulta.output_path
  source_code_hash = data.archive_file.consulta.output_base64sha256

  depends_on = [aws_cloudwatch_log_group.consulta, aws_iam_role_policy.consulta]
}

resource "aws_apigatewayv2_api" "respaldo" {
  provider      = aws.respaldo
  name          = "${local.nombre}-api-respaldo"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_authorizer" "respaldo" {
  provider         = aws.respaldo
  api_id           = aws_apigatewayv2_api.respaldo.id
  name             = "cognito"
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.web.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.usuarios.id}"
  }
}

resource "aws_apigatewayv2_integration" "respaldo" {
  provider               = aws.respaldo
  api_id                 = aws_apigatewayv2_api.respaldo.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.consulta.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "respaldo" {
  provider           = aws.respaldo
  for_each           = toset(["GET /productos", "GET /productos/{id}", "GET /pedidos", "GET /pedidos/{id}"])
  api_id             = aws_apigatewayv2_api.respaldo.id
  route_key          = each.key
  target             = "integrations/${aws_apigatewayv2_integration.respaldo.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.respaldo.id
}

resource "aws_apigatewayv2_stage" "respaldo" {
  provider    = aws.respaldo
  api_id      = aws_apigatewayv2_api.respaldo.id
  name        = var.entorno
  auto_deploy = true
}

resource "aws_lambda_permission" "respaldo" {
  provider      = aws.respaldo
  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.consulta.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.respaldo.execution_arn}/*/*"
}
