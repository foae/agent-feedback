-- name: CreateSubmission :one
-- Not idempotent on its own: relies on the partial unique index on (submission_type, run_id)
-- WHERE run_id IS NOT NULL. On conflict, does nothing and returns no row -- the caller
-- must re-fetch via GetSubmissionByTypeAndRunID to get the existing row. See
-- core.CreateReview for the check-then-insert-then-recheck flow (the identity column
-- cannot be targeted by ON CONFLICT DO UPDATE SET id = ...).
INSERT INTO submissions (submission_type, machine_name, coordinator_model, run_id, payload, payload_hash)
VALUES ($1, $2, $3, $4, $5, $6)
ON CONFLICT (submission_type, run_id) WHERE run_id IS NOT NULL DO NOTHING
RETURNING *;

-- name: GetSubmissionByTypeAndRunID :one
SELECT * FROM submissions WHERE submission_type = $1 AND run_id = $2 LIMIT 1;

-- name: GetSubmissionByID :one
SELECT * FROM submissions WHERE id = $1 LIMIT 1;

-- name: LockFrictionDedupe :exec
-- A transaction-scoped advisory lock serializes duplicate absorption for one
-- content hash. It must run as its own statement before the lookup so the
-- latter gets a fresh READ COMMITTED snapshot after any lock wait.
SELECT pg_advisory_xact_lock(hashtextextended(sqlc.arg('payload_hash')::text, 0));

-- name: GetRecentFrictionByHash :one
-- Friction duplicate absorption: newest identical-content friction inside the
-- dedupe window. The caller holds LockFrictionDedupe for this hash.
SELECT * FROM submissions
WHERE submission_type = 'friction' AND payload_hash = $1 AND created_at >= $2
ORDER BY id DESC
LIMIT 1;

-- name: LockSubmissionProcessingStates :many
-- Locks candidate rows in a stable order so classification and the state
-- transition observe one atomic snapshot.
SELECT id, processed_at
FROM submissions
WHERE id = ANY(sqlc.arg('ids')::bigint[])
ORDER BY id
FOR UPDATE;

-- name: MarkSubmissionsProcessed :many
-- Sets processed_at only where currently NULL (idempotent; the timestamp of the
-- first marking is preserved). Returns the ids actually updated.
UPDATE submissions SET processed_at = NOW()
WHERE id = ANY(sqlc.arg('ids')::bigint[]) AND processed_at IS NULL
RETURNING id;

-- name: UnmarkSubmissionsProcessed :many
UPDATE submissions SET processed_at = NULL
WHERE id = ANY(sqlc.arg('ids')::bigint[]) AND processed_at IS NOT NULL
RETURNING id;


-- name: ListSubmissions :many
-- friction_* columns are extracted from the payload for friction rows so the
-- list is scannable without an N+1 fetch; they come back NULL for review rows.
SELECT
    id, submission_type, machine_name, coordinator_model, run_id, created_at, processed_at,
    COALESCE(payload->>'category', '')::text AS friction_category,
    COALESCE(payload->>'summary', '')::text  AS friction_summary,
    COALESCE(payload->>'project', '')::text  AS friction_project,
    COALESCE(payload->>'harness', '')::text  AS friction_harness
FROM submissions
WHERE
    (sqlc.narg('submission_type')::text IS NULL OR submission_type = sqlc.narg('submission_type'))
    AND (sqlc.narg('machine_name')::text IS NULL OR machine_name = sqlc.narg('machine_name'))
    AND (sqlc.narg('coordinator_model')::text IS NULL OR coordinator_model = sqlc.narg('coordinator_model'))
    AND (sqlc.narg('since')::timestamptz IS NULL OR created_at >= sqlc.narg('since'))
    AND (sqlc.narg('until')::timestamptz IS NULL OR created_at <= sqlc.narg('until'))
    AND (sqlc.narg('processed')::boolean IS NULL
         OR (sqlc.narg('processed')::boolean = TRUE AND processed_at IS NOT NULL)
         OR (sqlc.narg('processed')::boolean = FALSE AND processed_at IS NULL))
ORDER BY id DESC
LIMIT sqlc.arg('limit') OFFSET sqlc.arg('offset');
