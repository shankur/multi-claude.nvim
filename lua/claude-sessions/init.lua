local config = require("claude-sessions.config")
local session = require("claude-sessions.session")
local sidebar = require("claude-sessions.sidebar")

local M = {}

local marker_ns = vim.api.nvim_create_namespace("claude_picker_marker")

--- Apply a selection marker to the current cursor line in a floating picker.
--- Updates automatically as the cursor moves via CursorMoved autocmd.
---@param buf number
---@param win number
---@param is_valid_row fun(row: number): boolean  returns true if row should show marker
local function setup_picker_marker(buf, win, is_valid_row)
  local marker = config.options.selection_marker
  if not marker or marker == "" then return end

  local function update(row)
    vim.api.nvim_buf_clear_namespace(buf, marker_ns, 0, -1)
    if is_valid_row(row) then
      pcall(vim.api.nvim_buf_set_extmark, buf, marker_ns, row - 1, 0, {
        virt_text = { { marker, "ClaudeSessionMarker" } },
        virt_text_pos = "overlay",
      })
    end
  end

  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if vim.api.nvim_win_is_valid(win) then
        update(vim.api.nvim_win_get_cursor(win)[1])
      end
    end,
  })

  update(vim.api.nvim_win_get_cursor(win)[1])
end

function M.setup(opts)
  config.setup(opts)
end

