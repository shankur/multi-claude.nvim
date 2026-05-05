local config = require("claude-sessions.config")
local session_mod = require("claude-sessions.session")

local M = {}
M._sidebar_buf = nil
M._sidebar_win = nil
M._main_win = nil
M._selected_session_id = nil

local ns = vim.api.nvim_create_namespace("claude_sessions")

function M._format_session_line(s, opts, idx)
  local icon = opts.icons[s.status] or "?"
  local num = idx and (idx .. " ") or "  "
  return "  " .. num .. icon .. " " .. s.name
end

--- Shorten a path zsh-style: intermediate dirs become first char, last component stays full.
--- e.g. ~/Repositories/multi-claude.nvim → ~/R/multi-claude.nvim
---@param path string
---@return string
local function shorten_path(path)
  local parts = {}
  for part in path:gmatch("[^/]+") do
    table.insert(parts, part)
  end
  if #parts <= 1 then return path end
  -- Keep prefix (~ or first component) and last component full, shorten middle
  local result = {}
  for i, part in ipairs(parts) do
    if i == #parts then
      -- Last component: keep full
      table.insert(result, part)
    elseif part == "~" then
      table.insert(result, "~")
    elseif i == 1 and path:sub(1, 1) == "/" then
      -- Root-level dir after /: shorten
      table.insert(result, part:sub(1, 1))
    else
      -- Intermediate: first char only
      table.insert(result, part:sub(1, 1))
    end
  end
  local shortened = table.concat(result, "/")
  if path:sub(1, 1) == "/" and shortened:sub(1, 1) ~= "~" then
    shortened = "/" .. shortened
  end
  return shortened
end

