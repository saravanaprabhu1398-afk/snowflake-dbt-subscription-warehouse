# Deploying to Snowflake + AWS

This runbook deploys the warehouse to a real Snowflake account (Enterprise edition, tested
target: a trial account) with an S3 landing zone and auto-ingest Snowpipe.

```
generator ──► S3 landing/<feed>/_load_date=…/ ──(S3 event → SQS)──► Snowpipe ──► RAW.LANDING
                                                                                    │
GitHub Actions (daily) / make sf-build ── SVC_DBT (key pair) ── dbt build ──► ANALYTICS.{STAGING,SNAPSHOTS,CORE,SUBSCRIPTION,PRODUCT}
                                                                                    │
GOVERNANCE: tags, masking, row access, erasure task ────────────────────────────────┘
```

## Who owns what

| Layer | Tool | Role |
|---|---|---|
| S3 bucket, KMS key, IAM role, S3 → SQS notifications | Terraform (`terraform/aws.tf`) | your AWS profile |
| Storage integration, resource monitors, warehouses, roles, grants, `SVC_DBT` user | Terraform (`terraform/snowflake.tf`) | ACCOUNTADMIN |
| Databases, RAW tables, file format, stage, pipes | Terraform | SYSADMIN |
| Tags, masking + row access policies, erasure procedure + task, account monitor | SQL (`snowflake/04`, `06`) via `make sf-governance` | ACCOUNTADMIN |
| Everything in `ANALYTICS` | dbt (`--target prod`) | TRANSFORMER (as `SVC_DBT`) |

Nothing secret lives in the repo. Snowflake access is key-pair only; private keys stay in
`~/.snowflake/keys/` (and, for CI, a GitHub environment secret).

## Trial budget

A trial comes with about $400 of credit (roughly 100–130 credits on Enterprise, depending on
region). The trial settings in `terraform/example.tfvars` make every warehouse XSMALL
(1 credit/hour, billed per second after the first minute, suspended after 60 s idle) and cap
spend with monitors: 20 credits/month for transform, 5 for BI, 40 for the whole account
(`snowflake/06_account_guardrails.sql`). A full `dbt build` at 20k customers takes about a
minute of XSMALL time. Snowpipe and the daily erasure task are serverless/small and not
covered by monitors; `make sf-cost` shows them.

AWS cost at this size: one KMS key ($1/month) plus cents for S3 and requests.

## One-time steps you do yourself

These involve credentials, so they are yours, not the automation's.

1. **Key pairs** (unencrypted PKCS#8, as the dbt and Terraform providers expect):

   ```bash
   mkdir -p ~/.snowflake/keys && chmod 700 ~/.snowflake/keys && cd ~/.snowflake/keys
   openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out admin.p8 -nocrypt
   openssl rsa -in admin.p8 -pubout -out admin.pub
   openssl genrsa 2048 | openssl pkcs8 -topk8 -inform PEM -out svc_dbt.p8 -nocrypt
   openssl rsa -in svc_dbt.p8 -pubout -out svc_dbt.pub
   chmod 600 *.p8
   ```

2. **Register the admin public key** on a dedicated admin service user. In Snowsight open a
   SQL worksheet / SQL file (the **+** button at the top of the sidebar, or Workspaces) with
   role ACCOUNTADMIN, paste the body of `admin.pub` (no BEGIN/END lines) and run:

   ```sql
   create user SVC_ADMIN type = service default_role = ACCOUNTADMIN
     rsa_public_key = 'MIIBIjANBgkq...' comment = 'Terraform + setup SQL. Key-pair only.';
   grant role ACCOUNTADMIN to user SVC_ADMIN;
   desc user SVC_ADMIN;   -- RSA_PUBLIC_KEY_FP must equal the local fingerprint below
   ```

   ```bash
   echo "SHA256:$(openssl rsa -pubin -in ~/.snowflake/keys/admin.pub -outform DER | openssl dgst -sha256 -binary | openssl enc -base64)"
   ```

   Why not your own login: key-pair auth sends the user name upper-cased, so a sign-up name
   like `first.last` (lower case, dots) fails with "JWT token is invalid". A service user
   with a plain upper-case name also keeps automation off a human account.

   Terraform registers `svc_dbt.pub` on the `SVC_DBT` service user itself.

3. **AWS CLI credentials** for an IAM user/role that can create S3 buckets, KMS keys and IAM
   roles (`aws configure sso` or `aws configure`). Check with `aws sts get-caller-identity`.

4. **Fill in config** (both files are git-ignored):

   ```bash
   cp .env.snowflake.example .env.snowflake
   cp terraform/example.tfvars terraform/terraform.tfvars
   ```

   `aws_region` must be the AWS region of your Snowflake account (`make sf-check` prints it):
   S3 can only notify an SQS queue in the same region.

## Deploy

```bash
make sf-setup          # dbt-snowflake into .venv
make sf-check          # account, region, AWS account id
make tf-init
make tf-plan           # review: 75 resources, nothing destroyed
make tf-apply          # applies exactly the reviewed plan
make sf-governance     # tags, policies, erasure procedure + task, account monitor
```

## Load and build (the two-load replay, for real)

```bash
make data CUSTOMERS=20000                 # if data/landing is empty
make sf-upload LOAD_DATE=2025-10-01       # load 1: history; Snowpipe ingests in ~1 min
make sf-load-status                       # rows per feed/partition, pipe state
make sf-build                             # backfill: snapshot opens versions, facts created
make sf-upload LOAD_DATE=2025-11-01       # load 2: October delta + profile changes
make sf-load-status
make sf-build                             # incremental MERGE + SCD2 changes
make sf-verify                            # same query as ANALYST / ANALYST_EU / PII_READER
make sf-cost                              # credits by warehouse, model, pipe
```

## Scheduled runs (GitHub Actions)

`.github/workflows/prod-run.yml` builds prod daily and on demand. To switch it on:

1. Repo → Settings → Environments → create `production` (optionally with required
   reviewers).
2. Add environment secrets `SNOWFLAKE_ACCOUNT` (`orgname-accountname`) and
   `SNOWFLAKE_PRIVATE_KEY` (contents of `svc_dbt.p8`).
3. Repo → Settings → Variables → `SNOWFLAKE_DEPLOY_ENABLED` = `true`.

The same switch enables the `deploy-snowflake` job in `ci.yml` on merges to `main`.

## Production hardening not done on the trial

- Terraform state is local (`terraform/terraform.tfstate`, git-ignored). Use the S3 backend
  with locking (commented in `versions.tf`) for a team.
- Terraform runs as ACCOUNTADMIN for account objects. A dedicated provisioning role with only
  CREATE INTEGRATION / CREATE ROLE / MANAGE GRANTS is tighter.
- The masking hash salt in `04_governance.sql` is a literal; in production read it from a
  secret (e.g. a secure UDF over an external secret).
- Network policy restricting `SVC_DBT` to GitHub runner / office IP ranges.

## Tear down

```bash
make tf-destroy
```

This removes the bucket (with `force_destroy_bucket = true`), IAM role, KMS key (scheduled
deletion), pipes, warehouses, roles, `SVC_DBT` and the RAW/ANALYTICS/GOVERNANCE databases,
including the SQL-created governance objects inside GOVERNANCE. Then drop the account monitor
in a worksheet: `alter account set resource_monitor = null; drop resource monitor rm_account;`.
