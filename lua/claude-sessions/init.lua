local config = require("claude-sessions.config")
local session = require("claude-sessions.session")
local sidebar = require("claude-sessions.sidebar")

local M = {}

function M.setup(opts)
  config.setup(opts)
end

function M.toggle()
  sidebar.toggle()
end

function M.open()
  sidebar.open()
end

function M.close()
  sidebar.close()
end

function M.new_session(name)
  local s = session.spawn(name)
  sidebar._selected_session_id = s.id

  -- Open sidebar if not open and auto_open is set, or if sidebar is open already
  if sidebar.is_open() then
    sidebar.render()
    -- Show the new session in the main window
    local win = sidebar._main_win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_buf(win, s.bufnr)
      vim.api.nvim_set_current_win(win)
      vim.cmd("startinsert")
    end
  elseif config.options.auto_open or #session.sessions == 1 then
    sidebar.open()
    -- Show the session in main
    local win = sidebar._main_win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_buf(win, s.bufnr)
      vim.api.nvim_set_current_win(win)
      vim.cmd("startinsert")
    end
  end

  return s
end

function M.close_session(id)
  id = id or sidebar._selected_session_id
  if id then
    session.close(id)
    -- Update selection
    if #session.sessions > 0 then
      sidebar._selected_session_id = session.sessions[1].id
    else
      sidebar._selected_session_id = nil
    end
    sidebar.render()
  end
end

function M.next_session()
  if #session.sessions == 0 then return end
  local current_id = sidebar._selected_session_id
  local idx = session.get_index(current_id) or 0
  idx = (idx % #session.sessions) + 1
  local s = session.sessions[idx]
  sidebar._selected_session_id = s.id

  -- Switch main window buffer
  local win = sidebar._main_win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_buf(win, s.bufnr)
  end
  sidebar.render()
end

function M.prev_session()
  if #session.sessions == 0 then return end
  local current_id = sidebar._selected_session_id
  local idx = session.get_index(current_id) or 2
  idx = ((idx - 2) % #session.sessions) + 1
  local s = session.sessions[idx]
  sidebar._selected_session_id = s.id

  -- Switch main window buffer
  local win = sidebar._main_win
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_win_set_buf(win, s.bufnr)
  end
  sidebar.render()
end

return M
