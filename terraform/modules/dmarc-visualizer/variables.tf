variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "domain" {
  description = "Root domain for SES and reporting"
  type        = string
  default     = "craniumcafe.com"
}

variable "parsedmarc_ini_path" {
  description = "Path to the parsedmarc.ini configuration file in the container"
  type        = string
  default     = "/parsedmarc.ini"
}

variable "bucket_name" {
  description = "Name of the S3 bucket to store DMARC reports"
  type        = string
}

variable "vpc_name" {
  description = "Name of the VPC to deploy the DMARC visualizer into"
  type        = string
  default     = "conexed"
}

variable "grafana_google_client_id" {
  description = "Google OAuth Client ID for Grafana SSO"
  type        = string
}

variable "grafana_google_client_secret" {
  description = "Google OAuth Client Secret for Grafana SSO"
  type        = string
  sensitive   = true
}

variable "grafana_google_allowed_domains" {
  description = "Comma-separated list of allowed Google domains for Grafana SSO (e.g. example.com)"
  type        = string
  default     = "conexed.com"
}

variable "grafana_hostname" {
  description = "The public hostname for Grafana (e.g., dmarc.craniumcafe.com)"
  type        = string
  default     = "dmarc.craniumcafe.com"
}

variable "subnet_cidr_block" {
  description = "CIDR block for the DMARC Visualizer subnet"
  type        = string
}

variable "subnet_cidr_block_2" {
  description = "CIDR block for the second DMARC Visualizer subnet"
  type        = string
  default     = null
}

locals {
  s3_path = "${var.domain}/dmarc"
}
