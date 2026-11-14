# Eventos: DynamoDB Streams + EventBridge Pipes publican cada cambio de estado
resource "aws_cloudwatch_event_bus" "pedidos" {
  name = "${local.nombre}-pedidos"
}

resource "aws_sqs_queue" "dlq_eventos" {
  name              = "${local.nombre}-dlq-eventos"
  kms_master_key_id = aws_kms_key.datos.id
}

resource "aws_iam_role" "pipe" {
  name = "${local.nombre}-pipe"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pipes.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "pipe" {
  name = "${local.nombre}-pipe"
  role = aws_iam_role.pipe.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator", "dynamodb:ListStreams"]
        Resource = aws_dynamodb_table.pedidos.stream_arn
      },
      {
        Effect   = "Allow"
        Action   = "events:PutEvents"
        Resource = aws_cloudwatch_event_bus.pedidos.arn
      },
      {
        Effect   = "Allow"
        Action   = "kms:Decrypt"
        Resource = aws_kms_key.datos.arn
      }
    ]
  })
}

# Solo pasan los cambios de estado; el evento lleva eventId, pedidoId, clienteId, estado y fecha
resource "aws_pipes_pipe" "pedidos" {
  name     = "${local.nombre}-pedidos"
  role_arn = aws_iam_role.pipe.arn
  source   = aws_dynamodb_table.pedidos.stream_arn
  target   = aws_cloudwatch_event_bus.pedidos.arn

  source_parameters {
    dynamodb_stream_parameters {
      starting_position = "LATEST"
      batch_size        = 10
    }

    filter_criteria {
      filter {
        pattern = jsonencode({ eventName = ["MODIFY"], dynamodb = { NewImage = { estado = { S = [{ exists = true }] } } } })
      }
    }
  }

  target_parameters {
    input_template = "{\"eventId\": <$.eventID>, \"pedidoId\": <$.dynamodb.NewImage.pedidoId.S>, \"clienteId\": <$.dynamodb.NewImage.clienteId.S>, \"estado\": <$.dynamodb.NewImage.estado.S>, \"fecha\": <aws.pipes.event.ingestion-time>}"

    eventbridge_event_bus_parameters {
      detail_type = "CambioEstadoPedido"
      source      = "shopperu.pedidos"
    }
  }
}

# SNS: SMS o push al cliente y alertas al equipo
resource "aws_sns_topic" "clientes" {
  name              = "${local.nombre}-clientes"
  kms_master_key_id = aws_kms_key.datos.id
}

resource "aws_sns_topic" "alertas" {
  name              = "${local.nombre}-alertas"
  kms_master_key_id = aws_kms_key.datos.id
}

resource "aws_sns_topic_subscription" "alertas_correo" {
  topic_arn = aws_sns_topic.alertas.arn
  protocol  = "email"
  endpoint  = var.correo_alertas
}

resource "aws_sns_topic_policy" "clientes" {
  arn = aws_sns_topic.clientes.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.clientes.arn
    }]
  })
}

# SQS: cola de correos con su DLQ (3 recepciones fallidas)
resource "aws_sqs_queue" "dlq_correos" {
  name              = "${local.nombre}-dlq-correos"
  kms_master_key_id = aws_kms_key.datos.id
}

resource "aws_sqs_queue" "correos" {
  name              = "${local.nombre}-correos"
  kms_master_key_id = aws_kms_key.datos.id

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq_correos.arn
    maxReceiveCount     = 3
  })
}

resource "aws_sqs_queue_policy" "correos" {
  queue_url = aws_sqs_queue.correos.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.correos.arn
    }]
  })
}

# Reglas del bus: 1 SMS o push, 2 correo, 3 pantalla
resource "aws_cloudwatch_event_rule" "enviado_entregado" {
  name           = "${local.nombre}-regla1-enviado-entregado"
  event_bus_name = aws_cloudwatch_event_bus.pedidos.name
  event_pattern  = jsonencode({ source = ["shopperu.pedidos"], detail = { estado = ["ENVIADO", "ENTREGADO"] } })
}

