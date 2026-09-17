#!/usr/bin/env bash
# Export a 1.x (PostgreSQL) agent-feedback deployment in the API 1.1 export
# format, straight from the database, so ids, timestamps, processing state
# and payload hashes are all preserved. Run on the host, in the directory
# holding the 1.x docker-compose.yml (the postgres service must be running).
#
# Usage: scripts/export-v1-postgres.sh > v1.jsonl
# Env:   PG_SERVICE (default postgres), PG_USER (default feedback), PG_DB (default feedback)
#
# Output: header line, one record per line ascending id, terminator with count
# and sha256 over the record lines — exactly what `feedback import` verifies.
set -euo pipefail

PG_SERVICE="${PG_SERVICE:-postgres}"
PG_USER="${PG_USER:-feedback}"
PG_DB="${PG_DB:-feedback}"

if command -v sha256sum >/dev/null; then SHA=(sha256sum); else SHA=(shasum -a 256); fi

RECORDS=$(mktemp)
trap 'rm -f "$RECORDS"' EXIT

docker compose exec -T "$PG_SERVICE" psql -U "$PG_USER" -d "$PG_DB" -At -v ON_ERROR_STOP=1 <<'SQL' > "$RECORDS"
SELECT json_build_object(
  'id', id,
  'family', CASE WHEN submission_type = 'friction' THEN 'friction' ELSE 'review' END,
  'submission_type', submission_type,
  'machine_name', machine_name,
  'coordinator_model', coordinator_model,
  'run_id', run_id,
  'payload', payload,
  'payload_hash', payload_hash,
  'created_at', to_char(created_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"'),
  'processed_at', CASE WHEN processed_at IS NULL THEN NULL
                       ELSE to_char(processed_at AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.US"Z"') END,
  'resolution', NULL
)::text
FROM submissions
ORDER BY id;
SQL

count=$(wc -l < "$RECORDS" | tr -d ' ')
digest=$("${SHA[@]}" < "$RECORDS" | cut -d' ' -f1)
now=$(date -u +%Y-%m-%dT%H:%M:%S.000000Z)

printf '{"export_format":1,"family":null,"since":null,"exported_at":"%s","source":"agent-feedback-1.x-postgres"}\n' "$now"
cat "$RECORDS"
printf '{"export_complete":true,"count":%s,"sha256":"%s"}\n' "$count" "$digest"
echo "exported $count row(s)" >&2
