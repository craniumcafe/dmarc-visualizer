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

module "dmarc-visualizer" {
  source = "../../../../modules/dmarc-visualizer"

  bucket_name = "ses-email-archive-d99f0d87"
}
