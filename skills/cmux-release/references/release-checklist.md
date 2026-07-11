# Release Checklist

This reference expands the amux release workflow.

## Default path

Prefer the `/release` command. It should handle:

- choosing the version
- gathering commits since the last tag
- updating `CHANGELOG.md`
- running `./scripts/bump-version.sh`
- committing release metadata
- running `./scripts/release-pretag-guard.sh`
- tagging and pushing

## Version policy

Use a minor bump by default. Use patch or major only when explicitly requested or clearly justified by the release scope.

The version bump script updates both:

- `MARKETING_VERSION`
- `CURRENT_PROJECT_VERSION`

The build number must increase for Sparkle auto-update. If `release-pretag-guard.sh` fails because the build number is not monotonic, run the bump script, commit the build-number bump, and retry the guard.

## Changelog

Update `CHANGELOG.md`. The docs changelog page at `web/app/docs/changelog/page.tsx` renders from it, so do not update a separate docs changelog source.

Keep the changelog user-facing. Mention user-visible fixes, behavior changes, and compatibility notes more prominently than internal refactors.

## Tagging

Run before tagging:

```bash
./scripts/release-pretag-guard.sh
```

Manual tag flow:

```bash
git tag vX.Y.Z
git push origin vX.Y.Z
gh run watch --repo Open330/amux
```

## Release asset

The expected release asset is:

```text
amux-macos.dmg
```

The README download button points to:

```text
releases/latest/download/amux-macos.dmg
```

If the asset name changes, update every surface that assumes this path.

## Required secrets

Release signing/notarization depends on:

- `AMUX_SPARKLE_PUBLIC_KEY`
- `AMUX_SPARKLE_PRIVATE_KEY`
- `AMUX_GITHUB_TOKEN`
- `AMUX_HOMEBREW_GITHUB_TOKEN`

The self-hosted runner must also have an authenticated, unlocked Vaultwarden
session in `~/.bw_session` containing:

- `Developer ID Application (Jiun Bae)` with `p12_b64`, `p12_password`, and `team_id`
- `App Store Connect API Key - file-stack` with `key_id`, `issuer_id`, and `private_key_p8_b64`

The current workflow does not read Apple certificate or notarization material
from GitHub secrets.

If release automation fails before signing, inspect workflow configuration and version metadata first. If it fails during signing/notarization, inspect the secret availability and Apple account status.
