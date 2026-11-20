-- Protocol helpers for the Neovim frontend: classification, active protocol
-- selection and action descriptors. Pure functions only, so they can be tested
-- headlessly without a running fmclient.
local M = {}

M.PROTOCOL_TYPES = {
  vote = true,
  election = true,
  excommunicate = true,
  appeal = true,
  change_policy = true,
  change_rules = true,
  remove_echo = true,
  merge = true,
  conflict = true,
  recover = true,
  refill = true,
  remote_subscribe = true,
}

M.ACTIVE_DAYS_LIMIT = 7

local function decode(msg)
  if type(msg) ~= 'table' or type(msg.data) ~= 'string' or msg.data == '' then return {} end
  local ok, value = pcall(vim.json.decode, msg.data)
  if not ok or type(value) ~= 'table' then return {} end
  return value
end
M.decode = decode

function M.is_protocol(msg)
  return type(msg) == 'table' and M.PROTOCOL_TYPES[msg.type] == true
end

local function recent(msg, now)
  local ts = tonumber(msg.timestamp) or 0
  if ts > 1e12 then ts = math.floor(ts / 1000) end
  return ts <= 0 or ts >= (now or os.time()) - M.ACTIVE_DAYS_LIMIT * 86400
end

local function result_for(msg, data, messages)
  local text = data.message or msg.message_id
  local state_key = data.protocol_data and data.protocol_data.state_key or data.state_key
  local phase = data.protocol_data and data.protocol_data.phase or data.phase
  for _, other in ipairs(messages or {}) do
    if other ~= msg and other.echo == msg.echo and other.type == msg.type then
      local d = decode(other)
      if d.type == 'result' then
        if d.poster_message and (d.poster_message == text or d.poster_message == msg.message_id) then
          return true
        end
        if state_key and d.state_key == state_key and (phase == nil or d.phase == nil or d.phase == phase) then
          return true
        end
        if d.originalMessageId and d.originalMessageId == msg.message_id then
          return true
        end
      end
      if d.type == 'cancel' and (d.original_message_id == msg.message_id or d.message == text) then
        return true
      end
    end
  end
  return false
end

local function add_actions(actions, data, msg, opts)
  local echo = msg.echo or data.echo or ''
  local variants = data.variants
  local poster = data.message or msg.message_id or ''
  if type(variants) == 'table' and #variants > 0 then
    local kind = 'vote'
    local pd = data.protocol_data or {}
    if data.protocol == 'merge' and pd.state_key then
      kind = 'merge'
    elseif data.protocol == 'change_policy' then
      kind = 'change_policy'
    elseif data.proto == 'excommunicate' then
      kind = 'excommunicate'
    end
    for i, variant in ipairs(variants) do
      if i > 9 then break end
      local action = { kind = kind, echo = echo, poster = poster, variant = variant }
      if kind == 'merge' then
        action.state_key = pd.state_key
        action.phase = pd.phase or 1
        action.chunk_index = pd.chunk_index
      elseif kind == 'excommunicate' then
        action.target = data.protoAddress or ''
      end
      table.insert(actions, { key = tostring(i), label = tostring(variant), action = action })
    end
    if kind == 'vote' or kind == 'change_policy' then
      table.insert(actions, { key = '0', label = 'retract', action = { kind = kind, echo = echo, poster = poster, variant = '' } })
    elseif kind == 'merge' then
      table.insert(actions, { key = '0', label = 'retract', action = { kind = 'merge', echo = echo, poster = poster,
        variant = '', state_key = pd.state_key, phase = pd.phase or 1, chunk_index = pd.chunk_index } })
    end
    return
  end

  if msg.type == 'election' and data.type == 'poster' then
    local identity = opts and opts.identity or {}
    local seen, candidates = {}, {}
    local function add(candidate)
      if type(candidate) == 'string' and candidate ~= '' and not seen[candidate] then
        seen[candidate] = true
        table.insert(candidates, candidate)
      end
    end
    for _, other in ipairs((opts and opts.messages) or {}) do
      if other.echo == msg.echo and other.type == 'election' then
        local d = decode(other)
        if d.type == 'vote' and type(d.to) == 'string' and d.to ~= '' then add(d.to) end
        if d.type == 'phase' and type(d.candidates) == 'table' then
          for _, candidate in ipairs(d.candidates) do add(candidate) end
        end
      end
    end
    for i, candidate in ipairs(candidates) do
      if i > 9 then break end
      table.insert(actions, { key = tostring(i), label = candidate, action = { kind = 'election', echo = echo, candidate = candidate } })
    end
    if identity.address and identity.address ~= '' then
      table.insert(actions, { key = 'A', label = 'apply', action = { kind = 'election', echo = echo, candidate = identity.address } })
    end
    table.insert(actions, { key = '0', label = 'retract', action = { kind = 'election_retract', echo = echo } })
    return
  end

  if msg.type == 'refill' and data.type == 'request' then
    local identity = opts and opts.identity or {}
    local refill = data.refill or {}
    if identity.is_admin and refill.from and refill.before then
      table.insert(actions, {
        key = 'R',
        label = 'respond',
        action = { kind = 'refill', echo = refill.echo or echo, to = refill.from, before = refill.before },
      })
    end
  end
