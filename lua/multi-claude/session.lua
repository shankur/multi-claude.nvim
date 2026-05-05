local config = require("multi-claude.config")

local M = {}
M.sessions = {}
M._next_id = 1
M._poll_timer = nil

--- Detect git status of a cwd: "worktree", "repo", or nil (not a git repo).
---@param cwd string|nil
---@param host table|nil
---@return string|nil  "worktree", "repo", or nil
local function detect_git_type(cwd, host)
  if not cwd then return nil end
  local cmd
  if host then
    local remote = require("multi-claude.remote")
    local ssh = remote.ssh_base(host)
    cmd = table.concat(ssh, " ") .. " -- git -C " .. vim.fn.shellescape(cwd)
      .. " rev-parse --git-common-dir --git-dir 2>/dev/null"
  else
    cmd = "git -C " .. vim.fn.shellescape(vim.fn.expand(cwd))
      .. " rev-parse --git-common-dir --git-dir 2>/dev/null"
  end
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then return nil end
  local lines = {}
  for line in output:gmatch("[^\r\n]+") do table.insert(lines, line) end
  if #lines < 2 then return nil end
  -- If git-common-dir != git-dir, it's a worktree
  if lines[1] ~= lines[2] then return "worktree" end
  return "repo"
end

--- Query the cwd of an existing zellij session by dumping its layout.
---@param zellij_session_name string
---@param host table|nil
---@return string|nil
local function query_session_cwd(zellij_session_name, host)
  local cmd
  if host then
    local remote = require("multi-claude.remote")
    local ssh = remote.ssh_base(host)
    cmd = table.concat(ssh, " ") .. " -- ZELLIJ=skip zellij action --session "
      .. vim.fn.shellescape(zellij_session_name) .. " dump-layout 2>/dev/null"
  else
    cmd = "ZELLIJ=skip zellij action --session "
      .. vim.fn.shellescape(zellij_session_name) .. " dump-layout 2>/dev/null"
  end
  local output = vim.fn.system(cmd)
  if vim.v.shell_error ~= 0 then return nil end
  -- Parse first cwd "..." from KDL output
  return output:match('cwd%s+"([^"]+)"') or output:match("cwd%s+(%S+)")
end

local function create_session_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  return buf
end

function M.spawn(name, host, cwd, extra_args)
  local opts = config.options
  local buf = create_session_buf()
  local session = {
    id = M._next_id,
    name = name or ("session-" .. M._next_id),
    bufnr = buf,
    job_id = nil,
    status = "working",
    created_at = os.time(),
    last_output_at = vim.uv.now(), -- ms timestamp of last terminal output
    host = host, -- nil = local, table = remote host config
    cwd = cwd,
    git_type = detect_git_type(cwd, host),  -- "worktree", "repo", or nil
  }
  M._next_id = M._next_id + 1

  -- Build command
  local cmd
  if host then
    local remote = require("multi-claude.remote")
    if not remote.create_session(host, session.name, cwd, extra_args) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      return nil
    end
    cmd = remote.attach_cmd(host, session.name)
  else
    local remote = require("multi-claude.remote")
    if not remote.create_local_session(session.name, cwd, extra_args) then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      return nil
    end
    cmd = remote.local_attach_cmd(session.name)
  end

  -- We need a window to run termopen in. Use a temporary hidden window.
  local cur_win = vim.api.nvim_get_current_win()
  vim.cmd("botright vnew")
  local tmp_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(tmp_win, buf)

  local job_id = vim.fn.termopen(cmd, {
    on_exit = function(_, exit_code, _)
      vim.schedule(function()
        local sidebar = require("multi-claude.sidebar")

        -- If this was the selected session, switch to another first
        -- so deleting the buffer doesn't destroy the main window
        if sidebar._selected_session_id == session.id then
          local next_session = nil
          for _, s in ipairs(M.sessions) do
            if s.id ~= session.id then
              next_session = s
              break
            end
          end

          if next_session then
            sidebar._selected_session_id = next_session.id
            local win = sidebar._main_win
            if win and vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_win_set_buf(win, next_session.bufnr)
            end
          else
            sidebar._selected_session_id = nil
            M._stop_polling()
          end
        end

        -- Now safe to remove the session and delete its buffer
        local idx = M.get_index(session.id)
        if idx then
          if vim.api.nvim_buf_is_valid(session.bufnr) then
            pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
          end
          table.remove(M.sessions, idx)
        end

        sidebar.render()
      end)
    end,
  })

  -- Close the temporary window
  vim.api.nvim_win_close(tmp_win, true)
  vim.api.nvim_set_current_win(cur_win)

  session.job_id = job_id

  -- Map <Esc><Esc> in terminal mode to exit to normal mode
  vim.api.nvim_buf_set_keymap(buf, "t", "<Esc><Esc>", [[<C-\><C-n>]], { noremap = true, silent = true })
  -- Pass Ctrl-l through to the terminal (Neovim intercepts it by default)
  vim.api.nvim_buf_set_keymap(buf, "t", "<C-l>", "<C-l>", { noremap = true, silent = true })

  -- Track terminal output activity via buffer changes
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      session.last_output_at = vim.uv.now()
    end,
  })

  table.insert(M.sessions, session)

  M._ensure_polling()

  return session
