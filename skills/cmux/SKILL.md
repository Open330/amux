---
name: cmux
description: End-user control of amux topology and routing (windows, workspaces, panes/surfaces, focus, moves, reorder, identify, trigger flash). Use when automation needs deterministic placement and navigation in a multi-pane amux layout.
---

# amux Core Control

Use this skill to control non-browser amux topology and routing.

## Core Concepts

- Window: top-level macOS amux window.
- Workspace: tab-like group within a window.
- Pane: split container in a workspace.
- Surface: a tab within a pane (terminal or browser panel).

## Fast Start

```bash
# identify current caller context
amux identify --json

# list topology
amux list-windows
amux list-workspaces
amux list-panes
amux list-pane-surfaces --pane pane:1

# create/focus/move
amux new-workspace
amux new-split right --panel pane:1
amux move-surface --surface surface:7 --pane pane:2 --focus true
amux split-off --surface surface:7 right
amux reorder-surface --surface surface:7 --before surface:3

# attention cue
amux trigger-flash --surface surface:7
```

## Settings and Docs

Use `amux docs settings` before changing amux-owned settings. It prints the docs URL, schema URL, raw GitHub resources, amux.json paths, and reload command.

```bash
amux docs settings
amux settings path
```

amux-owned settings live in `~/.config/amux/amux.json`. Legacy cmux files are imported once and are not active fallback sources. Before editing, copy any existing `amux.json` file to a timestamped `.bak` next to it so the user can revert. Edit the user file, then reload:

```bash
amux reload-config
```

`amux reload-config` reloads BOTH `amux.json` and Ghostty config (`~/.config/ghostty/config`) and refreshes terminals in place. No app restart needed.

Use amux settings for app behavior, sidebar, notifications, browser behavior, automation, workspace colors, and amux-owned shortcuts. Terminal rendering settings such as font, cursor style, theme, scrollback, background transparency (`background-opacity`), and blur (`background-blur`) belong in Ghostty config at `~/.config/ghostty/config`.

Open the UI when useful:

```bash
amux settings
amux settings amux-json
amux settings shortcuts
```

## Handle Model

- Default output uses short refs: `window:N`, `workspace:N`, `pane:N`, `surface:N`.
- UUIDs are still accepted as inputs.
- Request UUID output only when needed: `--id-format uuids|both`.

## Deep-Dive References

| Reference | When to Use |
|-----------|-------------|
| [references/handles-and-identify.md](references/handles-and-identify.md) | Handle syntax, self-identify, caller targeting |
| [references/windows-workspaces.md](references/windows-workspaces.md) | Window/workspace lifecycle and reorder/move |
| [references/panes-surfaces.md](references/panes-surfaces.md) | Splits, surfaces, move/reorder, focus routing |
| [references/trigger-flash-and-health.md](references/trigger-flash-and-health.md) | Flash cue and surface health checks |
| [../cmux-workspace/SKILL.md](../cmux-workspace/SKILL.md) | Current caller workspace rules and non-disruptive automation |
| [../cmux-settings/SKILL.md](../cmux-settings/SKILL.md) | Safe amux.json settings edits and validation |
| [../cmux-browser/SKILL.md](../cmux-browser/SKILL.md) | Browser automation on surface-backed webviews |
| [../cmux-markdown/SKILL.md](../cmux-markdown/SKILL.md) | Markdown viewer panel with live file watching |