--- Prompt for a working directory using a fuzzy finder picker.
--- Uses Snacks.picker if available, falls back to vim.ui.select.
---@param host table|nil
---@param callback fun(cwd: string|nil)
function M._pick_cwd(host, callback)
  local opts = config.options
  local default_cwd = (host and host.cwd) or opts.default_cwd or vim.fn.getcwd()
  local paths = opts.cwd_paths or {}

  -- Try snacks.picker for fuzzy directory finding
  local has_snacks, snacks = pcall(require, "snacks")
  if has_snacks and snacks.picker then
    -- Build initial items from configured paths
    local items = {}
    for i, p in ipairs(paths) do
      table.insert(items, {
        text = vim.fn.expand(p),
        idx = i,
      })
    end

    local completed = false
    snacks.picker({
      title = "Working Directory",
      items = #items > 0 and items or nil,
      finder = #items == 0 and function(_, ctx)
        return require("snacks.picker.source.proc").proc(ctx:opts({
          cmd = "fd",
          args = { "--type", "d", "--max-depth", "4", "--color", "never", "-E", ".git", ".", vim.fn.expand("~") },
        }), ctx)
      end or nil,
      layout = { preset = "select" },
      format = function(item)
        local path = item.text
        local home = vim.fn.expand("~")
        if path:sub(1, #home) == home then
          path = "~" .. path:sub(#home + 1)
        end
        return { { path } }
      end,
      actions = {
        confirm = function(picker, item)
          if completed then return end
          completed = true
          picker:close()
          vim.schedule(function()
            if item then
              local path = item.text
              local home = vim.fn.expand("~")
              if path:sub(1, #home) == home then
                path = "~" .. path:sub(#home + 1)
              end
              callback(path)
            end
          end)
        end,
      },
      on_close = function()
        if completed then return end
        completed = true
      end,
    })
    return
  end

  -- Fallback: vim.ui.select with configured paths
  local items = {}
  local seen = {}
  local expanded_default = vim.fn.expand(default_cwd)
  table.insert(items, { path = default_cwd, display = default_cwd .. " (default)" })
  seen[expanded_default] = true

  for _, p in ipairs(paths) do
    local expanded = vim.fn.expand(p)
    if not seen[expanded] then
      seen[expanded] = true
      table.insert(items, { path = p, display = p })
    end
  end

  if #items == 1 and #paths == 0 then
    callback(default_cwd)
    return
  end

  table.insert(items, { path = nil, display = "Other..." })

  vim.ui.select(items, {
    prompt = "Working directory:",
    format_item = function(item)
      return item.display
    end,
  }, function(choice)
    if not choice then return end
    if choice.path then
      callback(choice.path)
    else
      vim.ui.input({
        prompt = "Path: ",
        default = default_cwd,
        completion = "dir",
      }, function(input)
        if not input or input == "" then return end
        callback(input)
      end)
    end
  end)
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
  local hosts = config.options.hosts or {}

  if #hosts == 0 then
    -- No remote hosts configured: prompt for cwd then spawn local
    local function do_spawn(session_name)
      M._pick_cwd(nil, function(cwd)
        if not cwd then return end
        M._spawn_and_show(session_name, nil, cwd)
      end)
    end

    if name then
      do_spawn(name)
    else
      vim.ui.input({
        prompt = "Session name: ",
        default = "session-" .. session._next_id,
      }, function(input_name)
        if not input_name or input_name == "" then return end
        do_spawn(input_name)
      end)
    end
    return
  end

  -- Build items: local + each configured host
  local items = { { name = "local", addr = "", host = nil } }
  for _, host in ipairs(hosts) do
    table.insert(items, { name = host.name, addr = host.addr, host = host })
  end

  -- Calculate column widths
  local max_name = 4
  for _, item in ipairs(items) do
    max_name = math.max(max_name, #item.name)
  end
  local max_addr = 7
  for _, item in ipairs(items) do
    max_addr = math.max(max_addr, #item.addr)
  end

  local width = max_name + max_addr + 10
  local lines = {}
  local highlights = {}

  table.insert(lines, "  New Claude Session")
  table.insert(highlights, { line = 0, hl = "ClaudeSessionTitle" })
  table.insert(lines, "  " .. string.rep("\u{2500}", width - 4))
  table.insert(highlights, { line = 1, hl = "ClaudeSessionBorder" })

  local header = string.format("  %-" .. max_name .. "s   %s", "Host", "Address")
  table.insert(lines, header)
  table.insert(highlights, { line = 2, hl = "ClaudeSessionBorder" })

  local row_to_item = {}
  for _, item in ipairs(items) do
    local line_idx = #lines
    local line = string.format("  %-" .. max_name .. "s   %s", item.name:upper(), item.addr)
    table.insert(lines, line)
    row_to_item[line_idx] = item
    table.insert(highlights, { line = line_idx, hl = "ClaudeSessionWaiting" })
  end

  table.insert(lines, "")
  table.insert(lines, "  Select host and press <CR>")
  table.insert(highlights, { line = #lines - 1, hl = "ClaudeSessionDone" })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local win_height = #lines
  local win_width = width
  local row = math.floor((vim.o.lines - win_height) / 2)
  local col = math.floor((vim.o.columns - win_width) / 2)

  local ns = vim.api.nvim_create_namespace("claude_new_host")
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = win_width,
    height = win_height,
    style = "minimal",
    border = "rounded",
  })

  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl, hl.line, 0, -1)
  end

  vim.api.nvim_set_option_value("cursorline", true, { win = win })
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  setup_picker_marker(buf, win, function(row) return row_to_item[row - 1] ~= nil end)

  local function close_win()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function on_select()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local item = row_to_item[cursor[1] - 1]
    if not item then return end

    close_win()

    local function spawn_with_cwd(session_name, host)
      M._pick_cwd(host, function(cwd)
        if not cwd then return end
        M._spawn_and_show(session_name, host, cwd)
      end)
    end

    if name then
      spawn_with_cwd(name, item.host)
    else
      vim.ui.input({
        prompt = "Session name: ",
        default = "session-" .. session._next_id,
      }, function(input_name)
        if not input_name or input_name == "" then return end
        spawn_with_cwd(input_name, item.host)
      end)
    end
  end

  local map_opts = { buffer = buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", on_select, map_opts)
  vim.keymap.set("n", "q", close_win, map_opts)
  vim.keymap.set("n", "<Esc>", close_win, map_opts)

  vim.keymap.set("n", "j", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    for r = cursor[1] + 1, #lines do
      if row_to_item[r - 1] then
        vim.api.nvim_win_set_cursor(win, { r, 0 })
        return
      end
    end
  end, map_opts)

  vim.keymap.set("n", "k", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    for r = cursor[1] - 1, 1, -1 do
      if row_to_item[r - 1] then
        vim.api.nvim_win_set_cursor(win, { r, 0 })
        return
      end
    end
  end, map_opts)
end

function M._spawn_and_show(name, host, cwd)
  vim.schedule(function()
    local ok, s = pcall(session.spawn, name, host, cwd)
    if not ok or not s then return end
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
  end)
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

function M.list_remote_sessions(host_name)
  local remote = require("claude-sessions.remote")
  local host = remote.get_host(host_name)
  if not host then
    vim.notify("Unknown host: " .. host_name, vim.log.levels.ERROR)
    return
  end

  local sessions = remote.list_sessions(host)
  if #sessions == 0 then
    vim.notify("No zellij sessions on " .. host_name, vim.log.levels.INFO)
    return
  end

  vim.ui.select(sessions, {
    prompt = "Attach to session on " .. host_name .. ":",
  }, function(choice)
    if not choice then return end

    -- Check if already attached to this session
    for _, s in ipairs(session.sessions) do
      if s.host and s.host.name == host_name and s.name == choice then
        vim.notify("Already attached to " .. choice, vim.log.levels.WARN)
        return
      end
    end

    local s = session.attach(choice, host)
    sidebar._selected_session_id = s.id

    if sidebar.is_open() then
      sidebar.render()
      local win = sidebar._main_win
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_buf(win, s.bufnr)
        vim.api.nvim_set_current_win(win)
        vim.cmd("startinsert")
      end
    elseif config.options.auto_open or #session.sessions == 1 then
      sidebar.open()
      local win = sidebar._main_win
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_set_buf(win, s.bufnr)
        vim.api.nvim_set_current_win(win)
        vim.cmd("startinsert")
      end
    end
  end)
end

function M.clean_remote_sessions()
  local hosts = config.options.hosts or {}
  local remote = require("claude-sessions.remote")
  local items = {}

  -- Check local sessions
  local local_count = #remote.list_local_sessions()
  if local_count > 0 then
    table.insert(items, { host = nil, name = "local", addr = "localhost", count = local_count })
  end

  -- Check remote hosts
  for _, host in ipairs(hosts) do
    local count = #remote.list_sessions(host)
    if count > 0 then
      table.insert(items, { host = host, name = host.name, addr = host.addr, count = count })
    end
  end

  if #items == 0 then
    print("[claude] No active sessions on any host")
    return
  end

  -- Calculate column widths
  local max_name = 4 -- "Host"
  local max_addr = 7 -- "Address"
  for _, item in ipairs(items) do
    max_name = math.max(max_name, #item.name)
    max_addr = math.max(max_addr, #item.addr)
  end

  -- Build floating window content
  local width = max_name + max_addr + 18
  local lines = {}
  local highlights = {}

  table.insert(lines, "  Clean Sessions")
  table.insert(highlights, { line = 0, hl = "ClaudeSessionTitle" })
  table.insert(lines, "  " .. string.rep("\u{2500}", width - 4))
  table.insert(highlights, { line = 1, hl = "ClaudeSessionBorder" })

  -- Header row
  local header = string.format("  %-" .. max_name .. "s   %-" .. max_addr .. "s   %s", "Host", "Address", "Count")
  table.insert(lines, header)
  table.insert(highlights, { line = 2, hl = "ClaudeSessionBorder" })

  -- Data rows
  local row_to_item = {}
  for _, item in ipairs(items) do
    local line_idx = #lines
    local line = string.format("  %-" .. max_name .. "s   %-" .. max_addr .. "s     %d", item.name:upper(), item.addr, item.count)
    table.insert(lines, line)
    row_to_item[line_idx] = item
    table.insert(highlights, { line = line_idx, hl = "ClaudeSessionWaiting" })
  end

  table.insert(lines, "")
  table.insert(lines, "  Select host and press <CR>")
  table.insert(highlights, { line = #lines - 1, hl = "ClaudeSessionDone" })

  -- Create floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local win_height = #lines
  local win_width = width
  local row = math.floor((vim.o.lines - win_height) / 2)
  local col = math.floor((vim.o.columns - win_width) / 2)

  local ns = vim.api.nvim_create_namespace("claude_clean")
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row,
    col = col,
    width = win_width,
    height = win_height,
    style = "minimal",
    border = "rounded",
  })

  -- Apply highlights
  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl, hl.line, 0, -1)
  end

  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  -- Place cursor on first data row
  vim.api.nvim_win_set_cursor(win, { 4, 0 })
  setup_picker_marker(buf, win, function(row) return row_to_item[row - 1] ~= nil end)

  -- Keymaps
  local function close_win()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function do_clean()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local item = row_to_item[cursor[1] - 1]
    if not item then return end

    close_win()

    -- Close any attached sessions for this host
    local to_close = {}
    for _, s in ipairs(session.sessions) do
      if item.host then
        if s.host and s.host.name == item.host.name then
          table.insert(to_close, s.id)
        end
      else
        if not s.host then
          table.insert(to_close, s.id)
        end
      end
    end
    for _, id in ipairs(to_close) do
      session.close(id)
    end

    if item.host then
      remote.kill_all_sessions(item.host)
    else
      remote.kill_all_local_sessions()
    end

    if sidebar.is_open() then
      sidebar.render()
    end
  end

  local map_opts = { buffer = buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", do_clean, map_opts)
  vim.keymap.set("n", "q", close_win, map_opts)
  vim.keymap.set("n", "<Esc>", close_win, map_opts)

  -- Keep cursor on data rows only
  vim.keymap.set("n", "j", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local r = cursor[1]
    for next_r = r + 1, #lines do
      if row_to_item[next_r - 1] then
        vim.api.nvim_win_set_cursor(win, { next_r, 0 })
        return
      end
    end
  end, map_opts)

  vim.keymap.set("n", "k", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local r = cursor[1]
    for next_r = r - 1, 1, -1 do
      if row_to_item[next_r - 1] then
        vim.api.nvim_win_set_cursor(win, { next_r, 0 })
        return
      end
    end
  end, map_opts)
end

function M.discover()
  local hosts = config.options.hosts or {}
  local remote = require("claude-sessions.remote")

  -- Open sidebar
  if not sidebar.is_open() then
    sidebar.open()
  end

  local found = 0

  -- Discover local zellij sessions
  local local_sessions = remote.list_local_sessions()
  for _, name in ipairs(local_sessions) do
    local already = false
    for _, s in ipairs(session.sessions) do
      if not s.host and s.name == name then
        already = true
        break
      end
    end

    if not already then
      local s = session.attach(name, nil)
      if found == 0 then
        sidebar._selected_session_id = s.id
        local win = sidebar._main_win
        if win and vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_set_buf(win, s.bufnr)
        end
      end
      found = found + 1
    end
  end

  -- Discover remote sessions across all hosts
  for _, host in ipairs(hosts) do
    local remote_sessions = remote.list_sessions(host)
    for _, name in ipairs(remote_sessions) do
      local already = false
      for _, s in ipairs(session.sessions) do
        if s.host and s.host.name == host.name and s.name == name then
          already = true
          break
        end
      end

      if not already then
        local s = session.attach(name, host)
        if found == 0 then
          sidebar._selected_session_id = s.id
          local win = sidebar._main_win
          if win and vim.api.nvim_win_is_valid(win) then
            vim.api.nvim_win_set_buf(win, s.bufnr)
          end
        end
        found = found + 1
      end
    end
  end

  sidebar.render()
end

--- Jump to a session by 1-based index (across all sessions in sidebar order).
function M.jump_to_index(n)
  if #session.sessions == 0 then return end
  local s = session.sessions[n]
  if not s then return end
  sidebar._selected_session_id = s.id
  local win = sidebar._main_win
  if sidebar.is_open() then
    sidebar.render()
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_buf(win, s.bufnr)
      vim.api.nvim_set_current_win(win)
      vim.cmd("startinsert")
    end
  elseif config.options.auto_open then
    sidebar.open()
    win = sidebar._main_win
    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_buf(win, s.bufnr)
      vim.api.nvim_set_current_win(win)
      vim.cmd("startinsert")
    end
  end
end

--- Show a floating session picker grouped by host.
function M.jump_picker()
  if #session.sessions == 0 then
    print("[claude] No active sessions")
    return
  end

  local opts = config.options
  local lines = {}
  local highlights = {}
  local row_to_session = {}

  -- Group sessions like sidebar
  local local_sessions = {}
  local host_groups = {}
  local host_order = {}
  for _, s in ipairs(session.sessions) do
    if not s.host then
      table.insert(local_sessions, s)
    else
      local hname = s.host.name
      if not host_groups[hname] then
        host_groups[hname] = { sessions = {} }
        table.insert(host_order, hname)
      end
      table.insert(host_groups[hname].sessions, s)
    end
  end

  local function add_session_line(s, idx)
    local icon = opts.icons[s.status] or "?"
    local host_label = s.host and s.host.name:upper() or "LOCAL"
    local line = string.format("  %s %-20s  %-8s  [%s]", icon, s.name, host_label, s.status)
    local line_idx = #lines
    table.insert(lines, line)
    row_to_session[line_idx] = s
    local hl = sidebar._session_hl(s)
    table.insert(highlights, { line = line_idx, hl = hl })
  end

  -- Header
  table.insert(lines, "  Jump to Session")
  table.insert(highlights, { line = 0, hl = "ClaudeSessionTitle" })
  table.insert(lines, "  " .. string.rep("\u{2500}", 46))
  table.insert(highlights, { line = 1, hl = "ClaudeSessionBorder" })

  -- Local sessions
  if #local_sessions > 0 then
    local h_idx = #lines
    table.insert(lines, "  LOCAL")
    table.insert(highlights, { line = h_idx, hl = "ClaudeSessionHostHeader" })
    for i, s in ipairs(local_sessions) do
      add_session_line(s, i)
    end
  end

  -- Remote sessions
  local first_remote = true
  for _, hname in ipairs(host_order) do
    if not first_remote or #local_sessions > 0 then
      local sep_idx = #lines
      table.insert(lines, "  " .. string.rep("\u{2500}", 46))
      table.insert(highlights, { line = sep_idx, hl = "ClaudeSessionBorder" })
    end
    first_remote = false
    local h_idx = #lines
    table.insert(lines, "  " .. hname:upper())
    table.insert(highlights, { line = h_idx, hl = "ClaudeSessionHostHeader" })
    for i, s in ipairs(host_groups[hname].sessions) do
      add_session_line(s, i)
    end
  end

  table.insert(lines, "")
  table.insert(lines, "  <CR> jump  \u{2502}  q / <Esc> close")
  table.insert(highlights, { line = #lines - 1, hl = "ClaudeSessionDone" })

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_option_value("bufhidden", "wipe", { buf = buf })
  vim.api.nvim_set_option_value("modifiable", true, { buf = buf })
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_set_option_value("modifiable", false, { buf = buf })

  local win_width = 52
  local win_height = #lines
  local row = math.floor((vim.o.lines - win_height) / 2)
  local col = math.floor((vim.o.columns - win_width) / 2)

  local ns = vim.api.nvim_create_namespace("claude_jump")
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = row, col = col,
    width = win_width, height = win_height,
    style = "minimal", border = "rounded",
  })

  for _, hl in ipairs(highlights) do
    pcall(vim.api.nvim_buf_add_highlight, buf, ns, hl.hl, hl.line, 0, -1)
  end

  vim.api.nvim_set_option_value("cursorline", true, { win = win })

  -- Place cursor on first session line
  for r = 1, #lines do
    if row_to_session[r - 1] then
      vim.api.nvim_win_set_cursor(win, { r, 0 })
      break
    end
  end
  setup_picker_marker(buf, win, function(row) return row_to_session[row - 1] ~= nil end)

  local function close_win()
    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end
  end

  local function do_jump()
    local cursor = vim.api.nvim_win_get_cursor(win)
    local s = row_to_session[cursor[1] - 1]
    if not s then return end
    close_win()
    sidebar._selected_session_id = s.id
    if not sidebar.is_open() then
      sidebar.open()
    else
      sidebar.render()
    end
    local main_win = sidebar._main_win
    if main_win and vim.api.nvim_win_is_valid(main_win) then
      vim.api.nvim_win_set_buf(main_win, s.bufnr)
      vim.api.nvim_set_current_win(main_win)
      vim.cmd("startinsert")
    end
  end

  local map_opts = { buffer = buf, noremap = true, silent = true, nowait = true }
  vim.keymap.set("n", "<CR>", do_jump, map_opts)
  vim.keymap.set("n", "q", close_win, map_opts)
  vim.keymap.set("n", "<Esc>", close_win, map_opts)

  vim.keymap.set("n", "j", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    for r = cursor[1] + 1, #lines do
      if row_to_session[r - 1] then
        vim.api.nvim_win_set_cursor(win, { r, 0 })
        return
      end
    end
  end, map_opts)

  vim.keymap.set("n", "k", function()
    local cursor = vim.api.nvim_win_get_cursor(win)
    for r = cursor[1] - 1, 1, -1 do
      if row_to_session[r - 1] then
        vim.api.nvim_win_set_cursor(win, { r, 0 })
        return
      end
    end
  end, map_opts)
end

return M