resource "aws_cloudwatch_event_target" "sns_clientes" {
  rule           = aws_cloudwatch_event_rule.enviado_entregado.name
  event_bus_name = aws_cloudwatch_event_bus.pedidos.name
  arn            = aws_sns_topic.clientes.arn

  dead_letter_config {
    arn = aws_sqs_queue.dlq_eventos.arn
  }
}

resource "aws_cloudwatch_event_rule" "confirmado" {
  name           = "${local.nombre}-regla2-compra-confirmada"
  event_bus_name = aws_cloudwatch_event_bus.pedidos.name
  event_pattern  = jsonencode({ source = ["shopperu.pedidos"], detail = { estado = ["CONFIRMADO"] } })
}

resource "aws_cloudwatch_event_target" "sqs_correos" {
  rule           = aws_cloudwatch_event_rule.confirmado.name
  event_bus_name = aws_cloudwatch_event_bus.pedidos.name
  arn            = aws_sqs_queue.correos.arn

  dead_letter_config {
    arn = aws_sqs_queue.dlq_eventos.arn
  }
}

resource "aws_cloudwatch_event_rule" "cambio_estado" {
  name           = "${local.nombre}-regla3-cambio-estado"
  event_bus_name = aws_cloudwatch_event_bus.pedidos.name
  event_pattern  = jsonencode({ source = ["shopperu.pedidos"] })
}

resource "aws_iam_role" "eventos_appsync" {
  name = "${local.nombre}-eventos-appsync"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "eventos_appsync" {
  name = "${local.nombre}-eventos-appsync"
  role = aws_iam_role.eventos_appsync.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "appsync:GraphQL"
      Resource = "${aws_appsync_graphql_api.pedidos.arn}/types/Mutation/fields/publicarEstadoPedido"
    }]
  })
}

resource "aws_cloudwatch_event_target" "appsync" {
  rule           = aws_cloudwatch_event_rule.cambio_estado.name
  event_bus_name = aws_cloudwatch_event_bus.pedidos.name
  arn            = aws_appsync_graphql_api.pedidos.uris["GRAPHQL"]
  role_arn       = aws_iam_role.eventos_appsync.arn

  appsync_target {
    graphql_operation = "mutation Publicar($pedidoId: ID!, $clienteId: String!, $estado: String!) { publicarEstadoPedido(pedidoId: $pedidoId, clienteId: $clienteId, estado: $estado) { pedidoId clienteId estado } }"
  }

  input_transformer {
    input_paths = {
      pedidoId  = "$.detail.pedidoId"
      clienteId = "$.detail.clienteId"
      estado    = "$.detail.estado"
    }
    input_template = "{\"pedidoId\": <pedidoId>, \"clienteId\": <clienteId>, \"estado\": <estado>}"
  }

  dead_letter_config {
    arn = aws_sqs_queue.dlq_eventos.arn
  }
}

# Lambda enviar-correo: unico consumidor de la cola, envia con SES
data "archive_file" "enviar_correo" {
  type        = "zip"
  source_dir  = "${path.module}/src/enviar-correo"
  output_path = "${path.module}/build/enviar-correo.zip"
}

resource "aws_iam_role" "enviar_correo" {
  name = "${local.nombre}-enviar-correo"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_cloudwatch_log_group" "enviar_correo" {
  name              = "/aws/lambda/${local.nombre}-enviar-correo"
  kms_key_id        = aws_kms_key.datos.arn
  retention_in_days = 90
}

resource "aws_iam_role_policy" "enviar_correo" {
  name = "${local.nombre}-enviar-correo"
  role = aws_iam_role.enviar_correo.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.enviar_correo.arn}:*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.correos.arn
      },
      {
        Effect   = "Allow"
        Action   = "ses:SendTemplatedEmail"
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = "dynamodb:UpdateItem"
        Resource = aws_dynamodb_table.pedidos.arn
      },
      {
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = aws_kms_key.datos.arn
      }
    ]
  })
}

