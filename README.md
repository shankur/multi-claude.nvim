# multi-claude.nvim

Manage multiple [Claude Code](https://github.com/anthropics/claude-code) sessions from within Neovim. A sidebar lists all active sessions with live status indicators, while the main pane shows the selected session's terminal.

```
  Claude Sessions           │
  ───────────────────────── │
                            │
  ● refactor-auth [working] │  Claude Code terminal
  ◉ fix-tests    [waiting]  │  for the selected session
                            │
```

## Features

- **Multi-session** — run several Claude Code instances in parallel
- **Sidebar navigator** — browse and switch between sessions
- **Live status** — see which sessions are working, waiting for input, or idle
- **Auto-cleanup** — sessions are removed from the sidebar when the process exits
- **Escape to normal mode** — press `<Esc>` in a Claude terminal to use Neovim commands, leader key, and window navigation

## Requirements

- Neovim >= 0.10
- [Claude Code CLI](https://github.com/anthropics/claude-code) installed and in `$PATH`

## Installation

### [lazy.nvim](https://github.com/folke/lazy.nvim)

```lua
{
  "ansharma/multi-claude.nvim",
  cmd = { "ClaudeSessions", "ClaudeNew", "ClaudeClose", "ClaudeNext", "ClaudePrev" },
  keys = {
    { "<leader>cs", "<cmd>ClaudeSessions<cr>", desc = "Claude Sessions" },
    { "<leader>cn", "<cmd>ClaudeNew<cr>", desc = "New Claude Session" },
    { "<leader>cN", "<cmd>ClaudeNext<cr>", desc = "Next Claude Session" },
    { "<leader>cP", "<cmd>ClaudePrev<cr>", desc = "Prev Claude Session" },
  },
  opts = {},
}
```

For local development, replace the plugin name with `dir`:

```lua
{ dir = "~/Repositories/multi-claude.nvim", ... }
```

## Usage

| Command            | Description                        |
| ------------------ | ---------------------------------- |
| `:ClaudeSessions`  | Toggle the sidebar                 |
| `:ClaudeNew [name]`| Start a new Claude session         |
| `:ClaudeClose`     | Close the active session           |
| `:ClaudeNext`      | Switch to the next session         |
| `:ClaudePrev`      | Switch to the previous session     |

### Sidebar keymaps

| Key      | Action                          |
| -------- | ------------------------------- |
| `<CR>`   | Switch to session under cursor  |
| `n`      | Create a new session            |
| `d`      | Delete session                  |
| `r`      | Rename session                  |
| `q`      | Close sidebar                   |
| `j` / `k`| Navigate (normal Neovim motion)|

### Terminal mode

When a Claude session is focused, you're in Neovim's terminal mode (keystrokes go to Claude). Press `<Esc>` to return to normal mode where your leader key, window switching, and all Neovim commands work. Press `i` or `a` to go back into the terminal.

## Status indicators

Status is determined by terminal output activity — no fragile prompt parsing.

| Icon | Status    | Meaning                                       |
| ---- | --------- | --------------------------------------------- |
| `●`  | working   | Terminal received output in the last 2 seconds|
| `◉`  | waiting   | Terminal has been idle (Claude wants input)    |

When a session's process exits, it is removed from the sidebar automatically.

## Configuration

All options with their defaults:

```lua
require("claude-sessions").setup({
  sidebar_width = 35,
  position = "left",           -- "left" or "right"
  claude_cmd = "claude",       -- path to claude binary
  claude_args = {},            -- extra args passed to every session
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

## License

MIT
