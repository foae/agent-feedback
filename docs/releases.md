# Releases

## Versioning and publication

Source releases are annotated, immutable `vMAJOR.MINOR.PATCH` tags: patch for
compatible fixes, docs and dependency updates; minor for compatible features;
major for breaking API or operational contracts. Every delivered change belongs
to a release. The two skills carry their own `version` in their `SKILL.md`;
bump one only when its command contract changes.

Maintainers need Git, Python 3 and an authenticated GitHub CLI (`gh`) with
write access to the repository and its tags.

1. Update the stable version link in `README.md`, the `SERVICE_VERSION`
   default in `cmd/feedback/config.go` and in `.env.example`, and add notes to
   this file.
2. Run the gates in [develop.md](develop.md#verification-before-you-are-done),
   commit, push `main`, and let CI finish on that exact commit (it publishes
   the image).
3. Write the release notes to a file outside the checkout or under the
   gitignored `.private/`.
4. Run the release tool, first in preflight, then for real:

   ```bash
   python3 scripts/release.py vX.Y.Z 'Release name' /path/to/notes.md --check
   python3 scripts/release.py vX.Y.Z 'Release name' /path/to/notes.md
   ```

   It checks a clean `main` against `origin`, refuses an existing tag, waits
   for green push CI on the commit, pushes the annotated tag with an absence
   lease, and creates and verifies a stable release. Images are tagged with
   the commit SHA and `latest`, not the release version: deploy the SHA.

### Recovery

If publication fails after tagging, inspect the local tag, the remote tag, the
CI run and the GitHub release before doing anything. Never force-move a
published tag. Local tag only: push it with an absence lease. Remote tag
without a release: `gh release create <tag> --verify-tag --latest --title '<name>' --notes-file <file>`.
Release exists: inspect it rather than creating another.

The notes file from step 3 is uncommitted, so it does not exist on another
machine: recovering there means rebuilding it from this file's section for
that version. Rewrite the section's relative links to repo-root paths
(`api.md` to `docs/api.md`) — a release body resolves them against the
repository root, not `docs/`. Corrections to source
need a new version; corrections to release prose need no new tag.

## v2.0.0 — SQLite, generic events, triage skill

Breaking operational contract, compatible API.

- **Storage**: PostgreSQL replaced by SQLite (`modernc.org/sqlite`, pure Go).
  One container, one named volume, no database service. Physical backups via
  `feedback backup`, logical via `GET /api/v1/export`; restore and migration
  via `feedback import` (all-or-nothing, header/count/digest verified, hashes
  recomputed, `--family` filter, ids never reused). See
  [operate.md](operate.md#restore-and-migration)
  for the 1.x migration procedure; `scripts/export-v1-postgres.sh` produces
  the import file from a 1.x deployment with ids, timestamps, processing state
  and hashes preserved.
- **API 1.1** ([api.md](api.md)): additive. `family` and `payload_hash` on
  every record, `POST /api/v1/events`, `resolution` when marking processed,
  keyset pagination (`before_id`, `has_more`, `next_before_id`, `total`),
  `include=payload`, `GET /api/v1/export`, six-digit timestamps. Every 1.0
  request and response field is unchanged.
- **Service**: stdlib `net/http`, Prometheus with bounded labels plus backlog,
  database size and busy counters. OpenTelemetry, chi, sqlc and the
  PostgreSQL-specific configuration are gone. `GRACEFUL_SHUTDOWN_TIMEOUT`
  default is now 30s; the fixed 5s drain sleep is removed. Payloads are
  returned byte-exact (large integers no longer round).
- **Deployment**: `scripts/deploy.sh <sha>` installs the compose file,
  preserves the host `.env`, pins the image there and runs `docker compose
  pull && up`. Requires the GHCR package to be pullable by the host. The
  `crane` streaming path is gone.
- **Skill `agent-feedback` 3.0**: new `submit-event.sh`; `process.sh list`
  pages through the whole queue and takes `--include-processed` (the old
  `--all` errors), `done` takes `--resolution`; `query.sh export`;
  `submit-review.sh --sweep` scans `REVIEW_LOG_DIR` and
  `AGENT_FEEDBACK_REVIEW_DIRS` only (set the latter where hardcoded cache
  paths were relied on). Fixes: spool persistence is verified (an unwritable
  spool now fails loudly instead of reporting `spooled`), review receipts are
  validated before a run is marked submitted, large prose no longer passes
  through argv, `--dry-run` applies the server's validation, rejected spool
  files are kept 30 days as documented.
- **New skill `feedback-triage` 1.0**: end-to-end queue processing with one
  consolidated interview. `scripts/digest.sh` pulls and groups the open queue.
- **Docs** rewritten for agents first: README route table, `api.md`,
  `operate.md`, `develop.md`, `security.md`. Template-era documents removed;
  `docs/agent-usage.md` redirects to `api.md`.

Upgrade: follow the migration procedure; the 1.x PostgreSQL volume is not
read by 2.x. Producers need skill 3.0 only for the new features; 2.1 clients
keep working against the 2.0.0 service.

## v1.0.1 — Public documentation and release workflow

Compact README with dedicated guides, guarded release tooling, updated Go
modules, toolchain, container bases and CI actions. No API or migration
changes.

## v1.0.0

Initial stable API and companion client release.
