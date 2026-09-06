# Releases

## Versioning and publication

Source releases use annotated, immutable `vMAJOR.MINOR.PATCH` tags. Use a patch
for compatible fixes, documentation, or dependency updates; a minor for compatible
features; a major for breaking contracts. Every delivered change belongs in a
named release. The companion skill is independently versioned in its `SKILL.md`;
do not bump it for service-only or repository-documentation changes.

Maintainers need Git, Python 3, authenticated GitHub CLI (`gh`) with repository
write access, and permission to push tags to the existing `origin` remote.

1. Update the stable version links/checkouts in `README.md` and
   `docs/getting-started.md`, the service's `ServiceVersion` default and
   `.env.example` `SERVICE_VERSION`, and add release and upgrade notes here.
2. Run the [development gates](development.md), commit all changes, and push
   `main`. CI must run on that exact commit, including container publication.
3. Prepare a Markdown notes file describing actual changes, compatibility,
   verification, and limitations. Keep temporary notes outside the checkout or
   in ignored `.private/`.
4. Run:

   ```bash
   python3 scripts/release.py v1.0.2 'A descriptive release name' /path/to/notes.md --check
   python3 scripts/release.py v1.0.2 'A descriptive release name' /path/to/notes.md
   ```

The tool checks the clean branch against `origin/main`, refuses existing tags,
waits for exact-commit push CI, creates an annotated tag, pushes it with a lease
requiring that the remote tag is absent, and publishes and verifies a stable,
non-draft release. It never changes repository visibility. CI publishes images
as `latest` and the commit SHA, not the source release version: deploy the SHA
image for reproducibility.

### Recovery

If publication fails after tag creation, inspect the local tag, remote tag, CI
run, and GitHub release before proceeding. Never force-move a published tag.
If only the local tag exists, verify its target and push that same tag using an
absence lease. If the remote tag exists but the release does not, verify it peels
to the successful CI SHA, then use `gh release create <tag> --verify-tag --title
'<name>' --notes-file <file>` and verify with `gh release view <tag>`. If the
release exists already, inspect it rather than creating another. Corrections to
source require a new version; corrections to release prose need no moved tag.

## v1.0.1 — Public documentation and release workflow

- Compact README with dedicated getting-started, security, development,
  deployment, and operations guides.
- Guarded stable-release tooling and explicit contributor release requirements.
- Broader ignoring of private environment variants while retaining safe examples.
- Updated stable Go modules, Go toolchain/container bases, and CI actions.

No API or database migration changes. Existing deployment credentials and data
remain unchanged. Back up before upgrading and use the new commit-SHA image.
The independently versioned companion skill is unchanged.

## v1.0.0

Initial stable API and companion client release. See the
[GitHub release](https://github.com/foae/agent-feedback/releases/tag/v1.0.0).
