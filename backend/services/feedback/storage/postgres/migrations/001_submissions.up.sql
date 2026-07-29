CREATE TABLE IF NOT EXISTS submissions (
    id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    submission_type   TEXT NOT NULL,          -- 'multi-llm-review' | 'second-opinion' | 'friction' | future types
    machine_name      TEXT NOT NULL,          -- self-reported: laptop-a, workstation-a, ...
    coordinator_model TEXT NOT NULL,          -- e.g. claude-fable-5, openai-codex/gpt-5.6-sol
    run_id            TEXT,                   -- client run identifier (reviews: existing run_ts); NULL for frictions
    payload           JSONB NOT NULL,
    created_at        TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE UNIQUE INDEX IF NOT EXISTS idx_submissions_type_run
    ON submissions(submission_type, run_id) WHERE run_id IS NOT NULL;  -- idempotent retries

CREATE INDEX IF NOT EXISTS idx_submissions_type ON submissions(submission_type);
CREATE INDEX IF NOT EXISTS idx_submissions_machine ON submissions(machine_name);
CREATE INDEX IF NOT EXISTS idx_submissions_created_at ON submissions(created_at);
CREATE INDEX IF NOT EXISTS idx_submissions_coordinator_model ON submissions(coordinator_model);