end

function M.get_by_id(id)
  for _, s in ipairs(M.sessions) do
    if s.id == id then return s end
  end
  return nil
end

function M.get_index(id)
  for i, s in ipairs(M.sessions) do
    if s.id == id then return i end
  end
  return nil
end

function M.close(id)
  local idx = M.get_index(id)
  if not idx then return end
  local session = M.sessions[idx]

  -- Stop the job if still running
  if session.job_id and session.status ~= "done" then
    pcall(vim.fn.jobstop, session.job_id)
  end

  -- Kill zellij session
  local remote = require("multi-claude.remote")
  if session.host then
    remote.kill_session(session.host, session.name)
  else
    remote.kill_local_session(session.name)
  end

  -- Delete the buffer
  if vim.api.nvim_buf_is_valid(session.bufnr) then
    pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
  end

  table.remove(M.sessions, idx)

  if #M.sessions == 0 then
    M._stop_polling()
  end
end

function M.rename(id, new_name)
  local session = M.get_by_id(id)
  if session then
    session.name = new_name
  end
end

--- Attach to an existing zellij session (no create step).
function M.attach(name, host)
  local remote = require("multi-claude.remote")
  local buf = create_session_buf()

  -- Query cwd from the running zellij session
  local prefix = config.options.session_prefix or ""
  local zname = prefix .. name
  local cwd = query_session_cwd(zname, host)

  local session = {
    id = M._next_id,
    name = name,
    bufnr = buf,
    job_id = nil,
    status = "working",
    created_at = os.time(),
    last_output_at = vim.uv.now(),
    host = host,
    cwd = cwd,
    git_type = detect_git_type(cwd, host),  -- "worktree", "repo", or nil
  }
  M._next_id = M._next_id + 1

  local cmd
  if host then
    cmd = remote.attach_cmd(host, name)
  else
    cmd = remote.local_attach_cmd(name)
  end

  local cur_win = vim.api.nvim_get_current_win()
  vim.cmd("botright vnew")
  local tmp_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(tmp_win, buf)

  local job_id = vim.fn.termopen(cmd, {
    on_exit = function(_, _, _)
      vim.schedule(function()
        local sidebar = require("multi-claude.sidebar")
        if sidebar._selected_session_id == session.id then
          local next_session = nil
          for _, s in ipairs(M.sessions) do
            if s.id ~= session.id then
              next_session = s
              break
            end
          end
          if next_session then
            sidebar._selected_session_id = next_session.id
            local win = sidebar._main_win
            if win and vim.api.nvim_win_is_valid(win) then
              vim.api.nvim_win_set_buf(win, next_session.bufnr)
            end
          else
            sidebar._selected_session_id = nil
            M._stop_polling()
          end
        end
        local idx = M.get_index(session.id)
        if idx then
          if vim.api.nvim_buf_is_valid(session.bufnr) then
            pcall(vim.api.nvim_buf_delete, session.bufnr, { force = true })
          end
          table.remove(M.sessions, idx)
        end
        sidebar.render()
      end)
    end,
  })

  vim.api.nvim_win_close(tmp_win, true)
  vim.api.nvim_set_current_win(cur_win)

  session.job_id = job_id
  vim.api.nvim_buf_set_keymap(buf, "t", "<Esc><Esc>", [[<C-\><C-n>]], { noremap = true, silent = true })
  vim.api.nvim_buf_attach(buf, false, {
    on_lines = function()
      session.last_output_at = vim.uv.now()
    end,
  })

  table.insert(M.sessions, session)
  M._ensure_polling()
  return session
end

-- Status detection based on terminal output activity.
-- If output was received recently, Claude is "working".
-- If idle for longer than the threshold, Claude is "waiting" for input.

local function detect_status(session)
  if not vim.api.nvim_buf_is_valid(session.bufnr) then
    return
  end

  local threshold = config.options.idle_threshold_ms or 2000
  local elapsed = vim.uv.now() - session.last_output_at
  if elapsed < threshold then
    session.status = "working"
  else
    session.status = "waiting"
  end
end

function M.poll_status()
  for _, session in ipairs(M.sessions) do
    detect_status(session)
  end
  local sidebar = require("multi-claude.sidebar")
  if sidebar.is_open() then
    sidebar.render()
  end
end

function M._ensure_polling()
  if M._poll_timer then return end
  local timer = vim.uv.new_timer()
  timer:start(config.options.status_poll_ms, config.options.status_poll_ms, vim.schedule_wrap(function()
    M.poll_status()
  end))
  M._poll_timer = timer
end

function M._stop_polling()
  if M._poll_timer then
    M._poll_timer:stop()
    M._poll_timer:close()
    M._poll_timer = nil
  end
end

return M
