# DMARC Visualizer Terraform Configuration

This directory contains the Terraform configuration for deploying the DMARC Visualizer. Defaults to **craniumcafe.com** in the production environment.

## Overview

- **Purpose:**  
  Collect, parse, and visualize DMARC aggregate reports for the domain using the [parsedmarc](https://domainaware.github.io/parsedmarc/index.html) tool and a Grafana dashboard.

- **Infrastructure:**  
  - S3 bucket for DMARC report storage
  - Grafana dashboard for visualization
  - Google OAuth for secure access
  - All secrets managed via AWS SSM Parameter Store

## Key Parameters

| Name                              | Description                                                      | Example Value                |
|------------------------------------|------------------------------------------------------------------|------------------------------|
| `bucket_name`                     | S3 bucket where DMARC reports are archived                       | `ses-email-archive-d99f0d87` |
| `domain`                          | Domain for which DMARC reports are visualized                    | `craniumcafe.com`            |
| `grafana_hostname`                | Public hostname for the Grafana dashboard                        | `dmarc.craniumcafe.com`      |
| `grafana_google_allowed_domains`  | Restricts Grafana login to users from this domain                | `craniumcafe.com`            |
| `grafana_google_client_id`        | Google OAuth client ID (from AWS SSM)                            | (from SSM)                   |
| `grafana_google_client_secret`    | Google OAuth client secret (from AWS SSM)                        | (from SSM)                   |
| `vpc_name`                        | Name of the VPC for deployment                                   | `conexed`                    |

## How It Works

1. **DMARC Reports Collection:**  
   External mail servers send DMARC aggregate reports to a mailbox for the domain (e.g., `rua=mailto:dmarc@craniumcafe.com`).

2. **Archival in S3:**  
   Reports are collected and stored in the specified S3 bucket.

3. **Parsing and Visualization:**  
   The `dmarc-visualizer` module fetches, parses (using [parsedmarc](https://domainaware.github.io/parsedmarc/index.html)), and stores the data for visualization in Grafana.

4. **Access Control:**  
   Grafana is secured with Google OAuth, restricted to users from the specified domain.

## Usage

- **Initialize Terraform:**
  ```sh
  terraform init
  ```
- **Plan and Apply:**
  ```sh
  terraform plan
  terraform apply
  ```

- **Apply from the Project Root with a Targeted Directory:**
  ```sh
  terraform -chdir=terraform/live/prod/craniumcafe.com/dmarc-visualizer apply
  ```
  **Explanation:**  
  The `-chdir` flag tells Terraform to use the configuration in the specified directory (`terraform/live/prod/craniumcafe.com/dmarc-visualizer`), regardless of your current working directory.  
  This is especially useful in a multi-environment or modular setup, keeping your project root clean and making it easy to target specific environments.  
  This command will initialize, plan, and apply the infrastructure for the `prod` environment of the `craniumcafe.com` deployment.

  **Tip:**  
  To deploy a different environment or domain, simply change the path after `-chdir=`.

## References

- [parsedmarc documentation](https://domainaware.github.io/parsedmarc/index.html)
- Internal module: `modules/dmarc-visualizer`

---

**For questions or changes, see the module source or contact the infrastructure team.**