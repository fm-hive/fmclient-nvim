local M = {}

local protocols = require('fmclient.protocols')

local START_DIR = vim.fn.getcwd()

local state = {
  menu_buf = nil, menu_win = nil, menu_meta = {},
  work_buf = nil, work_win = nil, work_meta = {}, work_view = nil,
  history = {}, screen = 'menu', echo = nil, echo_msgs = {}, echo_last_read = 0,
  netmail_folder = nil, netmail_msgs = {}, menu_echoes = {}, menu_folders = {}, menu_blogs = {}, current_blog = nil, msg_wins = {}, picker_wins = {}, current_msg = nil, current_echo = nil,
  compose_seq = 0, closing = false, cmd = nil, data = nil, address = nil,
  identity = nil, checked = false, network_name = 'FM',
  show_protocols = vim.g.fmclient_show_protocols == true,
  echo_all_msgs = {}, current_protocol_messages = {},
  protocol_actions = {},
}

local function split_cmd(cmd) return vim.split(cmd, '%s+', { trimempty = true }) end

local function app_title()
  local name = state.network_name or 'FM'
  if state.address and state.address ~= '' then return name .. ' · ' .. state.address end
  return name
end

local function readable(path) return vim.fn.filereadable(path) == 1 end
local function executable(path) return vim.fn.executable(path) == 1 end
local function valid_win(win) return win ~= nil and vim.api.nvim_win_is_valid(win) end
local function valid_buf(buf) return buf ~= nil and vim.api.nvim_buf_is_valid(buf) end

local function normalize_dir(dir)
  if type(dir) ~= 'string' or dir == '' then return nil end
  dir = vim.fn.expand(dir)
  if dir == '' then return nil end
  dir = vim.fs.normalize(vim.fn.fnamemodify(dir, ':p'))
  if vim.fn.isdirectory(dir) ~= 1 then return nil end
  return dir
end

local function launch_dir()
  return normalize_dir(vim.env.PWD) or START_DIR
end

local function candidate_dirs()
  local dirs, seen = {}, {}
  local function add(dir)
    dir = normalize_dir(dir)
    if dir and not seen[dir] then
      seen[dir] = true
      table.insert(dirs, dir)
    end
  end
  add(vim.env.PWD)
  add(START_DIR)
  local buf = vim.api.nvim_buf_get_name(0)
  if buf ~= '' then add(vim.fn.fnamemodify(buf, ':p:h')) end
  add(vim.fn.getcwd())
  return dirs
end

local function local_command()
  local exe = vim.fn.has('win32') == 1 and 'fmclient.exe' or 'fmclient'
  for _, dir in ipairs(candidate_dirs()) do
    local path = dir .. '/' .. exe
    if executable(path) then return path end
  end
  return nil
end

local function detect_command()
  local configured = vim.g.fmclient_cmd
  if type(configured) == 'string' and configured ~= '' then return configured end
  local local_bin = local_command()
  if local_bin then return local_bin end
  if vim.fn.exepath('fmclient') ~= '' then return 'fmclient' end
  return nil
end

local function configured_data()
  local configured = vim.g.fmclient_data
  if type(configured) ~= 'string' or configured == '' then return nil end
  local path = vim.fn.expand(configured)
  if path == '' then return nil end
  local absolute = path:sub(1, 1) == '/' or path:sub(1, 1) == '\\' or path:match('^%a:[/\\]') ~= nil
  if not absolute then path = launch_dir() .. '/' .. path end
  return vim.fs.normalize(path)
end

local function detect_data()
  local configured = configured_data()
  if configured then return configured end
  local dirs = candidate_dirs()
  for _, dir in ipairs(dirs) do
    for _, data_dir in ipairs({ dir .. '/data', dir }) do
      if readable(data_dir .. '/fmclient.db') then return data_dir end
    end
  end
  return (dirs[1] or START_DIR) .. '/data'
end

local function find_local_client()
  local exe = vim.fn.has('win32') == 1 and 'fmclient.exe' or 'fmclient'
  for _, dir in ipairs(candidate_dirs()) do
    local cmd = dir .. '/' .. exe
    if executable(cmd) then
      for _, data_dir in ipairs({ dir .. '/data', dir }) do
        if readable(data_dir .. '/fmclient.db') then return cmd, data_dir end
      end
    end
  end
end

local function command()
  return state.cmd or detect_command() or 'fmclient', state.data or detect_data()
end

local function run(args, input)
  local cmd, data = command()
  local argv = split_cmd(cmd)
  vim.list_extend(argv, args)
  table.insert(argv, '--data')
  table.insert(argv, data)
  local out = vim.fn.systemlist(argv, input or '')
  if vim.v.shell_error ~= 0 then error(table.concat(out, '\n')) end
  return out
end

local function run_json(args)
  local text = table.concat(run(args), '\n')
  if text == '' then return nil end
  local ok, value = pcall(vim.json.decode, text)
  if not ok then error(value) end
  if value == vim.NIL then return nil end
  return value
end

local function read_account(cmd, data)
  local argv = split_cmd(cmd)
  vim.list_extend(argv, { 'policy', 'show', '--json', '--data', data })
  local out = vim.fn.systemlist(argv)
  if vim.v.shell_error ~= 0 then return nil end
  local ok, account = pcall(vim.json.decode, table.concat(out, '\n'))
  if not ok or type(account) ~= 'table' then return nil end
  local address = account.address or account.Address
  if type(address) ~= 'string' or address == '' then return nil end
  account.address = address
  return account
end

function M.detect(force)
  if state.checked and not force then
    if state.cmd then return { cmd = state.cmd, data = state.data, address = state.address } end
    return nil
  end
  state.checked = true
  local cmd, data
  if vim.g.fmclient_cmd or vim.g.fmclient_data then
    cmd = detect_command()
    if not cmd then return nil end
    data = detect_data()
  else
    cmd, data = find_local_client()
    if not cmd or not data then
      cmd = detect_command()
      if not cmd then return nil end
      data = detect_data()
    end
  end
  if not readable(data .. '/fmclient.db') then return nil end
  local account = read_account(cmd, data)
  if not account then return nil end
  state.cmd, state.data, state.address = cmd, data, account.address
  local ok, identity = pcall(run_json, { 'identity', '--json' })
  if ok and type(identity) == 'table' then
    state.identity = identity
    if type(identity.network_name) == 'string' and identity.network_name ~= '' then
      state.network_name = identity.network_name
    end
  end
  return { cmd = cmd, data = data, address = account.address }
end

local function ensure_ready()
  if state.cmd then return true end
  return M.detect(true) ~= nil
end

local function ensure_buf(name, filetype)
  local nr = vim.fn.bufnr(name)
  local buf
  if nr ~= -1 and vim.api.nvim_buf_is_valid(nr) then buf = nr
  else
    buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, name)
  end
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  if filetype then
    vim.bo[buf].filetype = filetype
    -- Scheme buffers are not always detected by filetype.vim; make the
    -- markdown viewer explicitly use markdown syntax (and colors).
    if filetype == 'markdown' then vim.bo[buf].syntax = 'markdown' end
  end
  return buf
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

function M.fmt_date(ts)
  local n = tonumber(ts)
  if not n or n <= 0 then return '?' end
  if n > 1e12 then n = math.floor(n / 1000) end
  local pattern = vim.g.fmclient_date_format
  if type(pattern) ~= 'string' or pattern == '' then pattern = '%Y-%m-%d %H:%M' end
  local ok, value = pcall(os.date, pattern, math.floor(n))
  return ok and value or os.date('%Y-%m-%d %H:%M', math.floor(n))
end

local function parse_data(msg)
  return protocols.decode(msg)
end

