data "aws_caller_identity" "current" {}

data "aws_ses_active_receipt_rule_set" "main" {}

# data query for vpc id
data "aws_vpc" "main" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_s3_bucket" "dmarc" {
  bucket = var.bucket_name
}

# get internet gateway id
data "aws_internet_gateway" "main" {
  filter {
    name   = "attachment.vpc-id"
    values = [data.aws_vpc.main.id]
  }
}

# create ecs subnet
resource "aws_subnet" "dmarc" {
  vpc_id            = data.aws_vpc.main.id
  cidr_block        = var.subnet_cidr_block
  availability_zone = "us-east-1a"
}

# create ecs subnet
resource "aws_subnet" "dmarc_2" {
  vpc_id            = data.aws_vpc.main.id
  cidr_block        = var.subnet_cidr_block_2
  availability_zone = "us-east-1b" # or another AZ in your region
}

# create ecs security group
resource "aws_security_group" "dmarc" {
  name        = "dmarc-security-group"
  description = "Security group for DMARC visualizer"
  vpc_id      = data.aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group_rule" "allow_alb_https" {
  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = ["0.0.0.0/0"]
  security_group_id = aws_security_group.dmarc.id
}

resource "aws_security_group_rule" "allow_grafana_from_alb" {
  type                     = "ingress"
  from_port                = 3000
  to_port                  = 3000
  protocol                 = "tcp"
  source_security_group_id = aws_security_group.dmarc.id # replace with your ALB SG resource
  security_group_id        = aws_security_group.dmarc.id
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
    instance_type  = "m5.large.search"
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
        Effect = "Allow"
        Principal = {
          AWS = [
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root",
            "arn:aws:iam::${data.aws_caller_identity.current.account_id}:role/ecsTaskRole"
          ]
        }
        Action   = "es:*"
        Resource = "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.current.account_id}:domain/dmarc-domain/*"
      }
    ]
  })

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_search_slow.arn
    log_type                 = "SEARCH_SLOW_LOGS"
    enabled                  = true
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_index_slow.arn
    log_type                 = "INDEX_SLOW_LOGS"
    enabled                  = true
  }

  log_publishing_options {
    cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_error.arn
    log_type                 = "ES_APPLICATION_LOGS"
    enabled                  = true
  }

  # log_publishing_options {
  #   cloudwatch_log_group_arn = aws_cloudwatch_log_group.opensearch_audit.arn
  #   log_type                 = "AUDIT_LOGS"
  #   enabled                  = true
  # }

  cognito_options {
    enabled          = true
    identity_pool_id = aws_cognito_identity_pool.opensearch.id
    role_arn         = aws_iam_role.opensearch_cognito_auth.arn
    user_pool_id     = aws_cognito_user_pool.opensearch.id
  }
}

# Grafana
resource "aws_ecs_task_definition" "grafana" {
  family = "grafana"
  container_definitions = jsonencode([
    {
      name      = "grafana"
      image     = docker_image.grafana.name
      essential = true
      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
        }
      ]
      memory = 512
      cpu    = 256
      environment = [
        { name = "ECS_CLUSTER", value = aws_ecs_cluster.dmarc.name },
        { name = "GF_AUTH_GOOGLE_CLIENT_ID", value = var.grafana_google_client_id },
        { name = "GF_AUTH_GOOGLE_CLIENT_SECRET", value = var.grafana_google_client_secret },
        { name = "GF_AUTH_GOOGLE_SCOPES", value = "https://www.googleapis.com/auth/userinfo.profile https://www.googleapis.com/auth/userinfo.email" },
        { name = "GF_AUTH_GOOGLE_ALLOWED_DOMAINS", value = var.grafana_google_allowed_domains },
        { name = "GF_AUTH_GOOGLE_ENABLED", value = "true" },
        { name = "GF_SERVER_ROOT_URL", value = "https://${var.grafana_hostname}" }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = "/ecs/grafana"
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
    }
  ])
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
}

