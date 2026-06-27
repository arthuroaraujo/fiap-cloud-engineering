data "aws_caller_identity" "current" {}

locals {
  lab_role_arn     = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/LabRole"
  bucket_name      = "pedeja-datalake-${data.aws_caller_identity.current.account_id}"
  powertools_layer = "arn:aws:lambda:us-east-1:017000801446:layer:AWSLambdaPowertoolsPythonV3-python312-x86_64:25"
}

# Cada fase e autossuficiente: cria seu proprio data lake.
resource "aws_s3_bucket" "datalake" {
  bucket        = local.bucket_name
  force_destroy = true
}

# ---------------------------------------------------------------------------
# Kinesis Data Stream: o dado fica RETIDO (24h padrao) e pode ser lido por
# varios consumidores independentes e reprocessado (replay). Modo on-demand
# para nao gerenciar shards manualmente.
# ---------------------------------------------------------------------------
resource "aws_kinesis_stream" "pedidos" {
  name = "pedeja-pedidos-stream"
  stream_mode_details {
    stream_mode = "ON_DEMAND"
  }
}

# ---------------------------------------------------------------------------
# Produtor: API GW -> publica no stream
# ---------------------------------------------------------------------------
data "archive_file" "produtor_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-produtor"
  output_path = "${path.module}/build/produtor.zip"
}

resource "aws_lambda_function" "produtor" {
  function_name    = "pedeja-produtor-stream"
  role             = local.lab_role_arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.produtor_zip.output_path
  source_code_hash = data.archive_file.produtor_zip.output_base64sha256
  timeout          = 15
  memory_size      = 128
  layers           = [local.powertools_layer]
  tracing_config { mode = "Active" }
  environment {
    variables = {
      STREAM_NAME                  = aws_kinesis_stream.pedidos.name
      POWERTOOLS_SERVICE_NAME      = "pedeja-produtor-stream"
      POWERTOOLS_METRICS_NAMESPACE = "PedeJa"
      POWERTOOLS_LOG_LEVEL         = "INFO"
    }
  }
}

# ---------------------------------------------------------------------------
# Consumidor 1: data lake (grava no S3)
# ---------------------------------------------------------------------------
data "archive_file" "datalake_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-datalake"
  output_path = "${path.module}/build/datalake.zip"
}

resource "aws_lambda_function" "datalake" {
  function_name    = "pedeja-datalake"
  role             = local.lab_role_arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.datalake_zip.output_path
  source_code_hash = data.archive_file.datalake_zip.output_base64sha256
  timeout          = 60
  memory_size      = 128
  layers           = [local.powertools_layer]
  tracing_config { mode = "Active" }
  environment {
    variables = {
      BUCKET_DATA_LAKE             = aws_s3_bucket.datalake.bucket
      POWERTOOLS_SERVICE_NAME      = "pedeja-datalake"
      POWERTOOLS_METRICS_NAMESPACE = "PedeJa"
      POWERTOOLS_LOG_LEVEL         = "INFO"
    }
  }
}

# ---------------------------------------------------------------------------
# Consumidor 2: faturamento em tempo real (agrega, nao grava no S3)
# ---------------------------------------------------------------------------
data "archive_file" "faturamento_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda-faturamento"
  output_path = "${path.module}/build/faturamento.zip"
}

resource "aws_lambda_function" "faturamento" {
  function_name    = "pedeja-faturamento"
  role             = local.lab_role_arn
  runtime          = "python3.12"
  handler          = "handler.handler"
  filename         = data.archive_file.faturamento_zip.output_path
  source_code_hash = data.archive_file.faturamento_zip.output_base64sha256
  timeout          = 60
  memory_size      = 128
  layers           = [local.powertools_layer]
  tracing_config { mode = "Active" }
  environment {
    variables = {
      POWERTOOLS_SERVICE_NAME      = "pedeja-faturamento"
      POWERTOOLS_METRICS_NAMESPACE = "PedeJa"
      POWERTOOLS_LOG_LEVEL         = "INFO"
    }
  }
}

# ---------------------------------------------------------------------------
# Os DOIS consumidores leem o MESMO stream, de forma independente.
# Cada event source mapping mantem seu proprio ponteiro de leitura (iterator).
# starting_position = TRIM_HORIZON: le desde o inicio do stream, entao todo
# aluno processa os mesmos registros retidos (resultado deterministico).
# ---------------------------------------------------------------------------
resource "aws_lambda_event_source_mapping" "stream_to_datalake" {
  event_source_arn  = aws_kinesis_stream.pedidos.arn
  function_name     = aws_lambda_function.datalake.arn
  starting_position = "TRIM_HORIZON"
  batch_size        = 100
}

resource "aws_lambda_event_source_mapping" "stream_to_faturamento" {
  event_source_arn  = aws_kinesis_stream.pedidos.arn
  function_name     = aws_lambda_function.faturamento.arn
  starting_position = "TRIM_HORIZON"
  batch_size        = 100
}

# ---------------------------------------------------------------------------
# API Gateway -> produtor
# ---------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "api" {
  name          = "pedeja-api-fase3"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.produtor.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_pedidos" {
  api_id    = aws_apigatewayv2_api.api.id
  route_key = "POST /pedidos"
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.produtor.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.api.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# Dashboard Fase 3: o mesmo stream alimentando 2 consumidores + negocio
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_dashboard" "fase3" {
  dashboard_name = "PedeJa-Fase3-Streaming"
  dashboard_body = jsonencode({
    widgets = [
      {
        type       = "text", x = 0, y = 0, width = 24, height = 2,
        properties = { markdown = "# PedeJa - Fase 3 (Kinesis: 1 stream -> N consumidores)\nO **mesmo** stream alimenta o **data lake** e o **faturamento em tempo real**, de forma independente. O dado fica retido -> permite **replay**. Isso a fila SQS nao faz." }
      },
      {
        type = "metric", x = 0, y = 2, width = 12, height = 6,
        properties = {
          title  = "Trafego - publicados vs consumidos (2 consumidores)",
          region = "us-east-1",
          metrics = [
            ["PedeJa", "pedidos_publicados", "service", "pedeja-produtor-stream", { stat = "Sum", label = "publicados" }],
            ["PedeJa", "pedidos_no_datalake", "service", "pedeja-datalake", { stat = "Sum", label = "data lake" }],
            ["PedeJa", "pedidos_agregados", "service", "pedeja-faturamento", { stat = "Sum", label = "faturamento" }]
          ]
        }
      },
      {
        type = "metric", x = 12, y = 2, width = 12, height = 6,
        properties = {
          title  = "Latencia (iterator age) dos 2 consumidores - ms",
          region = "us-east-1",
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", aws_lambda_function.datalake.function_name, { stat = "Average", label = "data lake" }],
            ["...", aws_lambda_function.faturamento.function_name, { stat = "Average", label = "faturamento" }]
          ]
        }
      },
      {
        type = "metric", x = 0, y = 8, width = 24, height = 6,
        properties = {
          title  = "Negocio - faturamento em tempo real por cidade",
          region = "us-east-1",
          view   = "timeSeries",
          metrics = [
            ["PedeJa", "faturamento_tempo_real", "service", "pedeja-faturamento", "cidade", "Sao Paulo", { stat = "Sum" }],
            ["...", "cidade", "Rio de Janeiro", { stat = "Sum" }],
            ["...", "cidade", "Curitiba", { stat = "Sum" }],
            ["...", "cidade", "Belo Horizonte", { stat = "Sum" }]
          ]
        }
      }
    ]
  })
}
