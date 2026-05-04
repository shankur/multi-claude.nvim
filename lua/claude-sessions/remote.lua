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

--- Build the zellij layout KDL string for a session.
---@param claude_cmd_str string  full claude command to run
---@param cwd string|nil  working directory
---@param session_name string  used in the kill-after command
---@return string
local function build_layout(claude_cmd_str, cwd, session_name)
  local opts = config.options
  local layout_file = opts.layout

  -- If user provided a layout file, read and substitute placeholders
  if layout_file then
    layout_file = vim.fn.expand(layout_file)
    local f = io.open(layout_file, "r")
    if f then
      local content = f:read("*a")
      f:close()
      content = content:gsub("{{claude_cmd}}", claude_cmd_str)
      content = content:gsub("{{cwd}}", cwd or "~")
      return content
    end
  end

  -- Built-in default: single tab with claude
  local kill_after = "zellij kill-session -y " .. vim.fn.shellescape(session_name)
    .. " && zellij delete-session " .. vim.fn.shellescape(session_name)
  local claude_inner = "unalias exit 2>/dev/null; " .. claude_cmd_str .. "; " .. kill_after
  local cwd_str = cwd or "~"

  return string.format([[
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
            args "-lc" %q
            cwd %q
        }
    }
}
]], claude_inner, cwd_str)
end

--- Build the claude command string for a host.
---@param host table|nil
---@return string
local function build_claude_cmd(host)
  local opts = config.options
  local cmd = opts.claude_cmd
  if host and host.model then
    cmd = cmd .. " --model '" .. host.model .. "'"
  end
  if host and host.skip_permissions then
    cmd = cmd .. " --dangerously-skip-permissions"
  end
  for _, arg in ipairs(opts.claude_args) do
    cmd = cmd .. " " .. arg
  end
  return cmd
end

--- Create a detached zellij session running claude on a remote host.
---@param host table
---@param session_name string
---@param cwd string|nil  override working directory (nil uses host.cwd)
function M.create_session(host, session_name, cwd)
  -- Check if session already exists
  local existing = M.list_sessions(host)
  for _, name in ipairs(existing) do
    if name == session_name then
      return true
    end
  end

  local claude_cmd_str = build_claude_cmd(host)
  local effective_cwd = cwd or host.cwd
  local layout_str = build_layout(claude_cmd_str, effective_cwd, session_name)

  -- Write layout to a temp file on remote, start session with nohup, clean up
  local tmp = "/tmp/zellij-layout-" .. session_name .. ".kdl"
  local write_cmd = ssh_base(host)
  vim.list_extend(write_cmd, { "--", "cat > " .. tmp })
  vim.fn.system(write_cmd, layout_str)
  if vim.v.shell_error ~= 0 then return false end

  local start_cmd = ssh_base(host)
  local start_str = "TERM=xterm-256color ZELLIJ=skip nohup zellij --session "
    .. vim.fn.shellescape(session_name)
    .. " --new-session-with-layout " .. tmp
    .. " < /dev/null > /dev/null 2>&1 &"
  vim.list_extend(start_cmd, { "--", start_str })
  vim.fn.system(start_cmd)
  if vim.v.shell_error ~= 0 then return false end

  -- Wait up to 5s for session to appear
  for _ = 1, 5 do
    vim.fn.system({ "sleep", "1" })
    local sessions = M.list_sessions(host)
    for _, name in ipairs(sessions) do
      if name == session_name then return true end
    end
  end
  return false
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
  local remote_cmd = "export ZELLIJ=skip TERM=xterm-256color; zellij attach "
    .. vim.fn.shellescape(session_name)
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
  local kill_cmd = ssh_base(host)
  vim.list_extend(kill_cmd, { "--", "TERM=xterm-256color", "zellij", "kill-session", "-y", session_name })
  vim.fn.system(kill_cmd)

  local del_cmd = ssh_base(host)
  vim.list_extend(del_cmd, { "--", "TERM=xterm-256color", "zellij", "delete-session", session_name })
  vim.fn.system(del_cmd)
end

--- Create a local zellij session running claude.
---@param session_name string
---@param cwd string|nil  working directory (nil defaults to ~)
function M.create_local_session(session_name, cwd)
  -- Check if session already exists
  local existing = M.list_local_sessions()
  for _, name in ipairs(existing) do
    if name == session_name then
      return true
    end
  end

  local claude_cmd_str = build_claude_cmd(nil)
  local layout_str = build_layout(claude_cmd_str, cwd, session_name)

  -- Write layout to temp file and start session with nohup
  local tmp = "/tmp/zellij-layout-" .. session_name .. ".kdl"
  local f = io.open(tmp, "w")
  if not f then return false end
  f:write(layout_str)
  f:close()

  vim.fn.system({ "zsh", "-c",
    "TERM=xterm-256color ZELLIJ=skip nohup zellij --session "
    .. vim.fn.shellescape(session_name)
    .. " --new-session-with-layout " .. tmp
    .. " < /dev/null > /dev/null 2>&1 &"
  })
  if vim.v.shell_error ~= 0 then return false end

  -- Wait up to 5s for session to appear
  for _ = 1, 5 do
    vim.fn.system({ "sleep", "1" })
    local sessions = M.list_local_sessions()
    for _, name in ipairs(sessions) do
      if name == session_name then return true end
    end
  end
  return false
end

--- Return the command table for termopen() to attach to a local zellij session.
---@param session_name string
---@return table
function M.local_attach_cmd(session_name)
  return { "zellij", "attach", session_name }
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
