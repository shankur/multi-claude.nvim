local M = {}

M.defaults = {
  sidebar_width = 30,  -- minimum sidebar width (actual width adapts to content or 25% of screen)
  position = "left", -- "left" or "right"
  claude_cmd = "claude",
  claude_args = {},
  skip_permissions = false, -- pass --dangerously-skip-permissions to all sessions
  icons = {
    working = "●",
    waiting = "◉",
    done = "○",
    worktree = "\238\156\165",  -- nf-dev-git_branch (U+E725)
  },
  group_by_cwd = true,
  status_poll_ms = 1000,
  idle_threshold_ms = 2000, -- ms of no output before marking "waiting"
  auto_open = false,
  session_prefix = "claude-", -- prefix for zellij session names (filters discover to plugin sessions only)
  default_cwd = nil, -- default working directory for new sessions (nil = cwd)
  cwd_paths = {}, -- list of frequently used paths for the cwd picker
  hosts = {}, -- { {name="server1", addr="user@host", cwd="~/project", ssh_args={}} }
  layout = nil, -- path to a custom zellij layout file, or nil to use built-in default
  selection_marker = "▶", -- marker shown next to the selected item in pickers and sidebar
  keymaps = {
    select = "<CR>",
    new_session = "n",
    delete_session = "d",
    rename_session = "r",
    close_sidebar = "q",
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
