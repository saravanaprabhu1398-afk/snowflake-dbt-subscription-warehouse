# Contributing

## Trunk-based workflow

- `main` is the only long-lived branch and is always deployable.
- Work in **short-lived branches** (`feat/…`, `fix/…`) that live a day or two, then open a PR.
  Large changes land in small PRs behind config (e.g. `enabled: false` on a new model) rather
  than in a long-running branch.
- Every PR runs CI: sqlfluff, generator lint, `dbt build` on DuckDB for the changed models and
  their parents/children (`+state:modified+` against the last `main` manifest), and
  `terraform validate`.
- **One approving review + green CI**, then squash-merge. No direct pushes to `main`
  (the `no-commit-to-branch` pre-commit hook guards this locally).
- Merge to `main` runs the full build, the incremental replay, freshness and docs, and uploads
  the manifest used by the next PRs' slim CI. If enabled, the deploy job then runs
  `dbt build --select state:modified+` on Snowflake prod.
- Breaking changes to a mart used by an exposure need a note in the PR and a heads-up to the
  exposure owner. Prefer adding a new column / model and deprecating the old one.
- Hotfixes are ordinary PRs to `main`; there are no release branches.

## Local setup

```bash
make setup                   # uv venv + requirements
.venv/bin/pre-commit install
make data                    # synthetic landing data (CUSTOMERS=20000 by default)
make replay                  # load 1 then load 2 on DuckDB
make lint
```

## Conventions

- Layers: `stg_` (1:1 with a source, views), `int_` (reusable logic), `dim_` / `fct_` (star
  schema), `mart_` (metric tables). Marts only read from core and intermediate models.
- Every model has a YAML entry with a description; primary keys get `unique` + `not_null`;
  foreign keys get `relationships`.
- New PII columns: add `meta: {pii_type: ..., masking_policy: ...}` so Snowflake masking is
  applied by the post-hook, and update `docs/governance.md`.
- SQL works on both DuckDB and Snowflake. If it can't, add an `adapter.dispatch` macro under
  `macros/cross_db/` rather than branching on `target.type` inside a model.
- Snowflake-only configs (`cluster_by`, `snowflake_warehouse`) go in the model config; they are
  ignored on DuckDB.
- Design changes that affect more than one layer or a metric definition get an RFC in `docs/`.
