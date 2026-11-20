-- Run from the repository root:
--   nvim --headless -u NONE --cmd 'set rtp+=.' -c 'luafile fmclient-nvim/tests/headless.lua' -c qa!
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.rtp:append(root)
vim.g.fmclient_auto = false

-- A tiny authorized-client stub: the UI tests must not touch the network.
local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
vim.fn.writefile({
  '{"name":"E","description":"echo","subscribed":true,"last_read":2}',
}, tmp .. '/echoes.json')
vim.fn.writefile({
  '{"name":"custom","created_at":1}',
}, tmp .. '/folders.json')
vim.fn.writefile({
  '[{"message_id":"m1","type":"echomail","echo":"E","sender_address":":0:2","recipient_address":"all","subject":"one","timestamp":1,"read":true,"data":"{}","body":"body1"},' ..
  '{"message_id":"m2","type":"echomail","echo":"E","sender_address":":0:2","recipient_address":"all","subject":"two","timestamp":2,"read":true,"data":"{}","body":"body2"},' ..
  '{"message_id":"m3","type":"echomail","echo":"E","sender_address":":0:2","recipient_address":"all","subject":"three","timestamp":3,"read":false,"data":"{}","body":"body3"}]',
}, tmp .. '/messages.json')
vim.fn.writefile({
  '[{"message_id":"n1","type":"netmail","sender_address":":0:2","recipient_address":":0:1","subject":"read","timestamp":1,"read":true,"data":"{}","body":"n1"},' ..
  '{"message_id":"n2","type":"netmail","sender_address":":0:2","recipient_address":":0:1","subject":"unread","timestamp":2,"read":false,"data":"{}","body":"n2"}]',
}, tmp .. '/netmail.json')
local stub = tmp .. '/fmclient'
vim.fn.writefile({
  '#!/bin/sh',
  'case "$*" in',
  '  *"policy show --json"*) printf \'%s\\n\' \'{"address":":0:1","name":"Tester"}\' ;;',
  '  *"identity --json"*) printf \'%s\\n\' \'{"address":":0:1","is_admin":true,"network_name":"MyNet"}\' ;;',
  '  *"policy fetch --json"*) printf \'%s\\n\' \'{"id":"policy1","policy":{"text":"rules","parameters":{"a":"1"}}}\' ;;',
  '  *"show echoes --json"*) printf \'[%s]\\n\' "$(cat ' .. tmp .. '/echoes.json)" ;;',
  '  *"show messages E"*) cat ' .. tmp .. '/messages.json; echo ;;',
  '  *"show messages NoMsgs"*) printf \'[]\\n\' ;;',
  '  *"show netmail --folder inbox"*) cat ' .. tmp .. '/netmail.json; echo ;;',
  '  *"netmail folder list --json"*) cat ' .. tmp .. '/folders.json; echo ;;',
  '  *"show blogs --json"*) printf \'[%s]\\n\' \'{"id":1,"name":"B"}\' ;;',
  '  *"show blog B --json"*) printf \'[%s]\\n\' \'{"title":"first","created_at":1}\' ;;',
  '  *) exit 0 ;;',
  'esac',
}, stub)
vim.fn.setfperm(stub, 'rwxr-xr-x')
vim.fn.writefile({}, tmp .. '/fmclient.db')
vim.g.fmclient_cmd = stub
vim.g.fmclient_data = tmp

local fm = require('fmclient')

local msg = {
  echo = 'Test', sender_address = ':0:1', recipient_address = 'all',
  subject = 'Subject', timestamp = 1793034877, body = 'line 1\nline 2',
  message_id = 'test-message',
}

local function named_buffer(name)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf) == name then return buf end
  end
end

