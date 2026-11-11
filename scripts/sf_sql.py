"""Run a SQL file (or a single statement) against Snowflake with key-pair auth.

Credentials come only from the environment, never from arguments or the repo:
  SNOWFLAKE_ACCOUNT            orgname-accountname
  SNOWFLAKE_USER               user to connect as
  SNOWFLAKE_PRIVATE_KEY_PATH   path to an unencrypted PKCS#8 PEM private key

Usage:
  python scripts/sf_sql.py --role ACCOUNTADMIN --file snowflake/04_governance.sql
  python scripts/sf_sql.py --role ANALYST --query "select email from analytics.core.dim_customer limit 3"
"""

from __future__ import annotations

import argparse
import io
import os
import sys

import snowflake.connector
import snowflake.connector.errors


def connect(role: str, warehouse: str | None):
    missing = [
        v
        for v in ("SNOWFLAKE_ACCOUNT", "SNOWFLAKE_USER", "SNOWFLAKE_PRIVATE_KEY_PATH")
        if not os.environ.get(v)
    ]
    if missing:
        sys.exit(f"missing environment variables: {', '.join(missing)}")
    return snowflake.connector.connect(
        account=os.environ["SNOWFLAKE_ACCOUNT"],
        user=os.environ["SNOWFLAKE_USER"],
        authenticator="SNOWFLAKE_JWT",
        private_key_file=os.path.expanduser(os.environ["SNOWFLAKE_PRIVATE_KEY_PATH"]),
        role=role,
        warehouse=warehouse or None,
        session_parameters={"QUERY_TAG": '{"app":"sf_sql","tool":"deploy"}'},
    )


def show(cur, max_rows: int) -> None:
    if cur.description is None:
        return
    cols = [d[0] for d in cur.description]
    rows = cur.fetchmany(max_rows)
    if not rows:
        print("  (no rows)")
        return
    print("  " + " | ".join(cols))
    for row in rows:
        print("  " + " | ".join("" if v is None else str(v) for v in row))


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    src = ap.add_mutually_exclusive_group(required=True)
    src.add_argument("--file")
    src.add_argument("--query")
    ap.add_argument("--role", default="SYSADMIN")
    ap.add_argument("--warehouse", default="TRANSFORM_WH_S")
    ap.add_argument("--max-rows", type=int, default=50)
    args = ap.parse_args()

    sql = open(args.file).read() if args.file else args.query
    conn = connect(args.role, args.warehouse)
    try:
        # execute_stream splits on statement boundaries and understands $$ blocks.
        for cur in conn.execute_stream(io.StringIO(sql), remove_comments=True):
            first_line = " ".join(cur.query.split())[:110]
            print(f"> {first_line}")
            show(cur, args.max_rows)
    except snowflake.connector.errors.ProgrammingError as exc:
        sys.exit(f"SQL error: {exc.msg} (query id {exc.sfqid})")
    finally:
        conn.close()


if __name__ == "__main__":
    main()
