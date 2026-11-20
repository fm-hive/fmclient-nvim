-- Run from the repository root:
--   nvim --headless -u NONE --cmd 'set rtp+=.' -c 'luafile fmclient-nvim/tests/protocol_ui.lua' -c qa!
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.rtp:append(root)
vim.g.fmclient_auto = false

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, 'p')
local vote_data = vim.json.encode({
  proto = 'vote', type = 'poster', message = 'Choose', variants = { 'yes', 'no' },
})
local now = os.time()
vim.fn.writefile({
  '[{"message_id":"m1","type":"echomail","echo":"E","sender_address":":0:2","recipient_address":"all","subject":"one","timestamp":' .. now .. ',"read":true,"data":"{}","body":"body1"},' ..
  '{"message_id":"m2","type":"vote","echo":"E","sender_address":":0:2","recipient_address":"all","subject":"Choose","timestamp":' .. (now + 1) .. ',"read":false,"data":' .. vim.json.encode(vote_data) .. ',"body":"vote"}]',
}, tmp .. '/messages.json')
local actions_log = tmp .. '/actions.log'
local stub = tmp .. '/fmclient'
vim.fn.writefile({
  '#!/bin/sh',
  'case "$*" in',
  '  *"policy show --json"*) printf \'%s\\n\' \'{"address":":0:1","name":"Tester"}\' ;;',
  '  *"identity --json"*) printf \'%s\\n\' \'{"address":":0:1","is_admin":true}\' ;;',
  '  *"show echoes --json"*) printf \'%s\\n\' \'[{"name":"E","description":"echo","subscribed":true,"last_read":' .. now .. '}]\' ;;',
  '  *"show messages E"*) cat ' .. tmp .. '/messages.json; echo ;;',
  '  *"vote cast"*) printf \'%s\\n\' "$*" >> ' .. actions_log .. ' ;;',
  '  *"send_receive"*) ;;',
  '  *) exit 0 ;;',
  'esac',
}, stub)
vim.fn.setfperm(stub, 'rwxr-xr-x')
vim.fn.writefile({}, tmp .. '/fmclient.db')
vim.g.fmclient_cmd = stub
vim.g.fmclient_data = tmp

local fm = require('fmclient')
assert(fm.detect(true), 'client not detected')
assert(fm.open_layout(), 'layout did not open')

-- Protocol messages are hidden by default and the feed opens the echomail.
fm.open_echo('E')
local header = nil
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(buf) == 'fmclient://message/header' then header = buf end
end
assert(header, 'header buffer missing')
local lines = vim.api.nvim_buf_get_lines(header, 0, 10, false)
assert(lines[6] == 'Messages: 1 / new: 0', 'protocol message was not hidden: ' .. tostring(lines[6]))

-- Toggle shows it and the vote poster gets footer actions.
fm.toggle_protocols()
header = nil
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(buf) == 'fmclient://message/header' then header = buf end
end
lines = vim.api.nvim_buf_get_lines(header, 0, 10, false)
assert(lines[6] == 'Messages: 2 / new: 1', 'protocol message was not shown: ' .. tostring(lines[6]))
local all = vim.json.decode(table.concat(vim.fn.readfile(tmp .. '/messages.json'), ''))
fm.open_message(all[2])
local footer = nil
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(buf) == 'fmclient://message/footer' then footer = buf end
end
assert(footer, 'protocol footer missing')
local footer_lines = vim.api.nvim_buf_get_lines(footer, 0, -1, false)
assert(vim.tbl_contains(footer_lines, '1) yes'), 'vote variant button missing')
assert(vim.tbl_contains(footer_lines, '0) retract'), 'retract button missing')

-- The active protocols screen lists the poster and runs the action.
fm.open_protocols('E')
local work = nil
for _, buf in ipairs(vim.api.nvim_list_bufs()) do
  if vim.api.nvim_buf_get_name(buf) == 'fmclient://work' then work = buf end
end
assert(work, 'protocol screen buffer missing')
local work_lines = vim.api.nvim_buf_get_lines(work, 0, -1, false)
local found = false
for _, line in ipairs(work_lines) do
  if line:find('vote', 1, true) and line:find('Choose', 1, true) then found = true end
end
assert(found, 'active protocol line missing')
assert(vim.tbl_contains(work_lines, '   1) yes'), 'active protocol action missing')
local work_win = vim.api.nvim_get_current_win()
vim.api.nvim_win_set_cursor(work_win, { 3, 0 })
fm.run_action_for_cursor('1')
local logged = table.concat(vim.fn.readfile(actions_log), '\n')
assert(logged:find('vote cast E Choose yes', 1, true), 'vote action was not executed: ' .. logged)

print('fmclient nvim protocol UI: OK')