assert(fm.detect(true), 'client not detected')
assert(fm.open_layout(), 'layout did not open')
-- The startup layout is the GoldED-style two columns: echo/menu sidebar on
-- the left and a reader on the right (header/body; footer only when needed).
assert(#vim.api.nvim_list_wins() == 3, 'expected sidebar and two reader windows')
local sidebar = named_buffer('fmclient://sidebar')
local sidebar_lines = sidebar and vim.api.nvim_buf_get_lines(sidebar, 0, -1, false) or {}
assert(sidebar_lines[1] == 'MyNet · :0:1', 'network name missing from the sidebar: ' .. tostring(sidebar_lines[1]))
assert(vim.tbl_contains(sidebar_lines, '  ● E'), 'sidebar subscribed echo list missing')
assert(vim.tbl_contains(sidebar_lines, '  Inbox'), 'sidebar netmail folders missing')
assert(not vim.tbl_contains(sidebar_lines, '  ⛔ Admin'), 'Admin must not be in the common sidebar')

fm.open_message(msg)
fm.open_message(msg)
-- menu + header + body (no footer without attachments/taglines)
assert(#vim.api.nvim_list_wins() == 3, 'expected menu, header and body windows')
local header = named_buffer('fmclient://message/header')
local body = named_buffer('fmclient://message/body.md')
assert(header, 'header buffer missing')
assert(body, 'body buffer missing')
local header_lines = vim.api.nvim_buf_get_lines(header, 0, 10, false)
local body_lines = vim.api.nvim_buf_get_lines(body, 0, 10, false)
assert(header_lines[4] == 'Date: ' .. fm.fmt_date(msg.timestamp), 'date is not formatted')
assert(vim.tbl_contains(body_lines, 'line 2'), 'multiline body missing')
assert(vim.bo[body].filetype == 'markdown', 'message body must be markdown')
assert(vim.bo[body].syntax == 'markdown', 'message body must use markdown syntax')
assert(fm.fmt_date(1793034877) == os.date('%Y-%m-%d %H:%M', 1793034877), 'local timezone mismatch')

-- An attached message opens in a pane between the body and the footer.
local attached_json = vim.json.encode({ from = ':0:2', to = ':0:1', subject = 'Attached', body = 'inner' })
local attached_msg = vim.deepcopy(msg)
attached_msg.data = vim.json.encode({ body = 'outer', attachments = { {
  name = 'attached.json', type = 'application/json',
  data = 'data:application/json;base64,' .. vim.base64.encode(attached_json),
} } })
fm.open_message(attached_msg)
fm.open_attachment(1)
assert(#vim.api.nvim_list_wins() == 5, 'attached message pane missing')
local attached_win, footer_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  local name = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))
  if name == 'fmclient://message/attached.md' then attached_win = win end
  if name == 'fmclient://message/footer' then footer_win = win end
end
assert(attached_win and footer_win, 'attached/footer windows missing')
local arow = vim.api.nvim_win_get_position(attached_win)[1]
local frow = vim.api.nvim_win_get_position(footer_win)[1]
assert(arow < frow, 'attached message must be above the footer')

-- Closing a message must not treat footer metadata as a window and must
-- restore the work pane (regression for the old msg_wins iteration).
assert(pcall(fm.open_screen, 'menu'), 'back to a screen failed')

-- Echo opening uses the last read message and shows total/new in the header.
fm.open_echo('E')
header = named_buffer('fmclient://message/header')
body = named_buffer('fmclient://message/body.md')
assert(header and body, 'echo message buffers missing')
header_lines = vim.api.nvim_buf_get_lines(header, 0, 10, false)
assert(header_lines[1] == 'Echo: E', 'echo header missing')
assert(header_lines[6] == 'Messages: 3 / new: 1', 'echo counter wrong: ' .. tostring(header_lines[6]))
assert(vim.tbl_contains(vim.api.nvim_buf_get_lines(body, 0, 5, false), 'body2'), 'last read echo message not opened')

-- Netmail opens the last read message and shows its own counter.
fm.open_netmail('inbox')
header = named_buffer('fmclient://message/header')
assert(header, 'netmail header missing')
header_lines = vim.api.nvim_buf_get_lines(header, 0, 10, false)
assert(header_lines[6] == 'Messages: 2 / new: 1', 'netmail counter wrong: ' .. tostring(header_lines[6]))

-- An empty echo is a single work pane, not a three-row reader.
fm.open_echo('NoMsgs')
assert(#vim.api.nvim_list_wins() == 2, 'empty echo must keep only sidebar and work pane')
local empty_work = named_buffer('fmclient://work')
assert(empty_work and vim.tbl_contains(vim.api.nvim_buf_get_lines(empty_work, 0, 10, false), 'No messages in this echo.'), 'empty echo message missing')

-- Compose buffers are writable (E382 regression) and prefill the echo name.
fm.compose('echo', 'E')
local compose_buf = vim.api.nvim_get_current_buf()
assert(vim.bo[compose_buf].buftype == 'acwrite', 'compose buffer must be writable')
assert(vim.bo[compose_buf].modifiable, 'compose buffer must be editable')
local compose_lines = vim.api.nvim_buf_get_lines(compose_buf, 0, 5, false)
assert(compose_lines[1] == 'Echo: E', 'compose echo name is not prefilled: ' .. tostring(compose_lines[1]))
-- :w is handled by BufWriteCmd and must not fail on the writable compose buffer.
vim.api.nvim_buf_set_lines(compose_buf, -1, -1, false, { 'hello' })
local write_ok, write_err = pcall(vim.cmd, 'write'); assert(write_ok, 'compose :w failed: ' .. tostring(write_err))
fm.open_screen('menu')

-- The FM CLIENT menu header opens Settings (the old E5108 regression).
fm.open_screen('menu')
local menu_win
for _, win in ipairs(vim.api.nvim_list_wins()) do
  if vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win)) == 'fmclient://sidebar' then menu_win = win end
