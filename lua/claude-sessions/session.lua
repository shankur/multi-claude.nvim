local config = require("claude-sessions.config")

local M = {}
M.sessions = {}
M._next_id = 1
M._poll_timer = nil

local function create_session_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "hide", { buf = buf })
  return buf
end

function M.spawn(name)
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
  }
  M._next_id = M._next_id + 1

  -- Build command
  local cmd = { opts.claude_cmd }
  for _, arg in ipairs(opts.claude_args) do
    table.insert(cmd, arg)
  end

  -- We need a window to run termopen in. Use a temporary hidden window.
  local cur_win = vim.api.nvim_get_current_win()
  vim.cmd("botright vnew")
  local tmp_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(tmp_win, buf)

  local job_id = vim.fn.termopen(cmd, {
    on_exit = function(_, exit_code, _)
      vim.schedule(function()
        local sidebar = require("claude-sessions.sidebar")

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

  -- Map <Esc> in terminal mode to exit to normal mode
  vim.api.nvim_buf_set_keymap(buf, "t", "<Esc>", [[<C-\><C-n>]], { noremap = true, silent = true })

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
  local sidebar = require("claude-sessions.sidebar")
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
