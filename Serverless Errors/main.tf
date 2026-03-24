###############################################################
# BROKEN LAB — Lambda + API Gateway + SQS
#
# Scenario: A simple serverless pipeline. An API Gateway
# endpoint accepts POST requests and writes messages to an
# SQS queue. A Lambda function is triggered by the queue,
# processes each message, and logs the result to CloudWatch.
#
# When you POST to the API endpoint, you expect a 200 response
# and a processed log entry in CloudWatch within a few seconds.
# Something is broken — find and fix it.
###############################################################

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "ap-southeast-2"
}

###############################################################
# SQS QUEUE
###############################################################

resource "aws_sqs_queue" "messages" {
  name                       = "lab-messages"
  visibility_timeout_seconds = 30
  message_retention_seconds  = 86400

  tags = { Name = "lab-messages" }
}

###############################################################
# IAM ROLE FOR LAMBDA
###############################################################

resource "aws_iam_role" "lambda_role" {
  name = "lab-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

# Basic Lambda execution — allows writing logs to CloudWatch
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# BUG 1: The Lambda needs permission to READ from SQS
# (ReceiveMessage, DeleteMessage, GetQueueAttributes) so it
# can consume messages from the queue. Without this, the
# event source mapping will fail with an access denied error
# and messages will sit in the queue unprocessed.
# The SQS policy attachment is missing entirely.

###############################################################
# LAMBDA FUNCTION
###############################################################

resource "aws_lambda_function" "processor" {
  filename         = "${path.module}/lambda.zip"
  function_name    = "lab-processor"
  role             = aws_iam_role.lambda_role.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  source_code_hash = filebase64sha256("${path.module}/lambda.zip")
  timeout          = 10

  environment {
    variables = {
      QUEUE_URL = aws_sqs_queue.messages.url
    }
  }

  tags = { Name = "lab-processor" }
}

# Trigger Lambda from SQS
# BUG 2: The batch_size is set to 1, which is fine, but
# function_response_types is missing "ReportBatchItemFailures".
# More critically, the event source mapping is pointing at the
# wrong ARN — it references the Lambda function ARN instead of
# the SQS queue ARN as the event_source_arn. Lambda will never
# receive any SQS events.
resource "aws_lambda_event_source_mapping" "sqs_trigger" {
  event_source_arn = aws_lambda_function.processor.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 1
  enabled          = true
}

###############################################################
# API GATEWAY
###############################################################

resource "aws_apigatewayv2_api" "main" {
  name          = "lab-api"
  protocol_type = "HTTP"
  tags          = { Name = "lab-api" }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
}

# IAM role allowing API Gateway to send messages to SQS
resource "aws_iam_role" "apigw_sqs_role" {
  name = "lab-apigw-sqs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "apigw_sqs_policy" {
  name = "lab-apigw-sqs-policy"
  role = aws_iam_role.apigw_sqs_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["sqs:SendMessage"]
      Resource = aws_sqs_queue.messages.arn
    }]
  })
}

# API Gateway SQS integration
resource "aws_apigatewayv2_integration" "sqs" {
  api_id             = aws_apigatewayv2_api.main.id
  integration_type   = "AWS_PROXY"
  integration_subtype = "SQS-SendMessage"
  credentials_arn    = aws_iam_role.apigw_sqs_role.arn

  request_parameters = {
    "QueueUrl"    = aws_sqs_queue.messages.url
    "MessageBody" = "$request.body"
  }

  payload_format_version = "1.0"
}

# BUG 3: The route is defined as "POST /messages" but the
# integration above is correctly set up. However the route_key
# uses "GET" instead of "POST", so POST requests from clients
# will get a 404 — there is no POST route registered.
resource "aws_apigatewayv2_route" "post_message" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /messages"
  target    = "integrations/${aws_apigatewayv2_integration.sqs.id}"
}

###############################################################
# LAMBDA ZIP — write inline for the lab
# In a real project this would come from your source code.
###############################################################

data "archive_file" "lambda" {
  type        = "zip"
  output_path = "${path.module}/lambda.zip"

  source {
    content  = <<-EOF
      exports.handler = async (event) => {
        console.log('Received event:', JSON.stringify(event, null, 2));
        for (const record of event.Records) {
          const body = record.body;
          console.log('Processing message:', body);
        }
        return { statusCode: 200 };
      };
    EOF
    filename = "index.js"
  }
}

###############################################################
# OUTPUTS
###############################################################

output "api_endpoint" {
  description = "POST to this URL to send a message"
  value       = "${aws_apigatewayv2_stage.default.invoke_url}/messages"
}

output "sqs_queue_url" {
  description = "SQS queue URL — check message count here"
  value       = aws_sqs_queue.messages.url
}

output "lambda_function_name" {
  description = "Lambda function name — check CloudWatch logs here"
  value       = aws_lambda_function.processor.function_name
}