end
assert(menu_win, 'menu window missing')
vim.api.nvim_set_current_win(menu_win)
vim.api.nvim_win_set_cursor(menu_win, { 1, 0 })
fm.open_menu_at_cursor()
local work = named_buffer('fmclient://work')
assert(work and vim.tbl_contains(vim.api.nvim_buf_get_lines(work, 0, 3, false), '# Settings'), 'menu header did not open settings')

-- Blogs are listed in the sidebar and open as a single work pane.
fm.open_blog('B')
assert(#vim.api.nvim_list_wins() == 2, 'blog view must be a single work pane')
local blog_work = named_buffer('fmclient://work')
local blog_lines = blog_work and vim.api.nvim_buf_get_lines(blog_work, 0, 20, false) or {}
local blog_found = false
for _, line in ipairs(blog_lines) do if line:find('first', 1, true) then blog_found = true end end
assert(blog_found, 'blog posts missing')
fm.compose_blog('B')
local blog_buf = vim.api.nvim_get_current_buf()
assert(vim.bo[blog_buf].buftype == 'acwrite', 'blog compose buffer must be editable')
assert(vim.tbl_contains(vim.api.nvim_buf_get_lines(blog_buf, 0, 5, false), 'Title: '), 'blog title field missing')
fm.open_screen('menu')

-- Admin p downloads the live policy and opens it in an editable JSON buffer.
fm.edit_policy()
local policy_buf = named_buffer('fmclient://policy.json')
assert(policy_buf, 'policy editor buffer missing')
assert(vim.bo[policy_buf].filetype == 'json', 'policy buffer must be JSON')
assert(vim.bo[policy_buf].modifiable, 'policy buffer must be editable')
local policy_lines = vim.api.nvim_buf_get_lines(policy_buf, 0, -1, false)
assert(vim.tbl_contains(policy_lines, '  "text": "rules"'), 'policy content missing')
fm.open_screen('admin')

fm.close()
assert(#vim.api.nvim_list_wins() == 1, 'close must remove both panes')
print('fmclient nvim headless: OK')
