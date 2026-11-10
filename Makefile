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
