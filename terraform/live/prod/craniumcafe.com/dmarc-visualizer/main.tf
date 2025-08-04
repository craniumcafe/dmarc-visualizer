# -----------------------------------------------------------------------------
# DMARC Visualizer Infrastructure for craniumcafe.com (Production)
#
# This Terraform configuration deploys the DMARC Visualizer stack for
# craniumcafe.com. It provisions resources to collect, parse, and visualize
# DMARC aggregate reports using the dmarc-visualizer module.
#
# Key parameters:
#   - bucket_name: S3 bucket where DMARC reports are archived
#   - domain:      Domain for which DMARC reports are visualized
#   - grafana_hostname: Public hostname for the Grafana dashboard
#   - grafana_google_allowed_domains: Restricts dashboard access to this domain
#
# Google OAuth credentials for Grafana are securely fetched from AWS SSM.
#
# For more details, see README.md in the module directory and the parsedmarc docs:
# https://domainaware.github.io/parsedmarc/index.html
# -----------------------------------------------------------------------------

terraform {
  required_version = ">= 1.11.4"
  backend "s3" {
    bucket       = "terraform-state-293627946929-us-west-2"
    key          = "prod/craniumcafe.com/dmarc-visualizer/terraform.tfstate"
    region       = "us-west-2"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
}

data "aws_ssm_parameter" "grafana_google_client_id" {
  name            = "/dmarc-visualizer/grafana/google_oauth_client_id"
  with_decryption = true
}

data "aws_ssm_parameter" "grafana_google_client_secret" {
  name            = "/dmarc-visualizer/grafana/google_oauth_client_secret"
  with_decryption = true
}

module "dmarc-visualizer" {
  source = "../../../../modules/dmarc-visualizer"

  bucket_name                    = "ses-email-archive-d99f0d87"
  domain                         = "craniumcafe.com"
  grafana_google_allowed_domains = "conexed.com"
  grafana_hostname               = "dmarc.craniumcafe.com"
  grafana_google_client_id       = data.aws_ssm_parameter.grafana_google_client_id.value
  grafana_google_client_secret   = data.aws_ssm_parameter.grafana_google_client_secret.value
  subnet_cidr_block              = "172.9.4.0/24"
  subnet_cidr_block_2            = "172.9.5.0/24"
  vpc_name                       = "conexed"
}
