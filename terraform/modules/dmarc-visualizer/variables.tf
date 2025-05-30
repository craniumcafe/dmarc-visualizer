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

locals {
  s3_path = "${var.domain}/dmarc"
}
