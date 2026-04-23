local config = require("claude-sessions.config")

local M = {}

--- Build the base SSH command for a host.
---@param host table { name, addr, ssh_args? }
---@return table
local function ssh_base(host)
  local cmd = { "ssh" }
  if host.ssh_args then
    for _, arg in ipairs(host.ssh_args) do
      table.insert(cmd, arg)
    end
  end
  table.insert(cmd, host.addr)
  return cmd
end

--- Create a detached zellij session running claude on a remote host.
---@param host table
---@param session_name string
function M.create_session(host, session_name)
  local opts = config.options

  -- Check if session already exists with a running pane
  local existing = M.list_sessions(host)
  for _, name in ipairs(existing) do
    if name == session_name then
      -- Session exists, just attach to it (don't create new claude pane)
      return true
    end
  end

  -- Step 1: Create detached zellij session
  local create_cmd = ssh_base(host)
  vim.list_extend(create_cmd, { "--", "TERM=xterm-256color", "zellij", "attach", "--create-background", session_name })
  local out1 = vim.fn.system(create_cmd)
  if vim.v.shell_error ~= 0 then
    if not out1:match("already exists") then
      return false
    end
  end

  -- Step 2: Run claude in a new pane
  local claude_cmd_str = opts.claude_cmd
  if host.model then
    claude_cmd_str = claude_cmd_str .. " --model '" .. host.model .. "'"
  end
  if host.skip_permissions then
    claude_cmd_str = claude_cmd_str .. " --dangerously-skip-permissions"
  end
  for _, arg in ipairs(opts.claude_args) do
    claude_cmd_str = claude_cmd_str .. " " .. arg
  end

  local run_cmd = ssh_base(host)
  local run_str = "TERM=xterm-256color zellij -s " .. vim.fn.shellescape(session_name)
    .. " run -c --name " .. vim.fn.shellescape(session_name)
  local kill_after = "zellij kill-session -y " .. vim.fn.shellescape(session_name)
    .. " && zellij delete-session " .. vim.fn.shellescape(session_name)
  if host.cwd then
    run_str = run_str .. " -- env ZELLIJ=skip zsh -lc " .. vim.fn.shellescape("unalias exit 2>/dev/null; cd " .. host.cwd .. " && " .. claude_cmd_str .. "; " .. kill_after)
  else
    run_str = run_str .. " -- env ZELLIJ=skip zsh -lc " .. vim.fn.shellescape("unalias exit 2>/dev/null; " .. claude_cmd_str .. "; " .. kill_after)
  end
  vim.list_extend(run_cmd, { "--", run_str })
  local out2 = vim.fn.system(run_cmd)
  if vim.v.shell_error ~= 0 then
    return false
  end

  -- Step 3: Close the original shell pane, leaving only claude
  local close_cmd = ssh_base(host)
  local close_str = "TERM=xterm-256color zellij -s " .. vim.fn.shellescape(session_name)
    .. " action close-pane -p terminal_0"
  vim.list_extend(close_cmd, { "--", close_str })
  vim.fn.system(close_cmd)
  if vim.v.shell_error ~= 0 then
    return false
  end

  return true
end

--- Return the command table for termopen() to attach to a remote zellij session.
---@param host table
---@param session_name string
---@return table
function M.attach_cmd(host, session_name)
  local cmd = { "ssh", "-t" }
  if host.ssh_args then
    for _, arg in ipairs(host.ssh_args) do
      table.insert(cmd, arg)
    end
  end
  -- Set ZELLIJ to skip auto-attach in remote .zshrc, set TERM, then attach
  local remote_cmd = "export ZELLIJ=skip TERM=xterm-256color; zellij attach --force-run-commands " .. vim.fn.shellescape(session_name)
  vim.list_extend(cmd, { host.addr, "--", remote_cmd })
  return cmd
end

--- List zellij sessions on a remote host.
---@param host table
---@return table list of session name strings
function M.list_sessions(host)
  local cmd = ssh_base(host)
  vim.list_extend(cmd, { "--", "TERM=xterm-256color", "zellij", "list-sessions", "--short" })
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local sessions = {}
  for line in output:gmatch("[^\r\n]+") do
    local name = line:match("^(%S+)")
    if name and name ~= "" then
      table.insert(sessions, name)
    end
  end
  return sessions
end

--- Kill all zellij sessions on a remote host.
---@param host table
function M.kill_all_sessions(host)
  local kill_cmd = ssh_base(host)
  vim.list_extend(kill_cmd, { "--", "TERM=xterm-256color", "zellij", "kill-all-sessions", "-y" })
  vim.fn.system(kill_cmd)

  local delete_cmd = ssh_base(host)
  vim.list_extend(delete_cmd, { "--", "TERM=xterm-256color", "zellij", "delete-all-sessions", "-y" })
  vim.fn.system(delete_cmd)
end

--- Kill a zellij session on a remote host.
---@param host table
---@param session_name string
function M.kill_session(host, session_name)
  local cmd = ssh_base(host)
  vim.list_extend(cmd, { "--", "TERM=xterm-256color", "zellij", "delete-session", session_name })
  vim.fn.system(cmd)
end

--- Create a local zellij session running claude.
---@param session_name string
function M.create_local_session(session_name)
  local opts = config.options

  -- Check if session already exists
  local existing = M.list_local_sessions()
  for _, name in ipairs(existing) do
    if name == session_name then
      return true
    end
  end

  -- Step 1: Create detached zellij session
  vim.fn.system({ "zellij", "attach", "--create-background", session_name })
  if vim.v.shell_error ~= 0 then
    return false
  end

  -- Step 2: Run claude in a new pane
  local claude_cmd_str = opts.claude_cmd
  for _, arg in ipairs(opts.claude_args) do
    claude_cmd_str = claude_cmd_str .. " " .. arg
  end

  local kill_after = "zellij kill-session -y " .. vim.fn.shellescape(session_name)
    .. " && zellij delete-session " .. vim.fn.shellescape(session_name)
  local run_str = "zellij -s " .. vim.fn.shellescape(session_name)
    .. " run -c --name " .. vim.fn.shellescape(session_name)
    .. " -- zsh -lc " .. vim.fn.shellescape("unalias exit 2>/dev/null; " .. claude_cmd_str .. "; " .. kill_after)
  vim.fn.system({ "zsh", "-c", run_str })
  if vim.v.shell_error ~= 0 then
    return false
  end

  -- Step 3: Close the original shell pane
  vim.fn.system({ "zsh", "-c", "zellij -s " .. vim.fn.shellescape(session_name) .. " action close-pane -p terminal_0" })

  return true
end

--- Return the command table for termopen() to attach to a local zellij session.
---@param session_name string
---@return table
function M.local_attach_cmd(session_name)
  return { "zellij", "attach", "--force-run-commands", session_name }
end

--- List local zellij sessions.
---@return table
function M.list_local_sessions()
  local output = vim.fn.system({ "zellij", "list-sessions", "--short" })
  if vim.v.shell_error ~= 0 then
    return {}
  end
  local sessions = {}
  for line in output:gmatch("[^\r\n]+") do
    local name = line:match("^(%S+)")
    if name and name ~= "" then
      table.insert(sessions, name)
    end
  end
  return sessions
end

--- Kill all local zellij sessions.
function M.kill_all_local_sessions()
  vim.fn.system({ "zellij", "kill-all-sessions", "-y" })
  vim.fn.system({ "zellij", "delete-all-sessions", "-y" })
end

--- Kill a local zellij session.
---@param session_name string
function M.kill_local_session(session_name)
  vim.fn.system({ "zellij", "kill-session", "-y", session_name })
  vim.fn.system({ "zellij", "delete-session", session_name })
end

--- Find a host config by name.
---@param name string
---@return table|nil
function M.get_host(name)
  for _, host in ipairs(config.options.hosts) do
    if host.name == name then
      return host
    end
  end
  return nil
end

return M
