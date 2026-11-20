-- Run from the repository root:
--   nvim --headless -u NONE --cmd 'set rtp+=.' -c 'luafile fmclient-nvim/tests/protocols.lua' -c qa!
local source = debug.getinfo(1, 'S').source:sub(2)
local root = vim.fn.fnamemodify(source, ':p:h:h')
vim.opt.rtp:append(root)

local protocols = require('fmclient.protocols')

local function msg(overrides)
  local m = {
    message_id = 'm1',
    type = 'vote',
    echo = 'E',
    sender_address = ':0:2',
    timestamp = os.time(),
    data = '{}',
  }
  for k, v in pairs(overrides or {}) do m[k] = v end
  if type(m.data) ~= 'string' then m.data = vim.json.encode(m.data) end
  return m
end

assert(protocols.is_protocol({ type = 'vote' }), 'vote must be a protocol')
assert(protocols.is_protocol({ type = 'election' }), 'election must be a protocol')
assert(not protocols.is_protocol({ type = 'echomail' }), 'echomail is not a protocol')

local poster = msg({
  data = {
    proto = 'vote', type = 'poster', message = 'Choose', variants = { 'yes', 'no' },
  },
})
local actions = protocols.actions(poster, { identity = { address = ':0:1' }, messages = { poster } })
assert(#actions == 3, 'vote poster must have two variants and retract')
assert(actions[1].key == '1' and actions[1].action.variant == 'yes', 'vote variant 1 missing')
assert(actions[3].key == '0' and actions[3].action.variant == '', 'vote retract missing')

local excomm = msg({
  type = 'excommunicate',
  data = {
    proto = 'excommunicate', type = 'poster', message = 'Bad node', protoAddress = ':0:9',
    variants = { 'excommunicate', 'read-only' },
  },
})
actions = protocols.actions(excomm, { identity = { address = ':0:1' }, messages = { excomm } })
assert(actions[1].action.kind == 'excommunicate', 'excommunicate action kind wrong')
assert(actions[1].action.target == ':0:9', 'excommunicate target missing')

local election = msg({
  type = 'election',
  data = { proto = 'election', type = 'poster', message = 'Election' },
})
local vote_for = msg({
  type = 'election',
  message_id = 'm2',
  data = { proto = 'election', type = 'vote', to = ':0:3' },
})
actions = protocols.actions(election, {
  identity = { address = ':0:1' },
  messages = { election, vote_for },
})
local has_candidate, has_apply, has_retract = false, false, false
for _, a in ipairs(actions) do
  if a.action.kind == 'election' and a.action.candidate == ':0:3' then has_candidate = true end
  if a.action.kind == 'election' and a.action.candidate == ':0:1' then has_apply = true end
  if a.action.kind == 'election_retract' then has_retract = true end
end
assert(has_candidate and has_apply and has_retract, 'election actions incomplete')

local merge = msg({
  data = {
    proto = 'vote', type = 'poster', protocol = 'merge', message = 'Merge chunk',
    variants = { 'accept', 'reject' },
    protocol_data = { state_key = 'merge::x', phase = 1, chunk_index = 2 },
  },
})
actions = protocols.actions(merge, { identity = { address = ':0:1' }, messages = { merge } })
assert(actions[1].action.kind == 'merge', 'merge action kind wrong')
assert(actions[1].action.state_key == 'merge::x' and actions[1].action.chunk_index == 2, 'merge metadata missing')

local policy = msg({
  data = {
    proto = 'vote', type = 'poster', protocol = 'change_policy', message = 'Policy chunk',
    variants = { 'accept', 'reject' }, protocol_data = { state_key = 'policy::x', chunk_index = 1 },
  },
})
actions = protocols.actions(policy, { identity = { address = ':0:1' }, messages = { policy } })
assert(actions[1].action.kind == 'change_policy', 'change_policy action kind wrong')

local refill = msg({
  type = 'refill',
  data = {
    proto = 'refill', type = 'request', echo = 'E',
    refill = { from = ':0:2', echo = 'E', before = '2026-01-01T00:00:00Z', messageId = 'r1' },
  },
})
actions = protocols.actions(refill, { identity = { address = ':0:1', is_admin = true }, messages = { refill } })
assert(#actions == 1 and actions[1].action.kind == 'refill', 'refill response action missing')
actions = protocols.actions(refill, { identity = { address = ':0:1', is_admin = false }, messages = { refill } })
assert(#actions == 0, 'non-admin must not see refill response')

local result = msg({
  message_id = 'result1',
  data = { proto = 'vote', type = 'result', poster_message = 'Choose', result = 'success' },
})
local active = protocols.active({ poster, result }, { identity = {} })
assert(#active == 1 and active[1].msg.message_id == 'result1', 'resolved vote poster must leave the active list')

local unresolved = msg({ message_id = 'm3', data = { proto = 'vote', type = 'poster', message = 'Open', variants = { 'yes', 'no' } } })
active = protocols.active({ unresolved }, { identity = {} })
assert(#active == 1 and active[1].kind == 'vote', 'unresolved vote poster must stay active')

print('fmclient nvim protocols: OK')
