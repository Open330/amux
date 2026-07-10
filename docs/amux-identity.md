# amux identity boundary

amux is the product name, application name, and canonical CLI. It is a friendly
fork of cmux, but users should encounter cmux only where compatibility requires
the old spelling or where upstream attribution is explicit.

## Canonical amux surfaces

- App bundles: `amux.app`, `amux DEV <tag>.app`, `amux STAGING.app`
- Bundle identifiers: `com.open330.amux` and `com.open330.amux.*`
- CLI and examples: `amux`
- URL schemes: `amux://`, `amux-dev[-tag]://`, `amux-nightly://`
- Release assets: `amux-macos.dmg`, `appcast.xml`
- Releases and documentation: `github.com/Open330/amux`
- Homebrew cask source: `packaging/homebrew/amux.rb`

## Compatibility contracts

These names remain intentionally stable until a versioned migration exists:

- `CMUX_*` environment variables used by terminals, hooks, and automation
- `cmux.json`, `.cmux/`, and `~/.config/cmux/`
- `cmux.*` built-in action identifiers
- control socket and marker filenames under the existing cmux namespace
- `cmuxd` and its remote protocol artifact names
- the `cmux` executable alias
- persisted keychain, notification, and session identifiers that existing
  installations already own
- Swift module, package, target, and Xcode project names inherited from upstream

New documentation may mention these only as literal configuration or API names.
Descriptive prose and command examples use amux.

## Upstream references

References to `manaflow-ai/cmux` are expected in historical changelog entries,
bug provenance comments, the preserved upstream README, and the Ghostty/Bonsplit
fork workflow. They must not appear in amux release feeds, download commands,
help destinations, schema URLs, issue-report links, or Homebrew metadata.

## Hosted services

The inherited cmux account, Pro billing, Cloud VM, iOS pairing, feedback API,
and web application use infrastructure that amux does not own. amux hides the
account/mobile/Pro surfaces, rejects their CLI and socket methods, and routes
feedback to Open330 GitHub Issues. The app does not construct the inherited
auth graph, and the retained feedback client has no default network endpoint.
Presence clients likewise have no default service URL or privileged email
domain. The website blocks inherited API, auth-handler, pricing, dashboard,
iOS, Vault, and legal routes while allowing only the Open330 GitHub-stars API.
Profiling submission is Debug-only; Release keeps local diagnostics without
exposing the inherited submission UI. These services are not part of the amux
0.2 distribution contract unless Open330 later provides explicit endpoints and
credentials.

The same rule applies to telemetry. amux does not start the inherited Sentry or
PostHog projects, does not ship their credentials, and keeps the legacy
`app.sendAnonymousTelemetry` setting only as a no-op configuration key for
compatibility. Any future telemetry must use Open330-owned infrastructure and
an explicit user-facing policy before it can be enabled.
