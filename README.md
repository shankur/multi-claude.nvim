# multi-claude.nvim

Manage multiple [Claude Code](https://github.com/anthropics/claude-code) sessions from within Neovim — locally and across remote machines. A sidebar lists all active sessions with live status indicators, while the main pane shows the selected session's terminal.

All sessions run inside [Zellij](https://zellij.dev/) for persistence — close Neovim, reopen it, and re-attach to your running sessions.

```
  Claude Sessions           │
  ───────────────────────── │
                            │
  LOCAL                     │
  ● refactor-auth [working] │  Claude Code terminal
  ─────────────────────────	│  for the selected session
  ALICE                     │
  ◉ fix-tests    [waiting]  │
  ─────────────────────────	│
  BOB                       │
  ● deploy-fix   [working]  │
                            │
```

## Features

- **Multi-session** — run several Claude Code instances in parallel
- **Remote sessions** — start and manage Claude on remote servers via SSH + Zellij
- **Persistent sessions** — sessions survive Neovim restarts; re-attach with a keypress
- **Sidebar navigator** — browse and switch between sessions, grouped by host
- **Live status** — see which sessions are working, waiting for input, or idle
- **Auto-cleanup** — sessions are removed from the sidebar when the process exits
- **Session discovery** — find and attach to existing sessions across all hosts
- **Floating UI** — host picker and clean table for session management

## Requirements

- Neovim >= 0.10
- [Claude Code CLI](https://github.com/anthropics/claude-code) installed and in `$PATH`
- [Zellij](https://zellij.dev/) installed locally (and on remote servers for remote sessions)
- SSH access to remote servers (for remote sessions)

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "shankur/multi-claude.nvim",
  cmd = { "ClaudeSessions", "ClaudeNew", "ClaudeClose", "ClaudeNext", "ClaudePrev", "ClaudeList", "ClaudeClean", "ClaudeDiscover" },
  keys = {
    { "<leader>cc", "<cmd>ClaudeDiscover<cr>", desc = "Discover Claude Sessions" },
    { "<leader>cn", "<cmd>ClaudeNew<cr>",      desc = "New Claude Session" },
    { "<leader>cN", "<cmd>ClaudeNext<cr>",     desc = "Next Claude Session" },
    { "<leader>cP", "<cmd>ClaudePrev<cr>",     desc = "Prev Claude Session" },
    { "<leader>cx", "<cmd>ClaudeClean<cr>",    desc = "Clean Claude Sessions" },
  },
  opts = {
    -- Optional: configure remote hosts
    hosts = {
      { name = "server1", addr = "user@10.0.0.1", cwd = "~/project", model = "opus", skip_permissions = true },
    },
  },
}
```

For local development, replace the plugin name with `dir`:

```lua
{ dir = "~/Repositories/multi-claude.nvim", ... }
```

## Remote Hosts

Configure remote servers to manage Claude sessions over SSH:

```lua
{
  "shankur/multi-claude.nvim",
  opts = {
    hosts = {
      { name = "server1", addr = "user@10.0.0.1", cwd = "~/project" },
      { name = "server2", addr = "deploy@prod.internal", cwd = "~/app", model = "opus" },
    },
  },
}
```

Each host entry supports:

| Field | Required | Description |
|-------|----------|-------------|
| `name` | yes | Display name shown in picker and sidebar |
| `addr` | yes | SSH address (`user@host`) |
| `cwd` | no | Working directory on the remote for Claude |
| `ssh_args` | no | Extra SSH flags (e.g. `{"-p", "2222"}`) |
| `model` | no | Claude model ID to use on this host |
| `skip_permissions` | no | Pass `--dangerously-skip-permissions` to Claude |

## Usage

| Command            | Description                                    |
| ------------------ | ---------------------------------------------- |
| `:ClaudeNew [name]`| Start a new Claude session (shows host picker) |
| `:ClaudeSessions`  | Toggle the sidebar                             |
| `:ClaudeClose`     | Close the active session                       |
| `:ClaudeNext`      | Switch to the next session                     |
| `:ClaudePrev`      | Switch to the previous session                 |
| `:ClaudeDiscover`  | Open sidebar and attach to all existing sessions |
| `:ClaudeList <host>` | List and attach to sessions on a remote host |
| `:ClaudeClean`     | Kill all sessions on a host (shows host picker) |

### Sidebar keymaps

| Key      | Action                          |
| -------- | ------------------------------- |
| `<CR>`   | Switch to session under cursor  |
| `n`      | Create a new session            |
| `d`      | Delete session                  |
| `r`      | Rename session                  |
| `q`      | Close sidebar                   |
| `j` / `k`| Navigate between sessions      |

### Terminal mode

When a Claude session is focused, you're in Neovim's terminal mode (keystrokes go to Claude). Press `<Esc><Esc>` (double escape) to return to normal mode where your leader key, window switching, and all Neovim commands work. Single `<Esc>` is passed through to Claude. Press `i` or `a` to go back into the terminal.

## Status indicators

Status is determined by terminal output activity — no fragile prompt parsing.

| Icon | Status    | Meaning                                       |
| ---- | --------- | --------------------------------------------- |
| `●`  | working   | Terminal received output in the last 2 seconds|
| `◉`  | waiting   | Terminal has been idle (Claude wants input)    |

When a session's process exits, it is removed from the sidebar automatically.

## How it works

```
Local Machine (Neovim)              Remote Server
┌──────────────────────┐           ┌─────────────────┐
│ Sidebar              │           │ Zellij session   │
│  LOCAL               │           │  └─ Claude Code  │
│  ● my-task           │◄── SSH ──►│                  │
│  ─────────────────── │           └─────────────────┘
│  SERVER1             │           ┌─────────────────┐
│  ◉ deploy-fix        │◄── SSH ──►│ Zellij session   │
│  ● migration         │           │  └─ Claude Code  │
└──────────────────────┘           └─────────────────┘
```

Each session runs Claude inside a Zellij session (both local and remote). This provides:

- **Persistence** — sessions survive Neovim restarts and SSH disconnects
- **Isolation** — each Claude instance runs in its own Zellij pane
- **Clean lifecycle** — when Claude exits (`/exit`), the Zellij session is automatically cleaned up

For remote sessions, the plugin:
1. Generates a Zellij layout with the Claude command embedded
2. Creates a detached Zellij session on the server via SSH using that layout
3. Attaches to it from Neovim via `ssh -t host -- zellij attach`

## Configuration

All options with their defaults:

```lua
require("claude-sessions").setup({
  sidebar_width = 35,
  position = "left",           -- "left" or "right"
  claude_cmd = "claude",       -- path to claude binary
  claude_args = {},            -- extra args passed to every session
  hosts = {},                  -- remote host configurations (see Remote Hosts)
  layout = nil,                -- path to a custom Zellij layout file (nil = built-in default)
  icons = {
    working = "●",
    waiting = "◉",
    done = "○",
  },
  status_poll_ms = 1000,       -- how often to check session status (ms)
  idle_threshold_ms = 2000,    -- ms of no output before marking "waiting"
  auto_open = false,           -- auto-open sidebar on first session
  keymaps = {
    select = "<CR>",
    new_session = "n",
    delete_session = "d",
    rename_session = "r",
    close_sidebar = "q",
  },
})
```

### Zellij layout

Each session is created with a 3-tab layout by default:

| Tab | Content |
|-----|---------|
| `claude` | Claude Code (focused on open) |
| `shell` | Plain shell in the working directory |
| `editor` | `nvim` in the working directory |

To use a custom layout file, set the `layout` option:

```lua
require("claude-sessions").setup({
  layout = "~/.config/zellij/layouts/claude-session.kdl",
})
```

In the layout file, use `{{claude_cmd}}` and `{{cwd}}` as placeholders:

```kdl
layout {
    default_tab_template {
        pane size=1 borderless=true {
            plugin location="tab-bar"
        }
        children
        pane size=1 borderless=true {
            plugin location="status-bar"
        }
    }
    tab name="claude" focus=true {
        pane command="zsh" close_on_exit=true {
            args "-lc" "{{claude_cmd}}"
            cwd "{{cwd}}"
        }
    }
    tab name="shell" {
        pane cwd="{{cwd}}"
    }
}
```

## Zellij configuration

For the best experience, unbind `Ctrl-l` (so it passes through to the terminal) and add any other passthrough keys you need:

```kdl
// ~/.config/zellij/config.kdl
keybinds {
    normal {
        unbind "Ctrl l"
        bind "Ctrl r" { SwitchToMode "resize"; }
        bind "Ctrl f" { ToggleFocusFullscreen; }
    }
}
```

## License

MIT
