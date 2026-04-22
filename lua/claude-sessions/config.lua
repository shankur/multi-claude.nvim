local M = {}

M.defaults = {
  sidebar_width = 35,
  position = "left", -- "left" or "right"
  claude_cmd = "claude",
  claude_args = {},
  icons = {
    working = "●",
    waiting = "◉",
    done = "○",
  },
  status_poll_ms = 1000,
  idle_threshold_ms = 2000, -- ms of no output before marking "waiting"
  auto_open = false,
  keymaps = {
    select = "<CR>",
    new_session = "n",
    delete_session = "d",
    rename_session = "r",
    close_sidebar = "q",
  },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", {}, M.defaults, opts or {})
end

return M
