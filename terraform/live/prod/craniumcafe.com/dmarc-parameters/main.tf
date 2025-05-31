# This file requires the Google credentials file to be added to the directory before running.
# The credentials file is stored in 1Password and should be retrieved and placed in the same directory as this file.
# The file name should be: client_secret_725814421154-fpv71qlq53g9mvs6eb1do1hgl20jp98c.apps.googleusercontent.com.json

terraform {
  required_version = ">= 1.11.4"
  backend "s3" {
    bucket       = "terraform-state-293627946929-us-west-2"
    key          = "prod/craniumcafe.com/dmarc-parameters/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
}

data "local_file" "grafana_google_creds" {
  filename = "./client_secret_725814421154-fpv71qlq53g9mvs6eb1do1hgl20jp98c.apps.googleusercontent.com.json"
}

locals {
  google_creds  = jsondecode(data.local_file.grafana_google_creds.content)
  client_id     = local.google_creds.web.client_id
  client_secret = local.google_creds.web.client_secret
}

resource "aws_ssm_parameter" "grafana_google_client_id" {
  name  = "/dmarc-visualizer/grafana/google_oauth_client_id"
  type  = "String"
  value = local.client_id
}

resource "aws_ssm_parameter" "grafana_google_client_secret" {
  name  = "/dmarc-visualizer/grafana/google_oauth_client_secret"
  type  = "SecureString"
  value = local.client_secret
}