resource "aws_ecs_service" "grafana" {
  name                   = "grafana"
  cluster                = aws_ecs_cluster.dmarc.id
  task_definition        = aws_ecs_task_definition.grafana.arn
  desired_count          = 1
  launch_type            = "FARGATE"
  enable_execute_command = true

  network_configuration {
    subnets          = [aws_subnet.dmarc.id, aws_subnet.dmarc_2.id]
    security_groups  = [aws_security_group.dmarc.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.grafana.arn
    container_name   = "grafana"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener.grafana_https]
}

# Parsedmarc
# Note: The parsedmarc ECS task definition uses a SigV4 proxy sidecar (aws-es-proxy) to enable IAM-authenticated access to OpenSearch.
resource "aws_ecs_task_definition" "parsedmarc" {
  family = "parsedmarc"
  container_definitions = templatefile("${path.module}/parsedmarc-task-definition.json.tmpl", {
    image               = docker_image.parsedmarc.name
    opensearch_endpoint = aws_opensearch_domain.dmarc.endpoint
    s3_bucket           = var.bucket_name
    aws_region          = var.aws_region
    s3_path             = local.s3_path
    parsedmarc_ini_path = var.parsedmarc_ini_path
  })
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_role.arn
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"
}

resource "aws_ecs_service" "parsedmarc" {
  name            = "parsedmarc"
  cluster         = aws_ecs_cluster.dmarc.id
  task_definition = aws_ecs_task_definition.parsedmarc.arn
  desired_count   = 0
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = [aws_subnet.dmarc.id, aws_subnet.dmarc_2.id]
    security_groups  = [aws_security_group.dmarc.id]
    assign_public_ip = true
  }
  # The service runs parsedmarc with a SigV4 proxy sidecar for OpenSearch
}

resource "aws_s3_bucket_notification" "dmarc_reports" {
  bucket = data.aws_s3_bucket.dmarc.id

  lambda_function {
    lambda_function_arn = aws_lambda_function.dmarc_trigger.arn
    events              = ["s3:ObjectCreated:*"]
    filter_prefix       = local.s3_path
  }

  depends_on = [aws_lambda_permission.allow_s3]
}

resource "aws_route_table" "dmarc_public" {
  vpc_id = data.aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = data.aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "dmarc_1" {
  subnet_id      = aws_subnet.dmarc.id
  route_table_id = aws_route_table.dmarc_public.id
}

resource "aws_route_table_association" "dmarc_2" {
  subnet_id      = aws_subnet.dmarc_2.id
  route_table_id = aws_route_table.dmarc_public.id
}

resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/dmarc-visualizer"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "parsedmarc" {
  name              = "/ecs/parsedmarc"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "grafana" {
  name              = "/ecs/grafana"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "opensearch_search_slow" {
  name              = "/aws/opensearch/dmarc/search-slow"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "opensearch_index_slow" {
  name              = "/aws/opensearch/dmarc/index-slow"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "opensearch_error" {
  name              = "/aws/opensearch/dmarc/error"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "opensearch_audit" {
  name              = "/aws/opensearch/dmarc/audit"
  retention_in_days = 14
}

data "template_file" "grafana_datasource" {
  template = file("${path.module}/grafana-datasource.yaml.tmpl")
  vars = {
    opensearch_endpoint = aws_opensearch_domain.dmarc.endpoint
    aws_region          = var.aws_region
  }
}

resource "local_file" "grafana_datasource" {
  content  = data.template_file.grafana_datasource.rendered
  filename = "${path.module}/build/grafana-datasource.yaml"
}

data "template_file" "parsedmarc_entrypoint" {
  template = file("${path.module}/parsedmarc-entrypoint.sh.tftpl")
  vars = {
    s3_bucket  = var.bucket_name
    s3_path    = local.s3_path
    aws_region = var.aws_region
  }
}

resource "local_file" "parsedmarc_entrypoint" {
  content  = data.template_file.parsedmarc_entrypoint.rendered
  filename = "${path.module}/build/parsedmarc-entrypoint.sh"
}

resource "random_string" "suffix" {
  length  = 8
  special = false
  upper   = false
  lower   = true
  numeric = true
}

resource "aws_cognito_user_pool" "opensearch" {
  name = "opensearch-user-pool"
}

resource "aws_cognito_user_pool_client" "opensearch" {
  name            = "opensearch-user-pool-client"
  user_pool_id    = aws_cognito_user_pool.opensearch.id
  generate_secret = false
}

resource "aws_cognito_user_pool_domain" "opensearch" {
  domain       = "dmarc-opensearch-${random_string.suffix.result}"
  user_pool_id = aws_cognito_user_pool.opensearch.id
}

resource "aws_cognito_identity_pool" "opensearch" {
  identity_pool_name               = "opensearch-identity-pool"
  allow_unauthenticated_identities = false

  cognito_identity_providers {
    client_id     = "44l2tg5khhker4rrsqaphh6tbi"
    provider_name = "cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.opensearch.id}"
  }
  cognito_identity_providers {
    client_id     = "3amn4uti98nm2tfj9881mhac8i"
    provider_name = "cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.opensearch.id}"
  }
}

resource "aws_iam_role" "opensearch_cognito_auth" {
  name = "opensearch-cognito-auth-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "es.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
      {
        Effect = "Allow"
        Principal = {
          Federated = "cognito-identity.amazonaws.com"
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.opensearch.id
          },
          "ForAnyValue:StringLike" = {
            "cognito-identity.amazonaws.com:amr" = "authenticated"
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "opensearch_cognito_auth_policy" {
  name = "opensearch-cognito-auth-policy"
  role = aws_iam_role.opensearch_cognito_auth.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = "es:ESHttp*"
        Resource = "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.current.account_id}:domain/dmarc-domain/*"
      }
    ]
  })
}

resource "aws_iam_role_policy" "opensearch_cognito_auth_describe_userpool" {
  name = "opensearch-cognito-auth-describe-userpool"
  role = aws_iam_role.opensearch_cognito_auth.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cognito-idp:DescribeUserPool"
        ]
        Resource = aws_cognito_user_pool.opensearch.arn
      }
    ]
  })
}

