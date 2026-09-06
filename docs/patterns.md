# Implementation patterns

These patterns describe this service, not a reusable example service. See the
[architecture](architecture.md) and [API contract](agent-usage.md) for boundaries.

## Create and replay

Validate in core before storage. Reviews use an insert-on-conflict/re-fetch path
with payload-hash comparison: an identical replay returns the original record,
a changed replay returns `ErrReplayMismatch`. Do not update immutable content or
use an identity-column update to force a conflict result. Legacy hashless rows
are the documented exception, not a pattern for new submissions.

Friction duplicates are time-windowed rather than permanently unique. Acquire a
transaction-scoped advisory lock on the hash, then perform lookup and insertion
in that same READ COMMITTED transaction. The lookup must be a later statement
than lock acquisition so it sees the preceding lock holder's committed insert.
Context is excluded from this hash. A unique index on the hash alone would
incorrectly prevent legitimate submissions outside the window.

## Processing

Lock existing rows in sorted ID order, classify changed/unchanged/missing IDs,
update, and commit together. Do not classify with a separate post-update read:
another request can change the flag between operations. Roll back on error.

## SQL and resource ownership

Edit `storage/postgres/q.sql` and regenerate with `just sqlc-generate`; generated
bindings are not hand-maintained. Use `json.RawMessage` for JSONB parameters.
Use pgx pools and transactions directly through the generated DBTX interface;
no forwarding wrapper is needed. Close migration drivers and pools on failed
initialization as well as normal shutdown. Never modify deployed migrations.

## HTTP and errors

The shared decoder rejects unknown fields, requires one JSON value followed by
EOF, and bounds the complete request body to 10 MiB. Handlers translate core
sentinel errors into status codes. Validation and replay conflicts are expected
client errors, not server-error logs. Internal failures retain error severity.

The router uses Recoverer, RequestID, structured logging and request metrics.
Do not add RealIP unless a trusted-proxy policy is implemented: blindly accepting
forwarding headers allows spoofing. Operational endpoints are unauthenticated
and must remain inside the deployment boundary.

## Client delivery

A 200/201 HTTP status alone is not a friction receipt; require a positive integer
ID and the friction type before deleting queued content. Keep API keys out of
process arguments. Retry immutable payloads, not reconstructed payloads with
new attribution. Do not publish an ungraded or ambiguously joined review run:
once stored, that ID cannot be corrected by overwriting it.
