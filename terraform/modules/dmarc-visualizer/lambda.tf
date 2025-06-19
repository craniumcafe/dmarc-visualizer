resource "aws_iam_role" "lambda_exec" {
  name = "dmarc-lambda-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Action = "sts:AssumeRole",
      Effect = "Allow",
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_policy" "lambda_policy" {
  name = "dmarc-lambda-policy"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "s3:ListBucket",
          "s3:GetObject",
          "s3:DeleteObject"
        ],
        Resource = [
          "arn:aws:s3:::${var.bucket_name}",
          "arn:aws:s3:::${var.bucket_name}/${local.s3_path}*"
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "ecs:RunTask",
          "ecs:Describe*"
        ],
        Resource = "*"
      },
      {
        Effect = "Allow",
        Action = [
          "iam:PassRole"
        ],
        Resource = [
          aws_iam_role.ecs_task_role.arn,
          aws_iam_role.ecs_task_execution_role.arn
        ]
      },
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Effect = "Allow",
        Action = [
          "ecs:UpdateService"
        ],
        Resource = "arn:aws:ecs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:service/${aws_ecs_cluster.dmarc.name}/parsedmarc"
      },
      {
        Effect = "Allow",
        Action = [
          "es:ESHttp*"
        ],
        Resource = "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.current.account_id}:domain/${aws_opensearch_domain.dmarc.domain_name}/*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_policy_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_policy.arn
}

resource "aws_lambda_function" "dmarc_trigger" {
  filename         = "${path.module}/lambda/dmarc_trigger.zip"
  function_name    = "dmarc-s3-trigger"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "dmarc_trigger.lambda_handler"
  runtime          = "python3.12"
  source_code_hash = filebase64sha256("${path.module}/lambda/dmarc_trigger.zip")
  environment {
    variables = {
      BUCKET_NAME      = var.bucket_name
      S3_PATH          = local.s3_path
      CLUSTER_ARN      = aws_ecs_cluster.dmarc.arn
      TASK_DEF_ARN     = aws_ecs_task_definition.parsedmarc.arn
      SUBNETS          = join(",", [aws_subnet.dmarc.id])
      SECURITY_GROUPS  = join(",", [aws_security_group.dmarc.id])
      TASK_ROLE_ARN    = aws_iam_role.ecs_task_role.arn
      OPENSEARCH_HOST  = aws_opensearch_domain.dmarc.endpoint
      OPENSEARCH_INDEX = "dmarc_aggregate-*"
      OPENSEARCH_PORT  = 443
    }
  }
  timeout = 900 # 15 minutes
}

resource "aws_lambda_permission" "allow_sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dmarc_trigger.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.ses_notifications.arn
}

resource "aws_sns_topic_subscription" "lambda_sub" {
  topic_arn = aws_sns_topic.ses_notifications.arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.dmarc_trigger.arn
}

resource "aws_lambda_permission" "allow_s3" {
  statement_id  = "AllowExecutionFromS3"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dmarc_trigger.arn
  principal     = "s3.amazonaws.com"
  source_arn    = data.aws_s3_bucket.dmarc.arn
}
