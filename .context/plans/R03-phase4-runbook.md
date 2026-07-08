# amux Phase 4 productization runbook

Phase 4 turns the working feature set (Phases 0–3) into a shippable, branded
product. Unlike 0–3 these steps need signing certificates, real bundled
binaries, and a one-way flip of the app's identity — so they are written as a
runbook to execute deliberately (ideally on a release branch, not the live
`amux-phase0` dogfood tag), not auto-applied.

Status legend: ⬜ not started · 🟡 needs a decision/asset · ✅ done

## 1. Branding split ⬜ (do first, on a release branch)

The fork still builds as cmux (`com.cmuxterm.app`, "cmux DEV", cmux sockets).
Flip identity in one commit so upstream merges stay mechanical:

- `cmux.xcodeproj`: `PRODUCT_BUNDLE_IDENTIFIER = com.open330.amux`, product
  name `amux`, `CMUX_SIDEBAR_EXTENSION_POINT_ID = com.open330.amux.cmux.sidebar`.
- App display name / `CFBundleName` → `amux`; app icon asset swap.
- Socket + support paths: the debug socket, cmuxd socket, and
  `~/Library/Application Support/cmux` derive from the bundle id / a `cmux`
  literal — audit `scripts/reload*.sh` and the socket path builders and
  rename to an `amux` namespace so a user can run amux and upstream cmux
  side by side.
- Sparkle feed URL (see §5) and the `releases/latest` download URL in
  README.
- Keep a single `AMUX_BRAND` seam (or a build setting) so the diff against
  upstream is one file, not scattered literals.

**Risk:** changing the base bundle id changes the app users have been
dogfooding. Do it when starting a real release, migrate/rename the support
dir, and announce it.

## 2. Bundle tmux + muxad + muxa + CLI into the .app 🟡 (needs pinned binaries)

Target layout (already sketched in R02 §3.1):

```
amux.app/Contents/Resources/bin/{tmux, muxad, muxa, amux-cli}
```

- Add a "Bundle amux runtime" Run Script build phase that copies pinned
  binaries from a `vendor/` staging dir into `Resources/bin` and signs them.
- **tmux**: build universal from a pinned tag (3.5a baseline) with the ISC
  notice; or vendor a static build. `RemoteTmuxHost.localTmuxExecutablePath()`
  must prefer `Resources/bin/tmux` over the Homebrew paths it uses today.
- **muxad/muxa/amux-cli**: `cargo build --release` from the muxa repo at a
  pinned tag; copy the release artifacts (don't vendor source — keeps the
  MIT/Apache boundary clean, R02 §1).
- Record the {app, tmux, muxad, protocol} version tuple in a build manifest
  and add a release smoke test (R02 §3.4).

**Decision needed:** where the pinned binaries come from (CI build vs.
checked-in artifacts) and the exact tmux version to pin.

## 3. muxad LaunchAgent 🟡 (needs a decision on managing the user's daemon)

muxad must outlive the app so agent activity accrues while amux is closed
(R02 §3.3). Plan: a user-triggered (never automatic) install action that
writes `~/Library/LaunchAgents/com.open330.amux.muxad.plist` pointing at the
bundled muxad, plus an uninstall action.

**Blocked on a decision:** the user already runs muxad manually on the
default socket. An amux-managed LaunchAgent must not fight that — options:
(a) amux manages muxad only when the user opts in and the manual one isn't
running; (b) amux always uses the user's existing muxad and never installs
its own. Pick before building; auto-installing a second daemon would disrupt
the live workflow.

## 4. First-run integration wizard ⬜

Onboarding sheet (reuse `muxa init` presets) that, with explicit consent:
1. installs/point the muxad LaunchAgent (§3),
2. wires agent hooks (`~/.claude/settings.json`, `~/.codex/config.toml`,
   `~/.gemini/settings.json`),
3. sets alert ownership (amux owns notifications, muxa notify off — R02 §3.3),
4. offers the system-tmux adoption toggle.
Plus a matching "Uninstall integrations" action. All consent-gated.

## 5. Sparkle auto-update ⬜

- Reuse cmux's Sparkle wiring; point the feed at an amux appcast URL.
- Needs the signing story from §1 and a hosting location for the appcast +
  dmg (the release asset is `amux-macos.dmg`).

## 6. Homebrew cask ⬜

- `brew install --cask amux` tapping an `open330/homebrew-amux` (or the
  existing homebrew-cmux) tap. Depends on §5's hosted dmg + appcast.

## 7. Gitea CI / release pipeline 🟡 (replaces the removed GitHub Actions)

GitHub Actions were removed (CI runs on the Gitea mirror). Needs, on Gitea
Actions:
- build + `CmuxMuxa` / `CmuxControlSocket` package tests + the cmuxTests
  target on a macOS runner,
- pbxproj / workspace / Package.resolved / test-wiring lint scripts
  (already in `scripts/`),
- a release workflow: build → bundle runtime (§2) → sign/notarize → dmg →
  appcast (§5).
- Register the Gitea webhook (deferred earlier) so pushes trigger it.

**Decision needed:** the Gitea instance URL + runner availability (macOS
signing needs a real Mac runner).

## Remaining Phase 3 UI (not blocking Phase 4)

- **Detached-sessions sidebar section**: the data + a palette picker ship in
  Phase 3; the visual sidebar section is deferred because sidebar rows are
  under the strict snapshot-boundary rule (rows take value snapshots only —
  see CLAUDE.md). It needs a `DetachedSessionsSection` fed an immutable
  `[DetachedSessionSnapshot]` + a closure bundle, refreshed off a reload
  completion, never reading a store in the row body.
- **muxa stats/timeline panel**: a new non-terminal surface rendering
  muxa `stats`/`timeline` data via CmuxMuxa. Sizeable; own milestone.
- **Remote SSH ↔ local-engine UX unification**: largely achieved at the
  transport layer (shared `RemoteTmuxTransport`); the remaining work is
  presenting local + SSH hosts in one sidebar model.
