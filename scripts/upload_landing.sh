#!/usr/bin/env bash
# Upload one landing load (all feeds) to S3, which triggers the auto-ingest Snowpipes.
#   scripts/upload_landing.sh <bucket> <load_date>      e.g. my-bucket 2025-10-01
# Uses your normal AWS CLI credentials (AWS_PROFILE etc.). Bucket default encryption (KMS)
# applies automatically.
set -euo pipefail
bucket="${1:?bucket}"
load_date="${2:?load date, e.g. 2025-10-01}"
root="${LANDING_DIR:-data/landing}"

shopt -s nullglob
uploaded=0
for dir in "$root"/*/"_load_date=$load_date"; do
    feed="$(basename "$(dirname "$dir")")"
    aws s3 cp --recursive --only-show-errors "$dir" "s3://$bucket/landing/$feed/_load_date=$load_date/"
    echo "uploaded $feed/_load_date=$load_date"
    uploaded=$((uploaded + 1))
done
[ "$uploaded" -gt 0 ] || { echo "no partitions for $load_date under $root" >&2; exit 1; }