--- Build the inline cwd suffix for a session line.
---@param s table session
---@param opts table config options
---@return string|nil suffix text (without leading spaces), nil if no cwd
function M._format_cwd_suffix(s, opts)
  if not s.cwd or s.cwd == "" then return nil end
  local display = s.cwd
  local home = vim.fn.expand("~")
  if display:sub(1, #home) == home then
    display = "~" .. display:sub(#home + 1)
  end
  local short = shorten_path(display)
  if s.git_type == "worktree" then
    local wt_icon = opts.icons.worktree or "\238\156\165"
    return wt_icon .. " " .. short
  end
  return short
end

function M._session_hl(s)
  if s.id == M._selected_session_id then
    return "ClaudeSessionSelected"
  elseif s.status == "working" then
    return "ClaudeSessionWorking"
  elseif s.status == "waiting" then
    return "ClaudeSessionWaiting"
  end
  return "ClaudeSessionDone"
end

local function setup_highlights()
  vim.api.nvim_set_hl(0, "ClaudeSessionWorking", { fg = "#a6e3a1", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionWaiting", { fg = "#f9e2af", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionDone", { fg = "#6c7086", default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionSelected", { fg = "#cdd6f4", bg = "#45475a", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionTitle", { fg = "#cba6f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionBorder", { fg = "#585b70", default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionHostHeader", { fg = "#89b4fa", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionMarker", { fg = "#cba6f7", bold = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionCwd", { fg = "#a6adc8", italic = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionRepo", { fg = "#a6e3a1", italic = true, default = true })
  vim.api.nvim_set_hl(0, "ClaudeSessionWorktree", { fg = "#fab387", italic = true, default = true })
end

function M.is_open()
  return M._sidebar_win ~= nil and vim.api.nvim_win_is_valid(M._sidebar_win)
end

function M.render()
  if not M._sidebar_buf or not vim.api.nvim_buf_is_valid(M._sidebar_buf) then return end

  local opts = config.options
  local lines = {}
  local highlights = {}
  -- Maps line index (0-based) -> session, for cursor-to-session lookup
  M._line_to_session = {}

  -- Compute effective sidebar width: max(min_width, 25% of screen, content_width)
  -- We'll determine content_width after building lines, then adjust
  local min_width = opts.sidebar_width or 30

  -- Header (placeholder width, will adjust separator after content is built)
  table.insert(lines, "  Claude Sessions")
  table.insert(highlights, { line = 0, hl = "ClaudeSessionTitle" })
  local separator_line_idx = 1
  table.insert(lines, "")  -- placeholder for separator
  table.insert(highlights, { line = 1, hl = "ClaudeSessionBorder" })
  table.insert(lines, "")

  if #session_mod.sessions == 0 then
    table.insert(lines, "  No sessions")
    table.insert(lines, "")
    table.insert(lines, "  Press 'n' to create one")
  else
    -- Group sessions: local first, then by host name
    local local_sessions = {}
    local host_groups = {} -- host_name -> { host, sessions }
    local host_order = {}  -- preserve insertion order

    for _, s in ipairs(session_mod.sessions) do
      if not s.host then
        table.insert(local_sessions, s)
      else
        local hname = s.host.name
        if not host_groups[hname] then
          host_groups[hname] = { host = s.host, sessions = {} }
          table.insert(host_order, hname)
        end
        table.insert(host_groups[hname].sessions, s)
      end
    end

    --- Render a list of sessions with inline cwd suffix.
    local function render_session_group(sessions)
      -- First pass: compute max session line width for alignment
      local session_lines = {}
      local max_line_width = 0
      for _, s in ipairs(sessions) do
        local idx = session_mod.get_index(s.id)
        local line = M._format_session_line(s, opts, idx)
        local width = vim.fn.strdisplaywidth(line)
        if width > max_line_width then max_line_width = width end
        table.insert(session_lines, { session = s, line = line, width = width })
      end

      -- Second pass: render with aligned separators
      for _, entry in ipairs(session_lines) do
        local s = entry.session
        local line = entry.line
        local line_idx = #lines
        local cwd_suffix = opts.group_by_cwd and M._format_cwd_suffix(s, opts) or nil
        if cwd_suffix then
          local sep = "\u{2502}"  -- │ thin vertical bar separator
          local pad = max_line_width - entry.width + 1
          line = line .. string.rep(" ", pad) .. sep .. " " .. cwd_suffix
        end
        table.insert(lines, line)
        M._line_to_session[line_idx] = s
        table.insert(highlights, { line = line_idx, hl = M._session_hl(s) })
        -- Apply cwd highlight to just the suffix portion (use byte offset)
        if cwd_suffix then
          -- Separator highlight
          local sep_byte = "\u{2502}"
          local sep_start = #line - #cwd_suffix - #sep_byte - 1
          table.insert(highlights, { line = line_idx, hl = "ClaudeSessionBorder", col_start = sep_start, col_end = sep_start + #sep_byte })
          -- Cwd path highlight
          local suffix_byte_start = #line - #cwd_suffix
          local hl = "ClaudeSessionCwd"
          if s.git_type == "worktree" then
            hl = "ClaudeSessionWorktree"
          elseif s.git_type == "repo" then
            hl = "ClaudeSessionRepo"
          end
          table.insert(highlights, { line = line_idx, hl = hl, col_start = suffix_byte_start, col_end = -1 })
        end
      end
    end

    -- Render local sessions
    if #local_sessions > 0 then
      local header_idx = #lines
      table.insert(lines, "  LOCAL")
      table.insert(highlights, { line = header_idx, hl = "ClaudeSessionHostHeader" })
      render_session_group(local_sessions)
    end

    -- Render each remote host group
    for _, hname in ipairs(host_order) do
      local group = host_groups[hname]
      -- Only add separator if there are already session lines above
      local has_content_above = #local_sessions > 0 or hname ~= host_order[1]
      if has_content_above then
        local sep_idx = #lines
        table.insert(lines, "")  -- separator placeholder, filled after width calc
        table.insert(highlights, { line = sep_idx, hl = "ClaudeSessionBorder" })
      end
      -- Host header
      local header_idx = #lines
      table.insert(lines, "  " .. hname:upper())
      table.insert(highlights, { line = header_idx, hl = "ClaudeSessionHostHeader" })
      render_session_group(group.sessions)
    end
  end

  -- Compute dynamic width: fit content, never below min_width
  local content_width = 0
  for _, line in ipairs(lines) do
    local w = vim.fn.strdisplaywidth(line)
    if w > content_width then content_width = w end
  end
  local effective_width = math.max(min_width, content_width + 2)

  -- Fill separator placeholders (empty lines that have ClaudeSessionBorder highlight)
  local sep_str = "  " .. string.rep("\u{2500}", effective_width - 4)
  for _, hl in ipairs(highlights) do
    if hl.hl == "ClaudeSessionBorder" and lines[hl.line + 1] == "" then
      lines[hl.line + 1] = sep_str
    end
  end

  -- Write lines
  vim.api.nvim_set_option_value("modifiable", true, { buf = M._sidebar_buf })
  vim.api.nvim_buf_set_lines(M._sidebar_buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = M._sidebar_buf })

  -- Resize sidebar window to fit content
  if M._sidebar_win and vim.api.nvim_win_is_valid(M._sidebar_win) then
    vim.api.nvim_win_set_width(M._sidebar_win, effective_width)
  end

  -- Apply highlights
  vim.api.nvim_buf_clear_namespace(M._sidebar_buf, ns, 0, -1)
  for _, hl in ipairs(highlights) do
    local col_start = hl.col_start or 0
    local col_end = hl.col_end or -1
    pcall(vim.api.nvim_buf_add_highlight, M._sidebar_buf, ns, hl.hl, hl.line, col_start, col_end)
  end

  -- Apply selection marker on selected session's line
  local marker = config.options.selection_marker
  if marker and marker ~= "" then
    for line_idx, s in pairs(M._line_to_session) do
      if s.id == M._selected_session_id then
        pcall(vim.api.nvim_buf_set_extmark, M._sidebar_buf, ns, line_idx, 0, {
          virt_text = { { marker, "ClaudeSessionMarker" } },
          virt_text_pos = "overlay",
        })
        break
      end
    end
  end
end

local function get_session_at_cursor()
  if not M.is_open() then return nil end
  local cursor = vim.api.nvim_win_get_cursor(M._sidebar_win)
  local row = cursor[1] - 1 -- convert to 0-indexed
  return M._line_to_session and M._line_to_session[row] or nil
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
    -- Force a resize event so remote terminals (zellij) redraw correctly
    vim.cmd("startinsert")
    vim.schedule(function()
      vim.api.nvim_exec_autocmds("VimResized", {})
    end)
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

  -- Override j/k to skip non-session lines
  vim.keymap.set("n", "j", function()
    local cursor = vim.api.nvim_win_get_cursor(M._sidebar_win)
    local row = cursor[1] -- 1-indexed
    local total = vim.api.nvim_buf_line_count(M._sidebar_buf)
    for r = row + 1, total do
      if M._line_to_session[r - 1] then
        vim.api.nvim_win_set_cursor(M._sidebar_win, { r, 0 })
        return
      end
    end
  end, map_opts)

  vim.keymap.set("n", "k", function()
    local cursor = vim.api.nvim_win_get_cursor(M._sidebar_win)
    local row = cursor[1]
    for r = row - 1, 1, -1 do
      if M._line_to_session[r - 1] then
        vim.api.nvim_win_set_cursor(M._sidebar_win, { r, 0 })
        return
      end
    end
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

  -- Create sidebar buffer, cleaning up any stale same-named buffers first
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name:match("Claude Sessions") then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
  end
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
