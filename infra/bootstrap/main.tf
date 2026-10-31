# Bootstrap: lets HCP Terraform reach AWS without stored keys (dynamic credentials). Each run
# gets an OIDC token signed by app.terraform.io, which AWS trusts through the IAM OIDC provider
# below, and exchanges it for temporary credentials of one role that expire with the run.
#
# This is the one piece that must exist before HCP Terraform can do anything, so it is applied
# once from a laptop with your own credentials, and its state stays local (gitignored):
#
#   terraform -chdir=infra/bootstrap init
#   terraform -chdir=infra/bootstrap apply
#
# Then set TFC_AWS_PROVIDER_AUTH=true and TFC_AWS_RUN_ROLE_ARN=<role_arn> in the workspace.

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      PROJECT_NAME = var.project_name
      ManagedBy    = "terraform"
    }
  }
}

variable "project_name" {
  type    = string
  default = "spry"
}

variable "tfc_organization" {
  type        = string
  description = "HCP Terraform organization"
}

variable "tfc_workspace" {
  type        = string
  default     = "spry-dev"
  description = "The only workspace allowed to assume the role"
}

data "tls_certificate" "tfc" {
  url = "https://app.terraform.io"
}

resource "aws_iam_openid_connect_provider" "tfc" {
  url             = "https://app.terraform.io"
  client_id_list  = ["aws.workload.identity"]
  thumbprint_list = [data.tls_certificate.tfc.certificates[0].sha1_fingerprint]
}

resource "aws_iam_role" "tfc" {
  name = "${var.project_name}-hcp-terraform"

  # One workspace of one organization, any project, both run phases (plan and apply).
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.tfc.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "app.terraform.io:aud" = "aws.workload.identity" }
        StringLike = {
          "app.terraform.io:sub" = "organization:${var.tfc_organization}:project:*:workspace:${var.tfc_workspace}:run_phase:*"
        }
      }
    }]
  })
}

# For the class project. A real team narrows this to the services the workspace manages
# (Cognito, S3, SQS, Lambda, Scheduler, IAM roles named spry-*, Logs, Budgets, EC2 endpoints),
# and gives the plan phase a read-only role of its own.
resource "aws_iam_role_policy_attachment" "tfc" {
  role       = aws_iam_role.tfc.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "role_arn" {
  value = aws_iam_role.tfc.arn
}
