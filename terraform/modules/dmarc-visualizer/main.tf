data "aws_caller_identity" "current" {}

data "aws_ses_active_receipt_rule_set" "main" {}

# data query for vpc id
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

# create ecs subnet
resource "aws_subnet" "dmarc" {
  vpc_id            = data.aws_vpc.main.id
  cidr_block        = "10.0.0.0/24"
  availability_zone = "us-east-1a"
}

# create ecs security group
resource "aws_security_group" "dmarc" {
  name        = "dmarc-security-group"
  description = "Security group for DMARC visualizer"
  vpc_id      = data.aws_vpc.main.id
}


resource "aws_ses_receipt_rule" "s3_rule" {
  name          = "dmarc-${var.domain}"
  rule_set_name = data.aws_ses_active_receipt_rule_set.main.rule_set_name
  recipients    = ["dmarc@${var.domain}"]
  enabled       = true
  scan_enabled  = true

  s3_action {
    position          = 1
    bucket_name       = var.bucket_name
    object_key_prefix = "${var.domain}/dmarc/"
    topic_arn         = aws_sns_topic.ses_notifications.arn
  }

  stop_action {
    position = 2
    scope    = "RuleSet"
  }

  tls_policy = "Require"
}

resource "aws_sns_topic" "ses_notifications" {
  name = "dmarc-${replace(var.domain, ".", "-")}"
}

# ECS Fargate cluster to run parsedmarc / visualizer / grafana
resource "aws_ecs_cluster" "dmarc" {
  name = "dmarc-cluster"
}

# OpenSearch (Elasticsearch)
resource "aws_opensearch_domain" "dmarc" {
  domain_name    = "dmarc-domain"
  engine_version = "OpenSearch_2.11"
  cluster_config {
    instance_type  = "t3.small.search"
    instance_count = 1
  }
  ebs_options {
    ebs_enabled = true
    volume_size = 10
    volume_type = "gp2"
  }
  access_policies = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { "AWS" : "*" }
        Action    = ["es:*"]
        Resource  = "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.current.account_id}:domain/dmarc-domain/*"
      }
    ]
  })
}

# Grafana
resource "aws_ecs_task_definition" "grafana" {
  family                   = "grafana"
  container_definitions    = file("${path.module}/grafana-task-definition.json")
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
  requires_compatibilities = ["FARGATE"]
}

resource "aws_ecs_service" "grafana" {
  name            = "grafana"
  cluster         = aws_ecs_cluster.dmarc.id
  task_definition = aws_ecs_task_definition.grafana.arn
  desired_count   = 1

  network_configuration {
    subnets          = [aws_subnet.dmarc.id]
    security_groups  = [aws_security_group.dmarc.id]
    assign_public_ip = true
  }
}

# Parsedmarc
resource "aws_ecs_task_definition" "parsedmarc" {
  family = "parsedmarc"
  container_definitions = templatefile("${path.module}/parsedmarc-task-definition.json.tmpl", {
    opensearch_endpoint = aws_opensearch_domain.dmarc.endpoint
    s3_bucket           = var.bucket_name
    aws_region          = var.aws_region
    s3_path             = local.s3_path
    parsedmarc_ini_path = var.parsedmarc_ini_path
  })
  execution_role_arn = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn      = aws_iam_role.ecs_task_role.arn
}

resource "aws_ecs_service" "parsedmarc" {
  name            = "parsedmarc"
  cluster         = aws_ecs_cluster.dmarc.id
  task_definition = aws_ecs_task_definition.parsedmarc.arn
  desired_count   = 1

  network_configuration {
    subnets          = [aws_subnet.dmarc.id]
    security_groups  = [aws_security_group.dmarc.id]
    assign_public_ip = true
  }
}

resource "aws_s3_bucket_notification" "dmarc_reports" {
  bucket = var.bucket_name

  topic {
    topic_arn     = aws_sns_topic.ses_notifications.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = local.s3_path
  }
}

output "opensearch_endpoint" {
  value = aws_opensearch_domain.dmarc.endpoint
}