end

function M.actions(msg, opts)
  local actions = {}
  if not M.is_protocol(msg) then return actions end
  local data = decode(msg)
  if data.type ~= 'poster' and msg.type ~= 'refill' then return actions end
  add_actions(actions, data, msg, opts)
  return actions
end

local function protocol_kind(msg, data)
  if msg.type == 'vote' then
    if data.protocol == 'merge' then return 'merge' end
    if data.protocol == 'change_policy' then return 'change_policy' end
    if data.protocol == 'appeal' then return 'appeal' end
    return 'vote'
  end
  return msg.type
end
M.protocol_kind = protocol_kind

function M.active(messages, opts)
  local now = os.time()
  local out = {}
  for _, msg in ipairs(messages or {}) do
    local data = decode(msg)
    local keep = false
    if M.is_protocol(msg) and recent(msg, now) then
      if msg.type == 'vote' then
        keep = data.type == 'poster' or data.type == 'result'
        if keep and data.type == 'poster' and result_for(msg, data, messages) then keep = false end
      elseif msg.type == 'election' then
        keep = data.type == 'poster' or data.type == 'result'
        if keep and data.type == 'poster' and result_for(msg, data, messages) then keep = false end
      elseif msg.type == 'refill' then
        if data.type == 'request' then
          keep = true
          local refill = data.refill or {}
          for _, other in ipairs(messages or {}) do
            local d = decode(other)
            if other.type == 'refill' and d.type == 'response' and d.refill
                and d.refill.messageId == refill.messageId then
              keep = false
              break
            end
          end
        end
      elseif msg.type == 'excommunicate' or msg.type == 'appeal'
          or msg.type == 'remove_echo' or msg.type == 'merge'
          or msg.type == 'conflict' or msg.type == 'recover' then
        keep = data.type == 'poster' or data.type == 'result'
        if keep and data.type == 'poster' and result_for(msg, data, messages) then keep = false end
      end
    end
    if keep then
      out[#out + 1] = { msg = msg, data = data, kind = protocol_kind(msg, data) }
    end
  end
  table.sort(out, function(a, b)
    return (a.msg.timestamp or 0) < (b.msg.timestamp or 0)
  end)
  return out
end

function M.format_line(item)
  local msg = item.msg or {}
  local data = item.data or {}
  local subject = data.subject or msg.subject or ''
  local author = msg.sender_address or data.from or '?'
  local echo = msg.echo or data.echo or ''
  return string.format('%s · %s · %s · %s', item.kind or msg.type or '?', echo, subject, author)
end

return M