local function filter_protocols(messages)
  if state.show_protocols then return messages or {} end
  local out = {}
  for _, msg in ipairs(messages or {}) do
    if not protocols.is_protocol(msg) then out[#out + 1] = msg end
  end
  return out
end

local function json_pretty(value, indent)
  indent = indent or ''
  if type(value) ~= 'table' then return vim.json.encode(value) end
  local is_list = true
  for key in pairs(value) do
    if type(key) ~= 'number' then is_list = false; break end
  end
  if is_list then
    if #value == 0 then return '[]' end
    local parts = {}
    for _, item in ipairs(value) do
      table.insert(parts, indent .. '  ' .. json_pretty(item, indent .. '  '))
    end
    return '[\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. ']'
  end
  local keys = {}
  for key in pairs(value) do table.insert(keys, key) end
  table.sort(keys)
  local parts = {}
  for _, key in ipairs(keys) do
    table.insert(parts, indent .. '  ' .. vim.json.encode(key) .. ': ' .. json_pretty(value[key], indent .. '  '))
  end
  return '{\n' .. table.concat(parts, ',\n') .. '\n' .. indent .. '}'
end

local function sort_messages(list)
  table.sort(list or {}, function(a, b)
    if (a.timestamp or 0) == (b.timestamp or 0) then return (a.message_id or '') < (b.message_id or '') end
    return (a.timestamp or 0) < (b.timestamp or 0)
  end)
  return list or {}
end

local function scratch(name, filetype)
  local buf = ensure_buf(name, filetype)
  set_lines(buf, {})
  return buf
end

