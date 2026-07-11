# cmux Workspace Command Reference

Use these commands from a cmux terminal. Most commands infer the caller workspace from `CMUX_WORKSPACE_ID`, but explicit flags are safer for automation.

## Context

```bash
amux identify --json
cmux current-workspace --json
cmux capabilities --json
cmux ping
```

## Windows and Workspaces

```bash
amux list-windows
cmux current-window
amux new-window
cmux focus-window --window window:2
cmux close-window --window window:2

amux list-workspaces
amux list-workspaces --json
amux new-workspace --name "task" --cwd "$PWD"
amux new-workspace --command "npm run dev"
amux new-workspace --layout '{"root":{"type":"terminal"}}'
cmux current-workspace
cmux select-workspace --workspace workspace:2
cmux rename-workspace --workspace workspace:2 -- "new name"
cmux close-workspace --workspace workspace:2
cmux reorder-workspace --workspace workspace:4 --before workspace:2
cmux move-workspace-to-window --workspace workspace:4 --window window:1
```

## Panes and Surfaces

```bash
amux list-panes --workspace "$CMUX_WORKSPACE_ID"
amux list-pane-surfaces --workspace "$CMUX_WORKSPACE_ID" --pane pane:1
amux list-panels --workspace "$CMUX_WORKSPACE_ID"
cmux tree --workspace "$CMUX_WORKSPACE_ID"

amux new-split right --workspace "$CMUX_WORKSPACE_ID"
amux new-split down --workspace "$CMUX_WORKSPACE_ID" --surface "$CMUX_SURFACE_ID"
amux new-pane --workspace "$CMUX_WORKSPACE_ID" --type terminal --direction right
amux new-pane --workspace "$CMUX_WORKSPACE_ID" --type browser --url http://localhost:3000
amux new-surface --workspace "$CMUX_WORKSPACE_ID" --type terminal --pane pane:1
amux new-surface --workspace "$CMUX_WORKSPACE_ID" --type browser --pane pane:1 --url http://localhost:3000

cmux focus-pane --workspace "$CMUX_WORKSPACE_ID" --pane pane:2
cmux focus-panel --workspace "$CMUX_WORKSPACE_ID" --panel surface:3
cmux close-surface --workspace "$CMUX_WORKSPACE_ID" --surface surface:3
cmux move-surface --surface surface:7 --pane pane:2 --focus true
cmux reorder-surface --surface surface:7 --before surface:3
cmux move-tab-to-new-workspace --surface surface:7 --title "browser"
```

## Input

```bash
amux send "echo hello\n"
amux send-key enter
amux send --surface "$CMUX_SURFACE_ID" "git status\n"
amux send-key --surface "$CMUX_SURFACE_ID" enter
cmux read-screen --surface "$CMUX_SURFACE_ID"
```

## Sidebar Metadata

```bash
cmux set-status build "running" --workspace "$CMUX_WORKSPACE_ID" --icon hammer --color "#ff9500"
cmux clear-status build --workspace "$CMUX_WORKSPACE_ID"
amux list-status --workspace "$CMUX_WORKSPACE_ID"
cmux set-progress 0.5 --workspace "$CMUX_WORKSPACE_ID" --label "Building"
cmux clear-progress --workspace "$CMUX_WORKSPACE_ID"
cmux log --workspace "$CMUX_WORKSPACE_ID" --level info -- "Build started"
amux list-log --workspace "$CMUX_WORKSPACE_ID" --limit 20
cmux clear-log --workspace "$CMUX_WORKSPACE_ID"
cmux sidebar-state --workspace "$CMUX_WORKSPACE_ID" --json
```

## Notifications and Attention

```bash
amux notify --title "Done" --body "Task complete"
amux list-notifications --json
cmux clear-notifications
amux trigger-flash --workspace "$CMUX_WORKSPACE_ID" --surface "$CMUX_SURFACE_ID"
cmux surface-health --workspace "$CMUX_WORKSPACE_ID" --json
```

## Config and Docs

```bash
amux docs api
amux docs browser
amux docs settings
amux settings path
amux settings cmux-json
amux settings shortcuts
amux reload-config
```

## Tagged Reloads

```bash
./scripts/reload.sh --tag <short-tag>
CMUX_SOCKET_PATH=/tmp/cmux-debug-<short-tag>.sock amux identify --json
```
