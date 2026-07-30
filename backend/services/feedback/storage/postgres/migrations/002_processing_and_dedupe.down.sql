DROP INDEX IF EXISTS idx_submissions_payload_hash;

ALTER TABLE submissions
    DROP COLUMN IF EXISTS payload_hash,
    DROP COLUMN IF EXISTS processed_at;
