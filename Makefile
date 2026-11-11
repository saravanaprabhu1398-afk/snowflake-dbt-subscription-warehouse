# Local end-to-end run on DuckDB. No Snowflake account needed.
PY      ?= .venv/bin/python
DBT     ?= .venv/bin/dbt
CUSTOMERS ?= 20000
TARGET  ?= dev
DBT_FLAGS = --profiles-dir . --target $(TARGET)

.PHONY: setup data deps build replay freshness docs lint test clean

setup:
	uv venv --python 3.12 .venv && uv pip install --python $(PY) -r requirements.txt

data:
	$(PY) generator/generate.py --customers $(CUSTOMERS) --out data/landing

deps:
	$(DBT) deps $(DBT_FLAGS)

# One-shot build over all landing partitions.
build: deps
	$(DBT) build $(DBT_FLAGS)

# Production-like replay: load 1 (backfill to 2025-10-01), then load 2 (October delta).
# Exercises the SCD2 snapshot and the incremental MERGE path.
replay: deps
	rm -f data/$(TARGET).duckdb data/warehouse.duckdb
	$(DBT) build $(DBT_FLAGS) --vars '{as_of_load_date: "2025-10-01"}'
	$(DBT) build $(DBT_FLAGS)

freshness:
	$(DBT) source freshness $(DBT_FLAGS)

docs:
	$(DBT) docs generate $(DBT_FLAGS)

lint:
	.venv/bin/sqlfluff lint models tests snapshots

clean:
	rm -rf target dbt_packages logs data/*.duckdb

# ----------------------------------------------------------------------------- Snowflake + AWS
# Settings come from .env.snowflake (copy .env.snowflake.example). Credentials are key files
# on your machine; nothing secret is passed on the command line or stored in the repo.
# Runbook: docs/snowflake-deployment.md
-include .env.snowflake
export SNOWFLAKE_ORGANIZATION_NAME SNOWFLAKE_ACCOUNT_NAME AWS_PROFILE

SF_ACCOUNT = $(SNOWFLAKE_ORGANIZATION_NAME)-$(SNOWFLAKE_ACCOUNT_NAME)
AS_ADMIN   = SNOWFLAKE_ACCOUNT=$(SF_ACCOUNT) SNOWFLAKE_USER=$(SF_ADMIN_USER) SNOWFLAKE_PRIVATE_KEY_PATH=$(SF_ADMIN_KEY_PATH)
AS_DBT     = SNOWFLAKE_ACCOUNT=$(SF_ACCOUNT) SNOWFLAKE_USER=SVC_DBT SNOWFLAKE_PRIVATE_KEY_PATH=$(SF_DBT_KEY_PATH)
TF_ENV     = TF_VAR_admin_user=$(SF_ADMIN_USER) SNOWFLAKE_USER=$(SF_ADMIN_USER) SNOWFLAKE_AUTHENTICATOR=SNOWFLAKE_JWT SNOWFLAKE_PRIVATE_KEY="$$(cat $(SF_ADMIN_KEY_PATH))"
SF_SQL     = $(PY) scripts/sf_sql.py
PROD       = --profiles-dir . --target prod

.PHONY: sf-setup sf-check tf-init tf-plan tf-apply tf-destroy sf-governance sf-upload sf-load-status \
        sf-build sf-freshness sf-verify sf-cost

sf-setup:
	uv pip install --python $(PY) -r requirements-snowflake.txt

# Who/where am I? Region must match aws_region in terraform.tfvars.
sf-check:
	$(AS_ADMIN) $(SF_SQL) --role ACCOUNTADMIN --warehouse "" --query \
	  "select current_organization_name() as org, current_account_name() as account, current_region() as region, current_user() as user_name, current_version() as version"
	aws sts get-caller-identity --query Account --output text

tf-init:
	cd terraform && terraform init -input=false

tf-plan:
	cd terraform && $(TF_ENV) terraform plan -input=false -out=tfplan

# Applies exactly the plan you reviewed with tf-plan.
tf-apply:
	cd terraform && $(TF_ENV) terraform apply -input=false tfplan

tf-destroy:
	cd terraform && $(TF_ENV) terraform destroy -input=false

sf-governance:
	$(AS_ADMIN) $(SF_SQL) --role ACCOUNTADMIN --file snowflake/04_governance.sql
	$(AS_ADMIN) $(SF_SQL) --role ACCOUNTADMIN --file snowflake/06_account_guardrails.sql

# make sf-upload LOAD_DATE=2025-10-01   (then LOAD_DATE=2025-11-01 for the second load)
sf-upload:
	scripts/upload_landing.sh $(LANDING_BUCKET) $(LOAD_DATE)

sf-load-status:
	$(AS_ADMIN) $(SF_SQL) --role SYSADMIN --warehouse LOAD_WH --file snowflake/07_verify_load.sql

sf-build:
	$(AS_DBT) $(DBT) deps $(PROD)
	$(AS_DBT) $(DBT) build $(PROD)

sf-freshness:
	$(AS_DBT) $(DBT) source freshness $(PROD)

# Same query under three roles: masking and row access must differ.
sf-verify:
	@for r in ANALYST ANALYST_EU PII_READER; do \
	  $(AS_ADMIN) $(SF_SQL) --role $$r --warehouse BI_WH --file snowflake/08_verify_governance.sql; done

sf-cost:
	$(AS_ADMIN) $(SF_SQL) --role ACCOUNTADMIN --warehouse LOAD_WH --file snowflake/05_cost_monitoring.sql

# --- Airflow + Cosmos orchestration (local, Astro CLI + Docker) ---------------------------
# See orchestration/README.md. The DAG waits for Snowpipe, then runs dbt node by node.
AIRFLOW_SCHED = docker exec $$(docker ps -qf 'name=subscription-warehouse-orchestration.*-scheduler')
LOAD_DATE ?= 2025-11-01

.PHONY: airflow-start airflow-stop airflow-test airflow-run airflow-status

airflow-start:
	cd orchestration && astro dev start

airflow-stop:
	cd orchestration && astro dev stop

airflow-test:
	$(AIRFLOW_SCHED) bash -c 'cd /usr/local/airflow && python -m pytest -q tests'

airflow-run:
	$(AIRFLOW_SCHED) airflow dags trigger subscription_warehouse_daily \
	  -r manual_load_$(subst -,_,$(LOAD_DATE))_$$(date +%s) -c '{"load_date": "$(LOAD_DATE)"}'

airflow-status:
	$(AIRFLOW_SCHED) airflow dags list-runs subscription_warehouse_daily -o plain

# --- Dashboard (Streamlit over the marts) ---------------------------------------------------
.PHONY: dashboard sf-dashboard dashboard-test

dashboard:  ## local DuckDB build (run `make build` first)
	.venv/bin/streamlit run dashboard/app.py

sf-dashboard:  ## live Snowflake marts, read as SVC_DBT
	$(AS_DBT) DASHBOARD_BACKEND=snowflake .venv/bin/streamlit run dashboard/app.py

dashboard-test:
	.venv/bin/python -m pytest -q dashboard/tests