resource "aws_lambda_function" "enviar_correo" {
  #checkov:skip=CKV_AWS_272:El codigo solo se despliega desde GitHub Actions con OIDC y revision en el entorno dev
  reserved_concurrent_executions = 20
  #checkov:skip=CKV_AWS_117:Solo la Lambda de pagos va en la VPC; las demas usan servicios de AWS con IAM y no salen a internet
  tracing_config {
    mode = "Active"
  }

  #checkov:skip=CKV_AWS_116:Las fallas ya tienen DLQ en SQS y EventBridge o la Lambda responde sincrono a API Gateway
  function_name    = "${local.nombre}-enviar-correo"
  role             = aws_iam_role.enviar_correo.arn
  runtime          = "nodejs22.x"
  handler          = "index.handler"
  filename         = data.archive_file.enviar_correo.output_path
  source_code_hash = data.archive_file.enviar_correo.output_base64sha256

  environment {
    variables = {
      PLANTILLA = aws_ses_template.compra.name
      TABLA     = aws_dynamodb_table.pedidos.name
    }
  }

  depends_on = [aws_cloudwatch_log_group.enviar_correo, aws_iam_role_policy.enviar_correo]
}

resource "aws_lambda_event_source_mapping" "correos" {
  event_source_arn = aws_sqs_queue.correos.arn
  function_name    = aws_lambda_function.enviar_correo.arn
  batch_size       = 10
}

# SES: identidad del dominio y plantilla del correo de compra
resource "aws_sesv2_email_identity" "dominio" {
  email_identity = var.dominio
}

resource "aws_ses_template" "compra" {
  name    = "${local.nombre}-compra-confirmada"
  subject = "Tu compra en ShopPeru fue confirmada"
  html    = "<p>Hola, tu pedido {{pedidoId}} fue confirmado.</p>"
  text    = "Hola, tu pedido {{pedidoId}} fue confirmado."
}

# AppSync: mutacion publicarEstadoPedido y suscripcion por WebSocket
resource "aws_appsync_graphql_api" "pedidos" {
  name                = "${local.nombre}-pedidos"
  authentication_type = "AMAZON_COGNITO_USER_POOLS"

  user_pool_config {
    user_pool_id   = aws_cognito_user_pool.usuarios.id
    aws_region     = var.aws_region
    default_action = "ALLOW"
  }

  additional_authentication_provider {
    authentication_type = "AWS_IAM"
  }

  schema = <<-EOT
    type EstadoPedido @aws_cognito_user_pools @aws_iam {
      pedidoId: ID!
      clienteId: String!
      estado: String!
    }

    type Query {
      estadoPedido(pedidoId: ID!): EstadoPedido
    }

    type Mutation {
      publicarEstadoPedido(pedidoId: ID!, clienteId: String!, estado: String!): EstadoPedido @aws_iam
    }

    type Subscription {
      cambioEstado(clienteId: String!): EstadoPedido
        @aws_subscribe(mutations: ["publicarEstadoPedido"])
    }
  EOT
}

resource "aws_appsync_datasource" "ninguno" {
  api_id = aws_appsync_graphql_api.pedidos.id
  name   = "ninguno"
  type   = "NONE"
}

resource "aws_appsync_resolver" "publicar" {
  api_id      = aws_appsync_graphql_api.pedidos.id
  type        = "Mutation"
  field       = "publicarEstadoPedido"
  data_source = aws_appsync_datasource.ninguno.name

  runtime {
    name            = "APPSYNC_JS"
    runtime_version = "1.0.0"
  }

  code = <<-EOT
    export function request(ctx) {
      return { payload: ctx.args };
    }

    export function response(ctx) {
      return ctx.result;
    }
  EOT
}
