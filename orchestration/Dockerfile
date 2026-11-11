FROM astrocrpublic.azurecr.io/runtime:3.3-12

# dbt runs from its own Python 3.12 virtualenv so its pins never clash with Airflow's
# (the runtime itself is Python 3.14). Cosmos calls this executable.
RUN pip install --no-cache-dir uv==0.9.* \
    && uv venv --python 3.12 /usr/local/airflow/dbt_venv \
    && uv pip install --no-cache --python /usr/local/airflow/dbt_venv/bin/python \
        "dbt-core>=1.10,<1.13" "dbt-snowflake>=1.10,<1.13"
