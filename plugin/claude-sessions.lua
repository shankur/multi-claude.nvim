vim.api.nvim_create_user_command("ClaudeSessions", function()
  require("claude-sessions").toggle()
end, { desc = "Toggle Claude sessions sidebar" })

vim.api.nvim_create_user_command("ClaudeNew", function(opts)
  local name = opts.args ~= "" and opts.args or nil
  require("claude-sessions").new_session(name)
end, { nargs = "?", desc = "Create a new Claude session" })

vim.api.nvim_create_user_command("ClaudeClose", function()
  require("claude-sessions").close_session()
end, { desc = "Close current Claude session" })

vim.api.nvim_create_user_command("ClaudeNext", function()
  require("claude-sessions").next_session()
end, { desc = "Switch to next Claude session" })

vim.api.nvim_create_user_command("ClaudePrev", function()
  require("claude-sessions").prev_session()
end, { desc = "Switch to previous Claude session" })
