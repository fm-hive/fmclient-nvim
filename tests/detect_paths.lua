-- Run from the repository root:
--   nvim --headless -u NONE --cmd 'set rtp+=.' -c 'luafile fmclient-nvim/tests/detect_paths.lua' -c qa!
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.rtp:append(root)

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. '/data', 'p')
vim.fn.mkdir(tmp .. '/elsewhere', 'p')
local stub = tmp .. '/fmclient'
vim.fn.writefile({
  '#!/bin/sh',
  'case "$*" in',
  '  *"policy show --json"*) printf \'%s\\n\' \'{"address":":0:1","name":"Tester"}\' ;;',
  '  *"identity --json"*) printf \'%s\\n\' \'{"address":":0:1"}\' ;;',
  '  *) exit 0 ;;',
  'esac',
}, stub)
vim.fn.setfperm(stub, 'rwxr-xr-x')
vim.fn.writefile({}, tmp .. '/data/fmclient.db')

vim.env.PWD = tmp
vim.cmd('cd ' .. vim.fn.fnamemodify(tmp .. '/elsewhere', ':p'))
local fm = require('fmclient')
local found = fm.detect(true)
assert(found, 'launch directory was not detected after cwd changed')
assert(found.cmd == stub, 'unexpected command: ' .. tostring(found.cmd))
assert(found.data == tmp .. '/data', 'unexpected data dir: ' .. tostring(found.data))

vim.g.fmclient_data = './data'
local relative = fm.detect(true)
assert(relative and relative.data == tmp .. '/data', 'relative g:fmclient_data must use launch directory')
vim.g.fmclient_data = nil

vim.env.PWD = tmp .. '/elsewhere'
vim.fn.writefile({ 'note' }, tmp .. '/note.txt')
vim.cmd('edit ' .. vim.fn.fnamemodify(tmp .. '/note.txt', ':p'))
local buffered = fm.detect(true)
assert(buffered and buffered.data == tmp .. '/data', 'buffer directory fallback failed')

print('fmclient detect paths: ok')
