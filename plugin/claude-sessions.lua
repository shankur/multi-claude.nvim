vim.api.nvim_create_user_command("ClaudeSessions", function()
  require("claude-sessions").toggle()
end, { desc = "Toggle Claude sessions sidebar" })

vim.api.nvim_create_user_command("ClaudeNew", function(opts)
  local name = opts.args ~= "" and opts.args or nil
  require("claude-sessions").new_session(name)
end, { nargs = "?", desc = "Create a new Claude session" })

vim.api.nvim_create_user_command("ClaudeResume", function(opts)
  local name = opts.args ~= "" and opts.args or nil
  require("claude-sessions").resume_session(name)
end, { nargs = "?", desc = "Resume a Claude session (--resume)" })

vim.api.nvim_create_user_command("ClaudeClose", function()
  require("claude-sessions").close_session()
end, { desc = "Close current Claude session" })

vim.api.nvim_create_user_command("ClaudeNext", function()
  require("claude-sessions").next_session()
end, { desc = "Switch to next Claude session" })

vim.api.nvim_create_user_command("ClaudePrev", function()
  require("claude-sessions").prev_session()
end, { desc = "Switch to previous Claude session" })

vim.api.nvim_create_user_command("ClaudeList", function(opts)
  local host_name = opts.args ~= "" and opts.args or nil
  if not host_name then
    vim.notify("Usage: :ClaudeList <host_name>", vim.log.levels.ERROR)
    return
  end
  require("claude-sessions").list_remote_sessions(host_name)
end, { nargs = "?", desc = "List and attach to remote zellij sessions" })

vim.api.nvim_create_user_command("ClaudeClean", function()
  require("claude-sessions").clean_remote_sessions()
end, { desc = "Clean all zellij sessions on a remote host" })

vim.api.nvim_create_user_command("ClaudeDiscover", function()
  require("claude-sessions").discover()
end, { desc = "Open sidebar and attach to all remote sessions" })

vim.api.nvim_create_user_command("ClaudeJump", function()
  require("claude-sessions").jump_picker()
end, { desc = "Jump to a session via fuzzy picker" })

for i = 1, 9 do
  vim.api.nvim_create_user_command("ClaudeJump" .. i, function()
    require("claude-sessions").jump_to_index(i)
  end, { desc = "Jump to session " .. i })
end
