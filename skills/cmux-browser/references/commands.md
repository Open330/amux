# Command Reference (cmux Browser)

This maps common `agent-browser` usage to `amux browser` usage.

## Direct Equivalents

- `agent-browser open <url>` -> `amux browser open <url>`
- `agent-browser goto|navigate <url>` -> `amux browser <surface> goto|navigate <url>`
- `agent-browser snapshot -i` -> `amux browser <surface> snapshot --interactive`
- `agent-browser click <ref>` -> `amux browser <surface> click <ref>`
- `agent-browser fill <ref> <text>` -> `amux browser <surface> fill <ref> <text>`
- `agent-browser type <ref> <text>` -> `amux browser <surface> type <ref> <text>`
- `agent-browser select <ref> <value>` -> `amux browser <surface> select <ref> <value>`
- `agent-browser get text <ref>` -> `amux browser <surface> get text <ref-or-selector>`
- `agent-browser get url` -> `amux browser <surface> get url`
- `agent-browser get title` -> `amux browser <surface> get title`

## Core Command Groups

### Navigation

```bash
amux browser open <url>                        # opens in caller's workspace (uses CMUX_WORKSPACE_ID)
amux browser open <url> --workspace <id|ref>   # opens in a specific workspace
amux browser <surface> goto <url>
amux browser <surface> back|forward|reload
amux browser <surface> get url|title
```

> **Workspace context:** `browser open` targets the workspace of the terminal where the command is run (via `CMUX_WORKSPACE_ID`), even if a different workspace is currently focused. Use `--workspace` to override.

### Snapshot and Inspection

```bash
amux browser <surface> snapshot --interactive
amux browser <surface> snapshot --interactive --compact --max-depth 3
amux browser <surface> get text body
amux browser <surface> get html body
amux browser <surface> get value "#email"
amux browser <surface> get attr "#email" --attr placeholder
amux browser <surface> get count ".row"
amux browser <surface> get box "#submit"
amux browser <surface> get styles "#submit" --property color
amux browser <surface> eval '<js>'
```

### Interaction

```bash
amux browser <surface> click|dblclick|hover|focus <selector-or-ref>
amux browser <surface> fill <selector-or-ref> [text]   # empty text clears
amux browser <surface> type <selector-or-ref> <text>
amux browser <surface> press|keydown|keyup <key>
amux browser <surface> select <selector-or-ref> <value>
amux browser <surface> check|uncheck <selector-or-ref>
amux browser <surface> scroll [--selector <css>] [--dx <n>] [--dy <n>]
```

### Wait

```bash
amux browser <surface> wait --selector "#ready" --timeout-ms 10000
amux browser <surface> wait --text "Done" --timeout-ms 10000
amux browser <surface> wait --url-contains "/dashboard" --timeout-ms 10000
amux browser <surface> wait --load-state complete --timeout-ms 15000
amux browser <surface> wait --function "document.readyState === 'complete'" --timeout-ms 10000
```

### Session/State

```bash
amux browser <surface> cookies get|set|clear ...
amux browser <surface> storage local|session get|set|clear ...
amux browser <surface> tab list|new|switch|close ...
amux browser <surface> state save|load <path>
```

### Diagnostics

```bash
amux browser <surface> console list|clear
amux browser <surface> errors list|clear
amux browser <surface> highlight <selector>
amux browser <surface> screenshot
amux browser <surface> download wait --timeout-ms 10000
```

## Agent Reliability Tips

- Use `--snapshot-after` on mutating actions to return a fresh post-action snapshot.
- Re-snapshot after navigation, modal open/close, or major DOM changes.
- Prefer short handles in outputs by default (`surface:N`, `pane:N`, `workspace:N`, `window:N`).
- Use `--id-format both` only when a UUID must be logged/exported.

## Known WKWebView Gaps (`not_supported`)

- `browser.viewport.set`
- `browser.geolocation.set`
- `browser.offline.set`
- `browser.trace.start|stop`
- `browser.network.route|unroute|requests`
- `browser.screencast.start|stop`
- `browser.input_mouse|input_keyboard|input_touch`

See also:
- [snapshot-refs.md](snapshot-refs.md)
- [authentication.md](authentication.md)
- [session-management.md](session-management.md)
