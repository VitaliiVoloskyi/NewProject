# What the three Terraform files share, and what they read from the stacks that are still
# CloudFormation (ecr, backend, frontend, certificate, github-oidc).

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "aws_cloudformation_stack" "ecr" {
  name = "${var.project_name}-ecr"
}

data "aws_cloudformation_stack" "backend" {
  name = "${var.project_name}-backend"
}

# The API function: the report builder reads the same database with its DATABASE_URL.
data "aws_lambda_function" "api" {
  function_name = data.aws_cloudformation_stack.backend.outputs["FunctionName"]
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  backend    = data.aws_cloudformation_stack.backend.outputs

  # The builder and the parser run the backend's code at its `app` target, with a plain handler.
  initial_image_uri = "${data.aws_cloudformation_stack.ecr.outputs["RepositoryUri"]}:${var.initial_image_tag}"
}