resource "aws_iam_role_policy" "opensearch_cognito_auth_describe_identitypool" {
  name = "opensearch-cognito-auth-describe-identitypool"
  role = aws_iam_role.opensearch_cognito_auth.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "cognito-identity:DescribeIdentityPool"
        ]
        Resource = aws_cognito_identity_pool.opensearch.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "opensearch_cognito_access" {
  role       = aws_iam_role.opensearch_cognito_auth.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonOpenSearchServiceCognitoAccess"
}

resource "aws_iam_role" "opensearch_identity_pool_auth" {
  name = "opensearch-identity-pool-auth-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "cognito-identity.amazonaws.com"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.opensearch.id
        },
        "ForAnyValue:StringLike" = {
          "cognito-identity.amazonaws.com:amr" = "authenticated"
        }
      }
    }]
  })
}

resource "aws_iam_role" "opensearch_identity_pool_unauth" {
  name = "opensearch-identity-pool-unauth-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Federated = "cognito-identity.amazonaws.com"
      }
      Action = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = {
          "cognito-identity.amazonaws.com:aud" = aws_cognito_identity_pool.opensearch.id
        },
        "ForAnyValue:StringLike" = {
          "cognito-identity.amazonaws.com:amr" = "unauthenticated"
        }
      }
    }]
  })
}

resource "aws_cognito_identity_pool_roles_attachment" "opensearch" {
  identity_pool_id = aws_cognito_identity_pool.opensearch.id
  roles = {
    authenticated   = aws_iam_role.opensearch_identity_pool_auth.arn
    unauthenticated = aws_iam_role.opensearch_identity_pool_unauth.arn
  }
}

resource "aws_iam_role_policy" "opensearch_identity_pool_auth_policy" {
  name = "opensearch-identity-pool-auth-policy"
  role = aws_iam_role.opensearch_identity_pool_auth.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "es:ESHttpGet",
          "es:ESHttpPost",
          "es:ESHttpPut",
          "es:ESHttpDelete"
        ]
        Resource = "arn:aws:es:${var.aws_region}:${data.aws_caller_identity.current.account_id}:domain/dmarc-domain/*"
      }
    ]
  })
}

output "opensearch_endpoint" {
  value = aws_opensearch_domain.dmarc.endpoint
}
