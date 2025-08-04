terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    docker = {
      source  = "kreuzwerker/docker"
      version = "~> 3.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

data "aws_ecr_authorization_token" "token" {}

provider "docker" {
  registry_auth {
    address  = aws_ecr_repository.parsedmarc.repository_url
    username = "AWS"
    password = data.aws_ecr_authorization_token.token.authorization_token
  }
}

resource "aws_ecr_repository" "parsedmarc" {
  name = "parsedmarc"

  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_image" "parsedmarc" {
  name = "${aws_ecr_repository.parsedmarc.repository_url}:latest"
  build {
    context    = "../../../../../parsedmarc"
    dockerfile = "Dockerfile"
  }
}

resource "aws_ecr_repository" "grafana" {
  name = "grafana"

  lifecycle {
    prevent_destroy = true
  }
}

resource "docker_image" "grafana" {
  name = "${aws_ecr_repository.grafana.repository_url}:latest"
  build {
    context    = "../../../../../grafana"
    dockerfile = "Dockerfile"
  }
}

output "parsedmarc_image_uri" {
  value = docker_image.parsedmarc.name
}

output "grafana_image_uri" {
  value = docker_image.grafana.name
}
