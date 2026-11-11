terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
    snowflake = {
      source  = "snowflakedb/snowflake"
      version = "~> 2.0"
    }
  }
  # Remote state (example). Not configured here: this repo is code-only.
  # backend "s3" {
  #   bucket         = "my-tf-state"
  #   key            = "subscription-warehouse/terraform.tfstate"
  #   region         = "eu-west-1"
  #   dynamodb_table = "tf-locks"
  # }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      project     = "subscription-warehouse"
      environment = var.environment
      managed_by  = "terraform"
    }
  }
}

# Credentials come from the environment, never from this repo:
#   SNOWFLAKE_ORGANIZATION_NAME, SNOWFLAKE_ACCOUNT_NAME, SNOWFLAKE_USER,
#   SNOWFLAKE_AUTHENTICATOR=SNOWFLAKE_JWT, SNOWFLAKE_PRIVATE_KEY (PEM contents).
# `make tf-plan` / `make tf-apply` export these from the variables in docs/snowflake-deployment.md.
locals {
  snowflake_preview_features = [
    "snowflake_pipe_resource",
    "snowflake_table_resource",
  ]
}

# Default provider: SYSADMIN owns databases, schemas, RAW tables, stage, pipes.
provider "snowflake" {
  role                     = "SYSADMIN"
  preview_features_enabled = local.snowflake_preview_features
}

# ACCOUNTADMIN only for what requires it: integration, monitors, warehouses, roles, users, grants.
provider "snowflake" {
  alias                    = "admin"
  role                     = "ACCOUNTADMIN"
  preview_features_enabled = local.snowflake_preview_features
}
