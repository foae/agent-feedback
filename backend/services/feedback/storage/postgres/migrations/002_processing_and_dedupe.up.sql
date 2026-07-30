-- Processing lifecycle + content-hash dedupe.
--
-- processed_at: set/cleared by POST /api/v1/submissions/processed (the async
-- feedback processor). The ONLY mutable column — payload stays write-once.
--
-- payload_hash: sha256 hex over the canonical submission content, computed in
-- core (see core/hash.go). Reviews use it to detect replay-with-different-content
-- (409); frictions use it to absorb duplicate reports inside a time window
-- (200 + existing row). NULL on rows created before this migration — those
-- keep the legacy replay behavior (no content comparison).
ALTER TABLE submissions
    ADD COLUMN IF NOT EXISTS processed_at TIMESTAMPTZ,
    ADD COLUMN IF NOT EXISTS payload_hash TEXT;

CREATE INDEX IF NOT EXISTS idx_submissions_payload_hash
    ON submissions(payload_hash) WHERE payload_hash IS NOT NULL;
