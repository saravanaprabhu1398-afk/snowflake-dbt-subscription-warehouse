-- Deployed by Terraform (terraform/snowflake.tf, terraform/aws.tf). Kept as the readable SQL reference.
-- =============================================================================
-- 01 External stage over the S3 landing zone.
-- Layout written by the producers (and by generator/generate.py locally):
--   s3://<bucket>/landing/<feed>/_load_date=YYYY-MM-DD/<file>.parquet
-- feeds: customers, plans, subscription_events, payments, feature_usage
-- =============================================================================

use role accountadmin;

create storage integration if not exists s3_landing_int
    type = external_stage
    storage_provider = 'S3'
    enabled = true
    storage_aws_role_arn = 'arn:aws:iam::<aws_account_id>:role/snowflake-landing-reader'
    storage_allowed_locations = ('s3://<landing_bucket>/landing/');

-- Returns STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID for the IAM role trust
-- policy (Terraform wires these automatically, see terraform/aws.tf).
desc integration s3_landing_int;

grant usage on integration s3_landing_int to role loader;

use role loader;
use schema raw.landing;

create file format if not exists ff_parquet
    type = parquet
    use_logical_type = true;

create stage if not exists landing_stage
    storage_integration = s3_landing_int
    url = 's3://<landing_bucket>/landing/'
    file_format = ff_parquet
    comment = 'Landing zone, one prefix per feed, partitioned by _load_date';

list @landing_stage/subscription_events/;