local function close_message_windows()
  for _, key in ipairs({ 'attached', 'footer', 'header' }) do
    local win = state.msg_wins[key]
    if valid_win(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  state.msg_wins = {}
  for _, win in ipairs(state.picker_wins or {}) do
    if valid_win(win) then pcall(vim.api.nvim_win_close, win, true) end
  end
  state.picker_wins = {}
  state.current_msg = nil
  if valid_win(state.work_win) and valid_buf(state.work_buf) then
    vim.api.nvim_win_set_buf(state.work_win, state.work_buf)
  end
end

local function ensure_layout()
  state.menu_buf = ensure_buf('fmclient://sidebar', 'fmclient')
  state.work_buf = ensure_buf('fmclient://work', 'fmclient')
  if not valid_win(state.menu_win) and not valid_win(state.work_win) then
    local origin = vim.api.nvim_get_current_win()
    local origin_buf = vim.api.nvim_win_get_buf(origin)
    local reuse = #vim.api.nvim_list_wins() == 1 and vim.api.nvim_buf_get_name(origin_buf) == '' and not vim.bo[origin_buf].modified
    state.menu_win = vim.api.nvim_open_win(state.menu_buf, true, { split = 'left', win = origin })
    if reuse then
      state.work_win = origin
      vim.api.nvim_win_set_buf(origin, state.work_buf)
    else
      state.work_win = vim.api.nvim_open_win(state.work_buf, false, { split = 'right', win = origin })
    end
  elseif not valid_win(state.menu_win) then
    state.menu_win = vim.api.nvim_open_win(state.menu_buf, true, { split = 'left', win = state.work_win })
  elseif not valid_win(state.work_win) then
    state.work_win = vim.api.nvim_open_win(state.work_buf, false, { split = 'right', win = state.menu_win })
  end
  vim.wo[state.menu_win].number = false
  vim.wo[state.menu_win].relativenumber = false
  vim.wo[state.menu_win].winfixwidth = true
  vim.api.nvim_win_set_width(state.menu_win, math.min(42, math.max(24, math.floor(vim.o.columns / 3))))
  vim.wo[state.work_win].number = false
  vim.wo[state.work_win].relativenumber = false
  vim.wo[state.work_win].wrap = true
  vim.api.nvim_set_current_win(state.menu_win)
end

local function render_work(lines, meta, view)
  close_message_windows()
  if not valid_win(state.work_win) then ensure_layout() end
  set_lines(state.work_buf, lines)
  state.work_meta, state.work_view = meta or {}, view
  vim.api.nvim_win_set_buf(state.work_win, state.work_buf)
  vim.api.nvim_set_current_win(state.work_win)
  vim.keymap.set('n', '<CR>', function() M.open_work_at_cursor() end, { buffer = state.work_buf, desc = 'Open' })
  vim.keymap.set('n', 'q', function() M.back() end, { buffer = state.work_buf, desc = 'Back' })
  vim.keymap.set('n', 'u', function() M.back() end, { buffer = state.work_buf, desc = 'Back' })
  vim.keymap.set('n', 'P', function() M.toggle_protocols() end, { buffer = state.work_buf, desc = 'Toggle protocol messages' })
  local screen = view and view.screen or ''
  if screen == 'echoes' or screen == 'echo' then
    vim.keymap.set('n', 'l', function() M.open_list() end, { buffer = state.work_buf, desc = 'Message list' })
    vim.keymap.set('n', 'e', function() M.compose('echo', state.echo or '') end, { buffer = state.work_buf, desc = 'New echo message' })
    vim.keymap.set('n', 'c', function() M.create_echo() end, { buffer = state.work_buf, desc = 'Create echo' })
    vim.keymap.set('n', 'b', function() M.create_blog() end, { buffer = state.work_buf, desc = 'Create blog' })
    vim.keymap.set('n', 's', function() M.subscribe_selected() end, { buffer = state.work_buf, desc = 'Subscribe/unsubscribe' })
  elseif screen == 'netmail' then
    vim.keymap.set('n', 'l', function() M.open_list() end, { buffer = state.work_buf, desc = 'Message list' })
    vim.keymap.set('n', 'e', function() M.compose('netmail', '') end, { buffer = state.work_buf, desc = 'New netmail' })
    vim.keymap.set('n', 'n', function() M.create_netmail_folder() end, { buffer = state.work_buf, desc = 'New netmail folder' })
    vim.keymap.set('n', 'd', function() M.delete_netmail_folder() end, { buffer = state.work_buf, desc = 'Delete netmail folder' })
  elseif screen == 'settings' then
    vim.keymap.set('n', 'e', function() M.export_settings() end, { buffer = state.work_buf, desc = 'Export settings' })
    vim.keymap.set('n', 'i', function() M.import_settings() end, { buffer = state.work_buf, desc = 'Import settings' })
    vim.keymap.set('n', 'p', function() M.show_policy() end, { buffer = state.work_buf, desc = 'Show policy' })
    vim.keymap.set('n', 'a', function() M.open_screen('admin') end, { buffer = state.work_buf, desc = 'Admin' })
  elseif screen == 'admin' then
    vim.keymap.set('n', 'i', function() M.show_invite() end, { buffer = state.work_buf, desc = 'Invite URL' })
    vim.keymap.set('n', 'p', function() M.edit_policy() end, { buffer = state.work_buf, desc = 'Edit policy' })
    vim.keymap.set('n', 'm', function() M.start_merge() end, { buffer = state.work_buf, desc = 'Start merge' })
  end
end

local function load_menu_echoes()
  local ok, echoes = pcall(run_json, { 'show', 'echoes', '--json' })
  local subscribed = {}
  if ok and type(echoes) == 'table' then
    for _, e in ipairs(echoes) do
      if e.subscribed then subscribed[#subscribed + 1] = e end
    end
  end
  state.menu_echoes = subscribed
  return subscribed
end

local function load_menu_folders()
  local folders = {
    { name = 'inbox', label = 'Inbox' }, { name = 'outbox', label = 'Outbox' },
    { name = 'sent', label = 'Sent' }, { name = 'deleted', label = 'Deleted' },
  }
  local ok, custom = pcall(run_json, { 'netmail', 'folder', 'list', '--json' })
  if ok and type(custom) == 'table' then
    for _, f in ipairs(custom) do table.insert(folders, { name = f.name, label = f.name }) end
  end
  state.menu_folders = folders
end

local function load_menu_blogs()
  local ok, blogs = pcall(run_json, { 'show', 'blogs', '--json' })
  state.menu_blogs = (ok and type(blogs) == 'table') and blogs or {}
end

local function load_menu_data()
  load_menu_echoes()
  load_menu_folders()
  load_menu_blogs()
end

local function render_menu()
  if not valid_win(state.menu_win) then return end
  local lines = { app_title() }
  local meta = {}
  local function add(label, item)
    table.insert(lines, label)
    meta[#lines] = item
  end
  add('  ⚙ Settings', { kind = 'screen', screen = 'settings' })
  add('  🔎 All echoes', { kind = 'screen', screen = 'echoes' })
  add('  🛠 Active protocols', { kind = 'screen', screen = 'protocols' })
  table.insert(lines, '  ECHOES')
  for _, e in ipairs(state.menu_echoes or {}) do
    table.insert(lines, '  ● ' .. e.name)
    meta[#lines] = { kind = 'echo', name = e.name, subscribed = true }
  end
  if #(state.menu_echoes or {}) == 0 then table.insert(lines, '  (no subscribed echoes)') end
  if #(state.menu_blogs or {}) > 0 then
    table.insert(lines, '  BLOGS')
    for _, b in ipairs(state.menu_blogs) do
      table.insert(lines, '  ✎ ' .. b.name)
      meta[#lines] = { kind = 'blog', name = b.name }
    end
  end
  table.insert(lines, '  NETMAIL')
  for _, f in ipairs(state.menu_folders or {}) do
    table.insert(lines, '  ' .. f.label)
    meta[#lines] = { kind = 'netmail_folder', folder = f.name, name = f.label }
  end
  table.insert(lines, '')
  table.insert(lines, '  a write  c echo  b blog  S subscribe')
  table.insert(lines, '  l list   s sync  r refresh  q close')
  table.insert(lines, string.format('  P protocols %s', state.show_protocols and 'on' or 'off'))
  set_lines(state.menu_buf, lines)
  meta[1] = { kind = 'screen', screen = 'settings' }
  state.menu_meta = meta
  vim.keymap.set('n', '<CR>', function() M.open_menu_at_cursor() end, { buffer = state.menu_buf, desc = 'Open' })
  vim.keymap.set('n', 'a', function() M.add_message() end, { buffer = state.menu_buf, desc = 'Write a message' })
  vim.keymap.set('n', 'e', function() M.add_message() end, { buffer = state.menu_buf, desc = 'Write a message' })
  vim.keymap.set('n', 'l', function() M.open_selected_list() end, { buffer = state.menu_buf, desc = 'Message list' })
  vim.keymap.set('n', 'c', function() M.create_echo() end, { buffer = state.menu_buf, desc = 'Create echo' })
  vim.keymap.set('n', 'b', function() M.create_blog() end, { buffer = state.menu_buf, desc = 'Create blog' })
  vim.keymap.set('n', 'S', function() M.subscribe_selected() end, { buffer = state.menu_buf, desc = 'Subscribe/unsubscribe' })
  vim.keymap.set('n', 'n', function() M.create_netmail_folder() end, { buffer = state.menu_buf, desc = 'New netmail folder' })
  vim.keymap.set('n', 'd', function() M.delete_netmail_folder() end, { buffer = state.menu_buf, desc = 'Delete netmail folder' })
  vim.keymap.set('n', 's', function() M.sync() end, { buffer = state.menu_buf, desc = 'Send/receive' })
  vim.keymap.set('n', 'r', function() M.refresh() end, { buffer = state.menu_buf, desc = 'Refresh' })
  vim.keymap.set('n', 'P', function() M.toggle_protocols() end, { buffer = state.menu_buf, desc = 'Toggle protocol messages' })
  vim.keymap.set('n', 'q', function() M.close() end, { buffer = state.menu_buf, desc = 'Close' })
  vim.keymap.set('n', 'E', function() M.open_screen('settings') end, { buffer = state.menu_buf, desc = 'Settings' })
end

function M.refresh()
  if not ensure_ready() then return end
  load_menu_data()
  render_menu()
  if state.screen == 'echoes' or state.screen == 'echo' then
    if state.echo then M.open_echo(state.echo) else M.show_reader_placeholder() end
  elseif state.screen == 'netmail' then
    if state.netmail_folder then M.open_netmail(state.netmail_folder) else M.open_screen('netmail', true) end
  elseif state.screen == 'blog' and state.current_blog then M.open_blog(state.current_blog) end
end

function M.open_screen(name, keep_history)
  if not ensure_ready() then return end
  ensure_layout()
  close_message_windows()
  if not keep_history and state.work_view and state.work_view.screen then
    table.insert(state.history, state.work_view)
  end
  state.screen = name
  state.current_echo = nil
  state.current_blog = nil
  if name == 'menu' then
    render_work({ app_title(), '', 'Choose a section in the left menu.' }, {}, { screen = 'menu', lines = { app_title() } })
  elseif name == 'protocols' then
    M.open_protocols(nil)
  elseif name == 'echoes' then
    state.netmail_folder, state.netmail_msgs = nil, {}
    state.echo, state.echo_msgs, state.echo_last_read = nil, {}, 0
    local ok, echoes = pcall(run_json, { 'show', 'echoes', '--json' })
    if not ok then render_work({ '# Echoes', '', 'Error: ' .. tostring(echoes) }, {}, { screen = 'echoes' }); return end
    local lines, meta = { '# Echoes', '' }, {}
    for _, e in ipairs(echoes or {}) do
      local mark = e.subscribed and '●' or '○'
      table.insert(lines, string.format('%s %s  %s', mark, e.name, e.description or ''))
      meta[#lines] = { kind = 'echo', name = e.name, subscribed = e.subscribed }
    end
    table.insert(lines, '')
    table.insert(lines, 'c create echo   b create blog   s subscribe   e compose')
    render_work(lines, meta, { screen = 'echoes', lines = lines, meta = meta })
  elseif name == 'netmail' then
    state.echo, state.echo_msgs, state.echo_last_read = nil, {}, 0
    state.netmail_folder, state.netmail_msgs = nil, {}
    local folders = { { name = 'inbox', label = 'Inbox' }, { name = 'outbox', label = 'Outbox' }, { name = 'sent', label = 'Sent' }, { name = 'deleted', label = 'Deleted' } }
    local ok, custom = pcall(run_json, { 'netmail', 'folder', 'list', '--json' })
    if ok then for _, f in ipairs(custom or {}) do table.insert(folders, { name = f.name, label = f.name }) end end
    local lines, meta = { '# Netmail', '' }, {}
    for _, f in ipairs(folders) do
      table.insert(lines, '  ' .. f.label)
      meta[#lines] = { kind = 'netmail_folder', folder = f.name, name = f.label }
    end
    table.insert(lines, '')
    table.insert(lines, 'n new folder   d delete folder   l list   e compose')
    render_work(lines, meta, { screen = 'netmail', lines = lines, meta = meta })
  elseif name == 'settings' then
    local lines = { '# Settings', '', 'e export settings', 'i import settings', 'p show policy', 'a admin (if available)', 'q back' }
    render_work(lines, {}, { screen = 'settings', lines = lines })
  elseif name == 'admin' then
    if not (state.identity and state.identity.is_admin) then render_work({ '# Admin', '', 'Admin access required.' }, {}, { screen = 'settings' }); return end
    local lines = { '# Admin', '', 'i show invite URL', 'p edit policy (JSON file)', 'm start merge (invite URL)', 'q back' }
    render_work(lines, {}, { screen = 'admin', lines = lines })
  end
end

function M.open_menu_at_cursor()
  if not valid_win(state.menu_win) then return end
  local line = vim.api.nvim_win_get_cursor(state.menu_win)[1]
  local item = state.menu_meta[line]
  if not item then return end
  if item.kind == 'screen' then M.open_screen(item.screen)
  elseif item.kind == 'echo' then M.open_echo(item.name)
  elseif item.kind == 'blog' then M.open_blog(item.name)
  elseif item.kind == 'netmail_folder' then M.open_netmail(item.folder) end
end

local function selected_menu_item()
  if not valid_win(state.menu_win) then return nil end
  if vim.api.nvim_get_current_win() ~= state.menu_win then return nil end
  return state.menu_meta[vim.api.nvim_win_get_cursor(state.menu_win)[1]]
end

local function selected_menu_echo()
  local item = selected_menu_item()
  if item and item.kind == 'echo' then return item.name end
  return nil
end

function M.open_selected_list()
  local item = selected_menu_item()
  if item and item.kind == 'echo' then M.open_echo(item.name)
  elseif item and item.kind == 'netmail_folder' then M.open_netmail(item.folder)
  elseif item and item.kind == 'blog' then M.open_blog(item.name); return end
  M.open_list()
end

function M.compose_selected_echo()
  local name = selected_menu_echo() or state.echo or ''
  M.compose('echo', name)
end

function M.open_work_at_cursor()
  if not valid_win(state.work_win) then return end
  local line = vim.api.nvim_win_get_cursor(state.work_win)[1]
  local item = state.work_meta[line]
  if not item then return end
  if item.kind == 'echo' then M.open_echo(item.name)
  elseif item.kind == 'netmail_folder' then M.open_netmail(item.folder)
  elseif item.kind == 'protocol' then
    state.echo = item.msg.echo or state.echo
    state.current_protocol_messages = state.current_protocol_messages or {}
    M.open_message(item.msg)
  elseif item.kind == 'protocol_action' then M.run_protocol_action(item.action)
  end
end

function M.back()
  close_message_windows()
  local previous = table.remove(state.history)
  if previous then
    state.screen = previous.screen or 'menu'
    if previous.echo then state.echo = previous.echo end
    render_work(previous.lines or { '' }, previous.meta or {}, previous)
    return
  end
  state.screen = 'menu'
  render_work({ app_title(), '', 'Choose a section in the left menu.' }, {}, { screen = 'menu', lines = { app_title() } })
  if valid_win(state.menu_win) then vim.api.nvim_set_current_win(state.menu_win) end
end

local function render_empty_message(title, hint)
  ensure_layout()
  close_message_windows()
  local lines = { title, '', hint, '', 'Press a to write a new message.', 'q back' }
  set_lines(state.work_buf, lines)
  state.work_meta, state.work_view = {}, { screen = 'empty', lines = lines, echo = state.echo }
  vim.api.nvim_win_set_buf(state.work_win, state.work_buf)
  vim.api.nvim_set_current_win(state.work_win)
  vim.keymap.set('n', 'a', function() M.add_message() end, { buffer = state.work_buf, desc = 'Write a message' })
  vim.keymap.set('n', 'e', function() M.add_message() end, { buffer = state.work_buf, desc = 'Write a message' })
  vim.keymap.set('n', 'q', function() M.back() end, { buffer = state.work_buf, desc = 'Back' })
  vim.keymap.set('n', 'u', function() M.back() end, { buffer = state.work_buf, desc = 'Back' })
  vim.keymap.set('n', 'P', function() M.toggle_protocols() end, { buffer = state.work_buf, desc = 'Toggle protocol messages' })
end

function M.open_blog(name)
  local ok, posts = pcall(run_json, { 'show', 'blog', name, '--json' })
  if not ok then vim.notify('fmclient: ' .. tostring(posts), vim.log.levels.ERROR); return end
  state.echo, state.echo_msgs, state.echo_last_read = nil, {}, 0
  state.netmail_folder, state.netmail_msgs = nil, {}
  state.current_blog = name
  state.screen = 'blog'
  ensure_layout()
  close_message_windows()
  local lines = { '# Blog · ' .. name, '' }
  if type(posts) ~= 'table' or #posts == 0 then
    table.insert(lines, 'No posts.')
    table.insert(lines, '')
    table.insert(lines, 'Press a to write a new post.')
  else
    for _, post in ipairs(posts) do
      table.insert(lines, string.format('  %s  %s', M.fmt_date(post.created_at or post.timestamp), post.title or '(no title)'))
    end
    table.insert(lines, '')
    table.insert(lines, 'Press a to write a new post.')
  end
  set_lines(state.work_buf, lines)
  state.work_meta, state.work_view = {}, { screen = 'blog', blog = name, lines = lines }
  vim.api.nvim_win_set_buf(state.work_win, state.work_buf)
  vim.api.nvim_set_current_win(state.work_win)
  vim.keymap.set('n', 'a', function() M.compose_blog(name) end, { buffer = state.work_buf, desc = 'Write a blog post' })
  vim.keymap.set('n', 'q', function() M.back() end, { buffer = state.work_buf, desc = 'Back' })
end

function M.open_echo(name)
  local ok, messages = pcall(run_json, { 'show', 'messages', name, '--all', '--json' })
  if not ok then vim.notify('fmclient: ' .. tostring(messages), vim.log.levels.ERROR); return end
  local all_messages = sort_messages(messages or {})
  state.echo_all_msgs = all_messages
  messages = filter_protocols(all_messages)
  local last_read = 0
  local echoes_ok, echoes = pcall(run_json, { 'show', 'echoes', '--json' })
  if echoes_ok and type(echoes) == 'table' then
    for _, e in ipairs(echoes) do if e.name == name then last_read = e.last_read or 0 break end end
  end
  state.echo, state.echo_msgs, state.echo_last_read = name, messages, last_read
  state.netmail_folder, state.netmail_msgs = nil, {}
  state.screen = 'echo'
  state.current_blog = nil
  if #messages == 0 then
    render_empty_message('# ' .. name, 'No messages in this echo.')
    return
  end
  local target = messages[#messages]
  for _, m in ipairs(messages) do if (m.timestamp or 0) <= last_read then target = m end end
  M.open_message(target)
end

function M.open_netmail(folder)
  local ok, messages
  if folder == 'outbox' then ok, messages = pcall(run_json, { 'show', 'outbox', '--json' })
  else ok, messages = pcall(run_json, { 'show', 'netmail', '--folder', folder, '--all', '--json' }) end
  if not ok then vim.notify('fmclient: ' .. tostring(messages), vim.log.levels.ERROR); return end
  messages = sort_messages(messages or {})
  state.echo, state.echo_msgs, state.echo_last_read = nil, {}, 0
  state.netmail_folder, state.netmail_msgs = folder, messages
  state.current_blog = nil
  state.screen = 'netmail'
  if #messages == 0 then
    render_empty_message('# Netmail · ' .. folder, 'No messages in this folder.')
    return
  end
  local target = messages[#messages]
  for _, m in ipairs(messages) do if m.read then target = m end end
  M.open_message(target)
end

local function attachment_parts(data_url)
  if type(data_url) ~= 'string' then return nil end
  local meta, payload = data_url:match('^data:([^;]+);base64,(.*)$')
  if not meta then return nil end
  local ok, bytes = pcall(vim.base64.decode, payload)
  if not ok then return nil end
  return meta, bytes
end

local function write_attachment(data_url, name)
  local meta, bytes = attachment_parts(data_url)
  if not meta then return nil end
  local ext = ''
  if meta:find('image/png') then ext = '.png'
  elseif meta:find('image/jpeg') then ext = '.jpg'
  elseif meta:find('image/gif') then ext = '.gif'
  elseif meta:find('image/webp') then ext = '.webp'
  elseif meta:find('json') then ext = '.json'
  elseif meta:find('text') then ext = '.txt' end
  local path = vim.fn.tempname() .. ext
  local f = io.open(path, 'wb')
  if not f then return nil end
  f:write(bytes)
  f:close()
  return path, meta, bytes
end

function M.open_attachment(index)
  local msg = state.current_msg
  if not msg then return end
  local data = parse_data(msg)
  local att = data.attachments and data.attachments[index]
  if not att then return end
  local path, mime, bytes = write_attachment(att.data or att.dataUrl or '', att.name or 'attachment')
  if not path then vim.notify('fmclient: cannot decode attachment', vim.log.levels.ERROR); return end
  local is_message = (mime or ''):find('json') or (att.name or ''):match('%.json$')
  if is_message and bytes then
    local ok, attached = pcall(vim.json.decode, table.concat(vim.split(bytes, '\n'), ''))
    if ok and type(attached) == 'table' then
      local lines = { 'Attached message', '', 'From: ' .. (attached.from or attached.sender_address or ''), 'To: ' .. (attached.to or attached.recipient_address or ''), 'Subject: ' .. (attached.subject or ''), '', attached.body or attached.message or '' }
      local buf = ensure_buf('fmclient://message/attached.md', 'markdown')
      set_lines(buf, lines)
      if not valid_win(state.msg_wins.attached) then
        state.msg_wins.attached = vim.api.nvim_open_win(buf, false, { split = 'below', win = state.work_win, height = math.max(5, math.floor(vim.o.lines / 5)) })
      else
        vim.api.nvim_win_set_buf(state.msg_wins.attached, buf)
      end
      vim.wo[state.msg_wins.attached].wrap = true
      return
    end
  end
  local image = (mime or ''):find('^image/') ~= nil
  local viewer = vim.g.fmclient_image_viewer
  if image and type(viewer) == 'string' and viewer ~= '' then
    vim.fn.jobstart({ viewer, path }, { detach = true })
  elseif vim.ui and vim.ui.open then
    vim.ui.open(path)
  else
    vim.notify('fmclient: attachment saved to ' .. path)
  end
end

function M.open_message(msg)
  if not ensure_ready() then return end
  ensure_layout()
  if state.work_view and state.work_view.screen then table.insert(state.history, state.work_view) end
  close_message_windows()
  state.current_msg = msg
  local data = parse_data(msg)
  local body_buf = ensure_buf('fmclient://message/body.md', 'markdown')
  local body = data.body or data.message or msg.body or ''
  set_lines(body_buf, vim.split(body, '\n', { plain = true }))
  local header_buf = ensure_buf('fmclient://message/header', 'fmclient')
  local last = state.echo_last_read or 0
  local total = #(state.echo_msgs or {})
  local new = 0
  if state.echo then for _, m in ipairs(state.echo_msgs or {}) do if (m.timestamp or 0) > last then new = new + 1 end end end
  local header = { 'Echo: ' .. (msg.echo or state.echo or ''), 'From: ' .. (msg.sender_address or ''), 'To: ' .. (msg.recipient_address or ''), 'Date: ' .. M.fmt_date(msg.timestamp), 'Subject: ' .. (msg.subject or '(no subject)') }
  if state.echo then
    table.insert(header, string.format('Messages: %d / new: %d', total, new))
  elseif state.netmail_folder then
    local net_total = #(state.netmail_msgs or {})
    local net_new = 0
    for _, m in ipairs(state.netmail_msgs or {}) do if not m.read then net_new = net_new + 1 end end
    table.insert(header, string.format('Messages: %d / new: %d', net_total, net_new))
  end
  set_lines(header_buf, header)
  local footer_buf = ensure_buf('fmclient://message/footer', 'fmclient')
  local footer = {}
  local attachments = data.attachments or {}
  for i, att in ipairs(attachments) do
    table.insert(footer, string.format('%d. %s (%s)', i, att.name or 'attachment', att.type or 'file'))
  end
  if data.tagline and data.tagline ~= '' then table.insert(footer, 'Tagline: ' .. data.tagline) end
  if data.tearline and data.tearline ~= '' then table.insert(footer, 'Tearline: ' .. data.tearline) end
  local context = state.echo_all_msgs
  if type(context) ~= 'table' or #context == 0 then context = state.current_protocol_messages end
  if type(context) ~= 'table' or #context == 0 then context = state.echo_msgs end
  local actions = protocols.actions(msg, { identity = state.identity, messages = context or {} })
  local footer_actions = {}
  for _, a in ipairs(actions) do
    table.insert(footer, string.format('%s) %s', a.key, a.label))
    footer_actions[#footer] = a
  end
  vim.api.nvim_win_set_buf(state.work_win, body_buf)
  vim.wo[state.work_win].wrap = true
  state.msg_wins.header = vim.api.nvim_open_win(header_buf, false, { split = 'above', win = state.work_win, height = 6 })
  vim.wo[state.msg_wins.header].wrap = true
  vim.wo[state.msg_wins.header].number = false
  vim.wo[state.msg_wins.header].relativenumber = false
  vim.wo[state.msg_wins.header].winfixheight = true
  if #footer > 0 then
    set_lines(footer_buf, footer)
    state.msg_wins.footer = vim.api.nvim_open_win(footer_buf, false, { split = 'below', win = state.work_win, height = math.max(3, math.min(8, #footer)) })
    state.msg_wins.footer_buf = footer_buf
    state.msg_wins.footer_lines = footer
    state.msg_wins.footer_actions = footer_actions
    vim.wo[state.msg_wins.footer].wrap = true
    vim.wo[state.msg_wins.footer].number = false
    vim.wo[state.msg_wins.footer].relativenumber = false
    vim.wo[state.msg_wins.footer].winfixheight = true
  end
  vim.keymap.set('n', 'q', function() M.back() end, { buffer = body_buf, desc = 'Back' })
  vim.keymap.set('n', 'u', function() M.back() end, { buffer = body_buf, desc = 'Back' })
  vim.keymap.set('n', 'a', function() M.add_message() end, { buffer = body_buf, desc = 'Write a message' })
  vim.keymap.set('n', 'o', function() M.pick_attachment() end, { buffer = body_buf, desc = 'Open attachment' })
  vim.keymap.set('n', 'l', function() M.open_list() end, { buffer = body_buf, desc = 'Message list' })
  vim.keymap.set('n', 'e', function()
    if state.echo then M.compose('echo', state.echo)
    else M.compose('netmail', msg.sender_address or '') end
  end, { buffer = body_buf, desc = 'Compose new message' })
  vim.keymap.set('n', 'c', function() M.create_echo() end, { buffer = body_buf, desc = 'Create echo' })
  vim.keymap.set('n', 'b', function() M.create_blog() end, { buffer = body_buf, desc = 'Create blog' })
  vim.keymap.set('n', 'S', function() M.subscribe_selected() end, { buffer = body_buf, desc = 'Subscribe/unsubscribe' })
  if #footer > 0 then
    local function footer_enter()
      local line = vim.api.nvim_win_get_cursor(state.msg_wins.footer)[1]
      local action = (state.msg_wins.footer_actions or {})[line]
      if action then M.run_protocol_action(action.action); return end
      local text = (state.msg_wins.footer_lines or {})[line]
      local idx = text and text:match('^(%d+)%.')
      if idx then M.open_attachment(tonumber(idx)) else M.pick_attachment() end
    end
    vim.keymap.set('n', '<CR>', footer_enter, { buffer = footer_buf, desc = 'Open attachment / vote' })
    vim.keymap.set('n', 'o', footer_enter, { buffer = footer_buf, desc = 'Open attachment / vote' })
    vim.keymap.set('n', 'a', function() M.add_message() end, { buffer = footer_buf, desc = 'Write a message' })
  end
  if #actions > 0 then
    for _, a in ipairs(actions) do
      if #a.key == 1 then
        local action = a.action
        vim.keymap.set('n', a.key, function() M.run_protocol_action(action) end,
          { buffer = body_buf, desc = 'Protocol: ' .. a.label })
        if valid_buf(footer_buf) then
          vim.keymap.set('n', a.key, function() M.run_protocol_action(action) end,
            { buffer = footer_buf, desc = 'Protocol: ' .. a.label })
        end
      end
    end
  end
  vim.api.nvim_set_current_win(state.work_win)
  if state.netmail_msgs then
    for _, m in ipairs(state.netmail_msgs) do if m.message_id == msg.message_id then m.read = true end end
  end
  if msg.message_id then
    pcall(run, { 'mark-read', msg.message_id })
    if state.echo and msg.timestamp then
      pcall(run, { 'mark-read', '--echo', state.echo, '--timestamp', tostring(msg.timestamp) })
    end
  end
end

function M.compose_blog(name)
  if not ensure_ready() then return end
  ensure_layout()
  close_message_windows()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, string.format('fmclient://blog-compose/%s/%d', name, state.compose_seq))
  state.compose_seq = state.compose_seq + 1
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'markdown'
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'Title: ', '--', '' })
  vim.bo[buf].modified = false
  vim.api.nvim_win_set_buf(state.work_win, buf)
  vim.api.nvim_set_current_win(state.work_win)
  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local title, body, in_body = '', {}, false
    for _, line in ipairs(lines) do
      if line == '--' then in_body = true
      elseif not in_body then local v = line:match('^Title:%s*(.*)$'); if v then title = v end
      else table.insert(body, line) end
    end
    local file = vim.fn.tempname()
    vim.fn.writefile(body, file)
    local ok, err = pcall(run, { 'blog', 'post', name, '--title', title, '--body-file', file })
    os.remove(file)
    if not ok then vim.notify('fmclient: ' .. tostring(err), vim.log.levels.ERROR); return end
    vim.bo[buf].modified = false
    M.open_blog(name)
  end
  vim.keymap.set('n', '<leader>s', submit, { buffer = buf, desc = 'Save blog post' })
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = submit })
  vim.notify('fmclient: edit the post and press <leader>s or :w to save', vim.log.levels.INFO)
end

function M.add_message()
  local item = selected_menu_item()
  if item and item.kind == 'blog' then M.compose_blog(item.name); return end
  if item and item.kind == 'echo' then M.compose('echo', item.name); return end
  if item and item.kind == 'netmail_folder' then M.compose('netmail', ''); return end
  if state.current_blog then M.compose_blog(state.current_blog); return end
  if state.echo then M.compose('echo', state.echo); return end
  if state.netmail_folder then M.compose('netmail', ''); return end
  M.compose('echo', '')
end

function M.pick_attachment()
  local data = parse_data(state.current_msg)
  local atts = data.attachments or {}
  if #atts == 0 then vim.notify('fmclient: no attachments'); return end
  if #atts == 1 then M.open_attachment(1); return end
  vim.ui.select(vim.tbl_map(function(a) return a.name or 'attachment' end, atts), { prompt = 'Attachment' }, function(_, idx) if idx then M.open_attachment(idx) end end)
end

function M.run_protocol_action(action)
  if type(action) ~= 'table' then return end
  local args
  if action.kind == 'vote' then
    args = { 'vote', 'cast', action.echo, action.poster, action.variant }
  elseif action.kind == 'change_policy' then
    args = { 'change-policy', 'vote', '--echo', action.echo, '--poster', action.poster, '--variant', action.variant }
  elseif action.kind == 'appeal' then
    args = { 'appeal', 'vote', '--echo', action.echo, '--poster', action.poster, '--variant', action.variant }
  elseif action.kind == 'excommunicate' then
    args = { 'excommunicate', 'vote', '--echo', action.echo, '--target', action.target,
             '--poster', action.poster, '--variant', action.variant }
  elseif action.kind == 'merge' then
    args = { 'merge', 'vote', '--echo', action.echo, '--state-key', action.state_key,
             '--phase', tostring(action.phase or 1), '--poster', action.poster, '--variant', action.variant }
    local chunk = tonumber(action.chunk_index)
    if chunk and chunk >= 0 then
      table.insert(args, '--chunk-index')
      table.insert(args, tostring(chunk))
    end
  elseif action.kind == 'election' then
    args = { 'election', 'vote', action.echo, action.candidate }
  elseif action.kind == 'election_retract' then
    args = { 'election', 'retract', action.echo }
  elseif action.kind == 'refill' then
    args = { 'refill', 'respond', action.echo, '--to', action.to, '--before', action.before }
  end
  if not args then return end
  local ok, err = pcall(run, args)
  if not ok then vim.notify('fmclient: ' .. tostring(err), vim.log.levels.ERROR); return end
  pcall(run, { 'send_receive' })
  vim.notify('fmclient: protocol action queued', vim.log.levels.INFO)
  if state.screen == 'protocols' then M.open_protocols(state.current_echo) end
end

function M.cast_vote(variant)
  if not state.current_msg or not state.current_msg.message_id then return end
  local echo = state.current_msg.echo or state.echo or ''
  M.run_protocol_action({ kind = 'vote', echo = echo, poster = state.current_msg.message_id, variant = variant })
end

function M.run_action_for_cursor(key)
  if not valid_win(state.work_win) then return end
  local line = vim.api.nvim_win_get_cursor(state.work_win)[1]
  local item = state.work_meta[line]
  if item and item.kind == 'protocol_action' then
    if not key or item.key == key then M.run_protocol_action(item.action) end
    return
  end
  local actions
  for i = line, 1, -1 do
    local it = state.work_meta[i]
    if it and it.kind == 'protocol' then
      actions = state.protocol_actions[it.msg.message_id]
      break
    end
  end
  if not actions then return end
  for _, a in ipairs(actions) do
    if a.key == key then M.run_protocol_action(a.action); return end
  end
end

function M.open_protocols(echo)
  if not ensure_ready() then return end
  ensure_layout()
  close_message_windows()
  local messages = {}
  if echo and echo ~= '' then
    if state.echo == echo and type(state.echo_all_msgs) == 'table' and #state.echo_all_msgs > 0 then
      messages = state.echo_all_msgs
    else
      local ok, msgs = pcall(run_json, { 'show', 'messages', echo, '--all', '--json' })
      if ok then messages = msgs or {} end
    end
  else
    local echoes = state.menu_echoes
    if not echoes or #echoes == 0 then echoes = load_menu_echoes() end
    for _, e in ipairs(echoes or {}) do
      local ok, msgs = pcall(run_json, { 'show', 'messages', e.name, '--all', '--json' })
      if ok then
        for _, m in ipairs(msgs or {}) do
          if not m.echo or m.echo == '' then m.echo = e.name end
          table.insert(messages, m)
        end
      end
    end
  end
  messages = sort_messages(messages)
  local items = protocols.active(messages, { identity = state.identity, messages = messages })
  local lines = { '# Active protocols', '' }
  local meta, action_map = {}, {}
  for _, item in ipairs(items) do
    table.insert(lines, protocols.format_line(item))
    meta[#lines] = { kind = 'protocol', msg = item.msg }
    local actions = protocols.actions(item.msg, { identity = state.identity, messages = messages })
    action_map[item.msg.message_id] = actions
    for _, a in ipairs(actions) do
      table.insert(lines, string.format('   %s) %s', a.key, a.label))
      meta[#lines] = { kind = 'protocol_action', action = a.action, key = a.key }
    end
    table.insert(lines, '')
  end
  if #items == 0 then table.insert(lines, 'No active protocols.') end
  table.insert(lines, string.format('Enter open/vote   P protocols %s   q back', state.show_protocols and 'on' or 'off'))
  state.echo_all_msgs = messages
  state.current_protocol_messages = messages
  state.protocol_actions = action_map
  state.current_echo = echo
  state.screen = 'protocols'
  render_work(lines, meta, { screen = 'protocols', lines = lines, meta = meta })
  for _, key in ipairs({ '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', 'A', 'R' }) do
    vim.keymap.set('n', key, function() M.run_action_for_cursor(key) end,
      { buffer = state.work_buf, desc = 'Protocol action' })
  end
end

function M.toggle_protocols()
  state.show_protocols = not state.show_protocols
  vim.g.fmclient_show_protocols = state.show_protocols
  vim.notify('fmclient: protocol messages ' .. (state.show_protocols and 'on' or 'off'), vim.log.levels.INFO)
  if state.screen == 'echo' and state.echo then
    M.open_echo(state.echo)
  elseif state.screen == 'protocols' then
    M.open_protocols(state.current_echo)
  else
    M.refresh()
  end
end

function M.create_echo()
  vim.ui.input({ prompt = 'Echo name: ' }, function(name)
    if not name or name == '' then return end
    vim.ui.input({ prompt = 'Description: ' }, function(description)
      local ok, err = pcall(run, { 'create', 'echo', name, '--local', '--description', description or '' })
      if not ok then vim.notify(tostring(err), vim.log.levels.ERROR); return end
      load_menu_data(); render_menu(); M.open_echo(name)
    end)
  end)
end

function M.create_blog()
  vim.ui.input({ prompt = 'Blog name: ' }, function(name)
    if not name or name == '' then return end
    vim.ui.input({ prompt = 'Description: ' }, function(description)
      local ok, err = pcall(run, { 'create', 'blog', name, '--description', description or '' })
      if not ok then vim.notify(tostring(err), vim.log.levels.ERROR); return end
      load_menu_data(); render_menu(); M.open_blog(name)
    end)
  end)
end

function M.subscribe_selected()
  local name = selected_menu_echo()
  if not name and state.echo then name = state.echo end
  if not name and valid_win(state.work_win) then
    local item = state.work_meta[vim.api.nvim_win_get_cursor(state.work_win)[1]]
    if item and item.kind == 'echo' then name = item.name end
  end
  if not name then vim.notify('fmclient: select an echo first', vim.log.levels.WARN); return end
  local ok, err = pcall(run, { 'subscribe', name })
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR); return end
  load_menu_data(); render_menu()
end

function M.create_netmail_folder()
  vim.ui.input({ prompt = 'Folder name: ' }, function(name)
    if not name or name == '' then return end
    local ok, err = pcall(run, { 'netmail', 'folder', 'create', name })
    if not ok then vim.notify(tostring(err), vim.log.levels.ERROR); return end
    load_menu_data(); render_menu(); M.open_screen('netmail')
  end)
end

function M.delete_netmail_folder()
  local item = selected_menu_item()
  if not item and valid_win(state.work_win) then
    item = state.work_meta[vim.api.nvim_win_get_cursor(state.work_win)[1]]
  end
  if not item or item.kind ~= 'netmail_folder' or item.folder == 'inbox' or item.folder == 'outbox' or item.folder == 'sent' or item.folder == 'deleted' then return end
  local ok, err = pcall(run, { 'netmail', 'folder', 'delete', item.folder })
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR); return end
  load_menu_data(); render_menu(); M.open_screen('netmail')
end

function M.open_list()
  local echo = state.echo
  local folder = state.netmail_folder
  local messages
  if echo then messages = state.echo_msgs
  elseif folder then
    local ok, value
    if folder == 'outbox' then ok, value = pcall(run_json, { 'show', 'outbox', '--json' })
    else ok, value = pcall(run_json, { 'show', 'netmail', '--folder', folder, '--all', '--json' }) end
    if ok then messages = sort_messages(value or {}) end
  end
  if not messages or #messages == 0 then vim.notify('fmclient: no messages'); return end
  -- Telescope is optional: use a small two-pane fallback when unavailable.
  local ok, telescope = pcall(require, 'telescope')
  if ok and telescope then
    local pickers = require('telescope.pickers')
    local finders = require('telescope.finders')
    local conf = require('telescope.config').values
    local previewers = require('telescope.previewers')
    local previewer = previewers.new_buffer_previewer({
      define_preview = function(self, entry)
        local data = parse_data(entry.value)
        local text = (data.subject or entry.value.subject or '') .. '\n\n' .. (data.body or data.message or entry.value.body or '')
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(text, '\n', { plain = true }))
        vim.bo[self.state.bufnr].filetype = 'markdown'
      end,
    })
    pickers.new({}, {
      prompt_title = echo or folder or 'Messages',
      finder = finders.new_table({
        results = messages,
        entry_maker = function(m)
          return { value = m, display = (m.subject or '(no subject)') .. ' · ' .. (m.sender_address or ''), ordinal = (m.subject or '') .. ' ' .. (m.body or '') }
        end,
      }),
      sorter = conf.generic_sorter({}),
      previewer = previewer,
    }):find()
    return
  end
  local list_buf = ensure_buf('fmclient://picker/list', 'fmclient')
  local preview_buf = ensure_buf('fmclient://picker/preview', 'markdown')
  local lines, meta = {}, {}
  for _, m in ipairs(messages) do
    table.insert(lines, string.format('%s  %s  %s', M.fmt_date(m.timestamp), m.sender_address or '?', m.subject or '(no subject)'))
    meta[#lines] = m
  end
  set_lines(list_buf, lines)
  local list_win = vim.api.nvim_open_win(list_buf, true, { split = 'left', win = state.work_win, width = math.max(30, math.floor(vim.o.columns / 3)) })
  local preview_win = vim.api.nvim_open_win(preview_buf, false, { split = 'right', win = list_win })
  state.picker_wins = { list_win, preview_win }
  local function preview()
    local line = vim.api.nvim_win_get_cursor(list_win)[1]
    local m = meta[line]
    if not m then return end
    local data = parse_data(m)
    set_lines(preview_buf, vim.split((data.subject or m.subject or '') .. '\n\n' .. (data.body or data.message or m.body or ''), '\n', { plain = true }))
  end
  vim.keymap.set('n', '<CR>', function() local m = meta[vim.api.nvim_win_get_cursor(list_win)[1]]; pcall(vim.api.nvim_win_close, list_win, true); pcall(vim.api.nvim_win_close, preview_win, true); if m then M.open_message(m) end end, { buffer = list_buf })
  vim.keymap.set('n', 'q', function() state.picker_wins = {}; pcall(vim.api.nvim_win_close, list_win, true); pcall(vim.api.nvim_win_close, preview_win, true) end, { buffer = list_buf })
  vim.api.nvim_create_autocmd('CursorMoved', { buffer = list_buf, callback = preview })
  preview()
end

function M.show_invite()
  local ok, out = pcall(run, { 'invite' })
  if not ok then vim.notify('fmclient: ' .. tostring(out), vim.log.levels.ERROR); return end
  local url = out[1] or ''
  vim.fn.setreg('+', url)
  vim.notify('fmclient invite copied: ' .. url, vim.log.levels.INFO)
end

function M.show_policy()
  local ok, out = pcall(run, { 'policy', 'show' })
  if not ok then vim.notify('fmclient: ' .. tostring(out), vim.log.levels.ERROR); return end
  vim.notify(table.concat(out, '\n'), vim.log.levels.INFO)
end

function M.edit_policy()
  local ok, payload = pcall(run_json, { 'policy', 'fetch', '--json' })
  if not ok then vim.notify('fmclient: ' .. tostring(payload), vim.log.levels.ERROR); return end
  local policy = payload and (payload.policy or payload)
  if type(policy) ~= 'table' then
    vim.notify('fmclient: current policy is empty', vim.log.levels.ERROR)
    return
  end
  ensure_layout()
  close_message_windows()
  local buf = ensure_buf('fmclient://policy.json', 'json')
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(json_pretty(policy), '\n', { plain = true }))
  vim.bo[buf].modified = false
  vim.api.nvim_win_set_buf(state.work_win, buf)
  vim.api.nvim_set_current_win(state.work_win)
  state.work_view = { screen = 'policy', lines = {} }

  local function submit()
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local decoded_ok, decoded = pcall(vim.json.decode, table.concat(lines, '\n'))
    if not decoded_ok or type(decoded) ~= 'table' then
      vim.notify('fmclient: policy is not valid JSON', vim.log.levels.ERROR)
      return
    end
    local file = vim.fn.tempname() .. '.json'
    vim.fn.writefile(lines, file)
    local propose_ok, err = pcall(run, { 'change-policy', 'propose', '--file', file, '--echo', 'Admin council' })
    os.remove(file)
    if not propose_ok then
      vim.notify('fmclient: ' .. tostring(err), vim.log.levels.ERROR)
      return
    end
    vim.bo[buf].modified = false
    vim.notify('fmclient: policy change proposed', vim.log.levels.INFO)
    M.sync()
  end

  vim.keymap.set('n', '<leader>s', submit, { buffer = buf, desc = 'Save and propose policy' })
  vim.keymap.set('n', 'q', function() M.open_screen('admin') end, { buffer = buf, desc = 'Back to admin' })
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = submit })
  vim.notify('fmclient: edit the policy and press <leader>s or :w to propose it', vim.log.levels.INFO)
end

function M.start_merge()
  local url = vim.fn.input('Peer invite URL: ')
  if url == '' then return end
  local ok, err = pcall(run, { 'merge', 'initiate', url })
  if not ok then vim.notify('fmclient: ' .. tostring(err), vim.log.levels.ERROR); return end
  vim.notify('fmclient: merge initiated', vim.log.levels.INFO)
end

function M.open_settings() M.open_screen('settings') end
function M.open_admin() M.open_screen('admin') end

function M.export_settings()
  local path = vim.fn.input('Export to: ', vim.fn.getcwd() .. '/fm-settings.json')
  if path == '' then return end
  local ok, err = pcall(run, { 'settings', 'export', '--output', path })
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR); return end
  vim.notify('fmclient: settings exported to ' .. path, vim.log.levels.INFO)
end

function M.import_settings()
  local path = vim.fn.input('Import from: ', vim.fn.getcwd() .. '/fm-settings.json')
  if path == '' then return end
  local ok, err = pcall(run, { 'settings', 'import', path })
  if not ok then vim.notify(tostring(err), vim.log.levels.ERROR); return end
  vim.notify('fmclient: settings imported', vim.log.levels.INFO)
end

function M.sync()
  if not ensure_ready() then return end
  local ok, err = pcall(run, { 'send_receive' })
  if not ok then vim.notify('fmclient: ' .. tostring(err), vim.log.levels.ERROR) end
  M.refresh()
end

function M.close()
  if state.closing then return end
  state.closing = true
  close_message_windows()
  for _, win in ipairs({ state.menu_win, state.work_win }) do if valid_win(win) then pcall(vim.api.nvim_win_close, win, true) end end
  state.menu_win, state.work_win, state.work_view, state.history = nil, nil, nil, {}
  state.closing = false
end

function M.on_win_closed(win)
  if state.closing then return end
  if win == state.menu_win or win == state.work_win then vim.schedule(function() M.close() end) end
end

function M.show_reader_placeholder()
  state.echo, state.echo_msgs, state.echo_last_read = nil, {}, 0
  state.netmail_folder, state.netmail_msgs = nil, {}
  state.current_blog = nil
  render_empty_message('FM client', 'No subscribed echoes.')
end

function M.open_layout()
  if not ensure_ready() then vim.notify('fmclient: no authorized fmclient in ' .. launch_dir() .. ' (checked launch, buffer and current directories; set vim.g.fmclient_data if needed)', vim.log.levels.WARN); return false end
  ensure_layout()
  load_menu_data()
  render_menu()
  state.screen = 'echoes'
  local target
  for _, e in ipairs(state.menu_echoes or {}) do
    if e.subscribed then target = e; break end
  end
  target = target or (state.menu_echoes or {})[1]
  if target then M.open_echo(target.name) else M.show_reader_placeholder() end
  return true
end

function M.toggle()
  if valid_win(state.menu_win) or valid_win(state.work_win) then M.close(); return end
  M.open_layout()
end

function M.auto()
  local enabled = vim.g.fmclient_auto
  if enabled == false or enabled == 0 or enabled == '0' or enabled == 'false' then return end
  if valid_win(state.menu_win) or valid_win(state.work_win) then return end
  if not M.detect(false) then return end
  M.open_layout()
end

function M.compose(kind, target)
  if not ensure_ready() then vim.notify('fmclient: not detected or not authorized', vim.log.levels.ERROR); return end
  if kind == 'echo' and (not target or target == '') then target = state.echo or selected_menu_echo() or '' end
  ensure_layout()
  close_message_windows()
  local header = kind == 'netmail' and { 'To: ' .. (target or ''), 'Subject: ', '', '--', '', '' } or { 'Echo: ' .. (target or ''), 'Subject: ', '', '--', '', '' }
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_name(buf, string.format('fmclient://compose/%s/%d', kind, state.compose_seq))
  state.compose_seq = state.compose_seq + 1
  -- A normal (non-nofile) buffer is writable: typing into a nofile buffer
  -- raises E382. BufWriteCmd still intercepts :w and sends the message.
  vim.bo[buf].buftype = 'acwrite'
  vim.bo[buf].bufhidden = 'wipe'
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = 'mail'
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, header)
  vim.bo[buf].modified = false
  vim.api.nvim_win_set_buf(state.work_win, buf)
  vim.api.nvim_set_current_win(state.work_win)
  vim.b[buf].fmclient_compose_kind = kind
  vim.keymap.set('n', '<leader>s', function() M.send_current(buf, kind) end, { buffer = buf, desc = 'Send message' })
  vim.api.nvim_create_autocmd('BufWriteCmd', { buffer = buf, callback = function() M.send_current(buf, kind) end })
  vim.notify('fmclient: edit the message and press <leader>s or :w to send', vim.log.levels.INFO)
end

function M.send_current_buffer()
  local buf = vim.api.nvim_get_current_buf()
  local kind = vim.b[buf].fmclient_compose_kind or 'echo'
  M.send_current(buf, kind)
end

function M.send_current(buf, kind)
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  local headers, body, in_body = {}, {}, false
  for _, line in ipairs(lines) do
    if line == '--' then in_body = true
    elseif not in_body then local k, v = line:match('^(%w+):%s*(.*)$'); if k then headers[k:lower()] = v end
    else table.insert(body, line) end
  end
  while body[1] == '' do table.remove(body, 1) end
  while body[#body] == '' do table.remove(body) end
  local file = vim.fn.tempname(); vim.fn.writefile(body, file)
  local ok, err
  if kind == 'netmail' then ok, err = pcall(run, { 'netmail', 'send', '--to', headers['to'] or '', '--subject', headers['subject'] or '', '--body-file', file })
  else ok, err = pcall(run, { 'post', headers['echo'] or state.current_echo or '', '--subject', headers['subject'] or '', '--body-file', file }) end
  os.remove(file)
  if not ok then vim.notify('fmclient: ' .. tostring(err), vim.log.levels.ERROR); return end
  if valid_buf(buf) then vim.bo[buf].modified = false end
  M.sync()
  vim.notify('fmclient: message queued and synced', vim.log.levels.INFO)
end

return M
