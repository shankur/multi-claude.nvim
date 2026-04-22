local config = require("claude-sessions.config")
local session_mod = require("claude-sessions.session")

local M = {}
M._sidebar_buf = nil
M._sidebar_win = nil
M._main_win = nil
M._selected_session_id = nil

local ns = vim.api.nvim_create_namespace("claude_sessions")

local function setup_highlights()
  vim.api.nvim_set_hl(0, "ClaudeSessionWorking", { fg = "#a6e3a1", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionWaiting", { fg = "#f9e2af", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionDone", { fg = "#6c7086", default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionSelected", { fg = "#cdd6f4", bg = "#45475a", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionTitle", { fg = "#cba6f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionBorder", { fg = "#585b70", default = true })
end

function M.is_open()
  return M._sidebar_win ~= nil and vim.api.nvim_win_is_valid(M._sidebar_win)
end

function M.render()
  if not M._sidebar_buf or not vim.api.nvim_buf_is_valid(M._sidebar_buf) then return end

  local opts = config.options
  local lines = {}
  local highlights = {}

  -- Header
  table.insert(lines, "  Claude Sessions")
  table.insert(highlights, { line = 0, hl = "ClaudeSessionTitle" })
  table.insert(lines, "  " .. string.rep("\u{2500}", opts.sidebar_width - 4))
  table.insert(highlights, { line = 1, hl = "ClaudeSessionBorder" })
  table.insert(lines, "")

  if #session_mod.sessions == 0 then
    table.insert(lines, "  No sessions")
    table.insert(lines, "")
    table.insert(lines, "  Press 'n' to create one")
  else
    for _, session in ipairs(session_mod.sessions) do
      local icon = opts.icons[session.status] or "?"
      local status_str = "[" .. session.status .. "]"
      local prefix = "  "
      local line = prefix .. icon .. " " .. session.name .. " " .. status_str
      local line_idx = #lines
      table.insert(lines, line)

      -- Highlight based on status
      local hl_group = "ClaudeSessionDone"
      if session.status == "working" then
        hl_group = "ClaudeSessionWorking"
      elseif session.status == "waiting" then
        hl_group = "ClaudeSessionWaiting"
      end

      -- Selected session gets special highlight
      if session.id == M._selected_session_id then
        table.insert(highlights, { line = line_idx, hl = "ClaudeSessionSelected" })
      else
        table.insert(highlights, { line = line_idx, hl = hl_group })
      end
    end
  end

  -- Write lines
  vim.api.nvim_set_option_value("modifiable", true, { buf = M._sidebar_buf })
  vim.api.nvim_buf_set_lines(M._sidebar_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = M._sidebar_buf })

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(M._sidebar_buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, M._sidebar_buf, ns, hl.hl, hl.line, 0, -1)
  end
end

local function get_session_at_cursor()
  if not M.is_open() then return nil end
  local cursor = vim.api.nvim_win_get_cursor(M._sidebar_win)
  local row = cursor[1] -- 1-indexed
  local header_lines = 3 -- title, border, blank
  local idx = row - header_lines
  if idx >= 1 and idx <= #session_mod.sessions then
    return session_mod.sessions[idx]
  end
  return nil
end

local function ensure_main_win()
  -- Find or create the main window (not the sidebar)
  if M._main_win and vim.api.nvim_win_is_valid(M._main_win) then
    return M._main_win
  end

  -- Look for a non-sidebar window
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if win ~= M._sidebar_win then
      M._main_win = win
      return win
    end
  end

  -- Create one if none exists
  vim.cmd("botright vnew")
  M._main_win = vim.api.nvim_get_current_win()
  return M._main_win
end

local function switch_to_session(session)
  if not session then return end
  M._selected_session_id = session.id
  local win = ensure_main_win()
  if vim.api.nvim_buf_is_valid(session.bufnr) then
    vim.api.nvim_win_set_buf(win, session.bufnr)
    -- Focus the main window and enter terminal mode
    vim.api.nvim_set_current_win(win)
    vim.cmd("startinsert")
  end
  M.render()
end

local function setup_keymaps()
  local opts = config.options.keymaps
  local buf = M._sidebar_buf
  local map_opts = { buffer = buf, noremap = true, silent = true, nowait = true }

  -- Select session
  vim.keymap.set("n", opts.select, function()
    local session = get_session_at_cursor()
    if session then
      switch_to_session(session)
    end
  end, map_opts)

  -- New session
  vim.keymap.set("n", opts.new_session, function()
    local cs = require("claude-sessions")
    cs.new_session()
  end, map_opts)

  -- Delete session
  vim.keymap.set("n", opts.delete_session, function()
    local session = get_session_at_cursor()
    if session then
      -- Find the next session to switch to before closing
      local next_session = nil
      for _, s in ipairs(session_mod.sessions) do
        if s.id ~= session.id then
          next_session = s
          break
        end
      end

      -- If there's a next session, show it in the main window first
      -- so that closing the old buffer doesn't destroy the window
      if next_session then
        local win = ensure_main_win()
        vim.api.nvim_win_set_buf(win, next_session.bufnr)
      end

      session_mod.close(session.id)

      if next_session then
        M._selected_session_id = next_session.id
        switch_to_session(next_session)
      else
        M._selected_session_id = nil
        local win = ensure_main_win()
        local empty = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_win_set_buf(win, empty)
      end
      M.render()
    end
  end, map_opts)

  -- Rename session
  vim.keymap.set("n", opts.rename_session, function()
    local session = get_session_at_cursor()
    if session then
      vim.ui.input({ prompt = "Rename session: ", default = session.name }, function(name)
        if name and name ~= "" then
          session_mod.rename(session.id, name)
          M.render()
        end
      end)
    end
  end, map_opts)

  -- Close sidebar
  vim.keymap.set("n", opts.close_sidebar, function()
    M.close()
  end, map_opts)
end

function M.open()
  if M.is_open() then
    vim.api.nvim_set_current_win(M._sidebar_win)
    return
  end

  setup_highlights()

  local opts = config.options

  -- Remember current window as main
  M._main_win = vim.api.nvim_get_current_win()

  -- Create sidebar buffer
  M._sidebar_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("buftype", "nofile", { buf = M._sidebar_buf })
  vim.api.nvim_set_option_value("swapfile", false, { buf = M._sidebar_buf })
  vim.api.nvim_set_option_value("filetype", "claude-sessions", { buf = M._sidebar_buf })
  vim.api.nvim_buf_set_name(M._sidebar_buf, "Claude Sessions")

  -- Create sidebar window
  local split_cmd = opts.position == "right" and "botright" or "topleft"
  vim.cmd(split_cmd .. " vnew")
  M._sidebar_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(M._sidebar_win, M._sidebar_buf)
  vim.api.nvim_win_set_width(M._sidebar_win, opts.sidebar_width)

  -- Window options
  vim.api.nvim_set_option_value("winfixwidth", true, { win = M._sidebar_win })
  vim.api.nvim_set_option_value("number", false, { win = M._sidebar_win })
  vim.api.nvim_set_option_value("relativenumber", false, { win = M._sidebar_win })
  vim.api.nvim_set_option_value("signcolumn", "no", { win = M._sidebar_win })
  vim.api.nvim_set_option_value("foldcolumn", "0", { win = M._sidebar_win })
  vim.api.nvim_set_option_value("wrap", false, { win = M._sidebar_win })
  vim.api.nvim_set_option_value("cursorline", true, { win = M._sidebar_win })

  setup_keymaps()
  M.render()

  -- If there's a selected session, show it in main
  if M._selected_session_id then
    local session = session_mod.get_by_id(M._selected_session_id)
    if session then
      vim.api.nvim_win_set_buf(M._main_win, session.bufnr)
    end
  end
end

function M.close()
  if M._sidebar_win and vim.api.nvim_win_is_valid(M._sidebar_win) then
    vim.api.nvim_win_close(M._sidebar_win, true)
  end
  M._sidebar_win = nil
  if M._sidebar_buf and vim.api.nvim_buf_is_valid(M._sidebar_buf) then
    pcall(vim.api.nvim_buf_delete, M._sidebar_buf, { force = true })
  end
  M._sidebar_buf = nil
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
  end
end

return M
