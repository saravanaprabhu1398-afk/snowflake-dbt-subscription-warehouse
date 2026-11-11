# Copy to terraform.tfvars (git-ignored) and edit. Values below are sized for a
# Snowflake trial account; production defaults are in variables.tf.
landing_bucket_name = "<globally-unique-name>-subscription-landing"
aws_region          = "eu-west-1" # same region as the Snowflake account (SELECT CURRENT_REGION())
environment         = "prod"

# Public half of the SVC_DBT key pair (see docs/snowflake-deployment.md).
dbt_public_key_path = "~/.snowflake/keys/svc_dbt.pub"

# Trial guardrails: one XSMALL size everywhere, no multi-cluster, small monthly quotas.
warehouse_size_override = "XSMALL"
bi_max_clusters         = 1
monthly_credit_quota = {
  transform = 20
  bi        = 5
}

# Trial only: allow `terraform destroy` to delete the bucket with its files.
force_destroy_bucket = true

# Snowflake user names e-mailed by the resource monitors (their e-mail must be verified).
notify_users = ["<YOUR_SNOWFLAKE_ADMIN_USER>"]
