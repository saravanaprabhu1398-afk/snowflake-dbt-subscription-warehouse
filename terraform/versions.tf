terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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

# Credentials from env: SNOWFLAKE_ORGANIZATION_NAME, SNOWFLAKE_ACCOUNT_NAME, SNOWFLAKE_USER,
# SNOWFLAKE_AUTHENTICATOR=SNOWFLAKE_JWT, SNOWFLAKE_PRIVATE_KEY. Nothing in this repo.
provider "snowflake" {
  role = "ACCOUNTADMIN"
  preview_features_enabled = [
    "snowflake_stage_external_s3_resource",
    "snowflake_pipe_resource",
    "snowflake_storage_integration_aws_resource",
    "snowflake_file_format_parquet_resource",
  ]
}
