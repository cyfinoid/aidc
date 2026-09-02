# Releasing aidc

aidc is rolling-release — `main` is always the supported branch — but tagged
releases give users a version to report (`aidc version`), give
`aidc doctor`/`aidc upgrade` a reference point, and anchor the changelog.

## Procedure

1. **Bump the version line** in `lib/aidc/common.sh`:

   ```bash
   AIDC_VERSION="${AIDC_VERSION:-0.2.0}"
   ```

2. **Cut the changelog section.** In `CHANGELOG.md`, retitle the accumulated
   `## [Unreleased]` entries to the new version with today's date, and start a
   fresh empty `## [Unreleased]` above it:

   ```markdown
   ## [Unreleased]

   ## [0.2.0] - 2026-07-06
   ### Added
   - …
   ```

3. **Commit, tag, push.** The tag must be `v` + the exact version:

   ```bash
   git commit -am "release: v0.2.0"
   git tag v0.2.0
   git push origin main v0.2.0
   ```

4. **Done.** The `release` workflow verifies the tag matches `AIDC_VERSION`
   and that the changelog section exists, then creates the GitHub Release
   with that section as the body. There are no build artifacts — installing
   aidc is `git clone && ./install.sh`, and a tag checkout pins users to a
   release.

## If the workflow fails

- *tag does not match AIDC_VERSION* — you tagged without bumping step 1.
  Delete the tag (`git push origin :refs/tags/v0.2.0 && git tag -d v0.2.0`),
  fix, re-tag.
- *CHANGELOG.md has no section* — step 2 was skipped; same recovery.

## Versioning policy

Semver, staying in `0.x` until the CLI surface stabilizes: breaking CLI or
scaffold-behavior changes bump the minor; fixes and additive features bump
the patch. The version stamped into each project's
`.ai-container/project.env` records which aidc version scaffolded it — that
stamp is what `aidc upgrade` compares against.
