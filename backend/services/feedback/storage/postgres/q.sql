-- name: CreateSubmission :one
-- Not idempotent on its own: relies on the partial unique index on (submission_type, run_id)
-- WHERE run_id IS NOT NULL. On conflict, does nothing and returns no row -- the caller
-- must re-fetch via GetSubmissionByTypeAndRunID to get the existing row. See
-- core.CreateReview for the check-then-insert-then-recheck flow (the identity column
-- cannot be targeted by ON CONFLICT DO UPDATE SET id = ...).
INSERT INTO submissions (submission_type, machine_name, coordinator_model, run_id, payload)
VALUES ($1, $2, $3, $4, $5)
ON CONFLICT (submission_type, run_id) WHERE run_id IS NOT NULL DO NOTHING
RETURNING *;

-- name: GetSubmissionByTypeAndRunID :one
SELECT * FROM submissions WHERE submission_type = $1 AND run_id = $2 LIMIT 1;

-- name: GetSubmissionByID :one
SELECT * FROM submissions WHERE id = $1 LIMIT 1;

-- name: ListSubmissions :many
SELECT id, submission_type, machine_name, coordinator_model, run_id, created_at
FROM submissions
WHERE
    (sqlc.narg('submission_type')::text IS NULL OR submission_type = sqlc.narg('submission_type'))
    AND (sqlc.narg('machine_name')::text IS NULL OR machine_name = sqlc.narg('machine_name'))
    AND (sqlc.narg('coordinator_model')::text IS NULL OR coordinator_model = sqlc.narg('coordinator_model'))
    AND (sqlc.narg('since')::timestamptz IS NULL OR created_at >= sqlc.narg('since'))
    AND (sqlc.narg('until')::timestamptz IS NULL OR created_at <= sqlc.narg('until'))
ORDER BY id DESC
LIMIT sqlc.arg('limit') OFFSET sqlc.arg('offset');
