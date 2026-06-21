local lib = require("private_phrase.lib")
local M = {}

local function private_hint(entries)
  if not entries or not entries[1] then
    return nil
  end
  return entries[1].text
end

local function utf8_ellipsis(text, limit)
  if utf8.len(text) <= limit then
    return text
  end

  local end_pos = utf8.offset(text, limit + 1)
  if not end_pos then
    return text
  end
  return text:sub(1, end_pos - 1) .. ".."
end

function M.func(input, env)
  local private_cands = {}
  local normal_cands = {}
  local seen_private = {}
  local seen_normal = {}

  for cand in input:iter() do
    if seen_private[cand.text] or seen_normal[cand.text] then
      goto continue
    end

    local entries = lib.lookup(env, cand.text)
    local hint = private_hint(entries)
    if hint and hint ~= cand.text then
      local comment = utf8_ellipsis(hint, 2)
      local gcand = cand:get_genuine()
      if gcand then
        gcand.comment = comment
      end
      cand.comment = comment
      table.insert(private_cands, cand)
      seen_private[cand.text] = true
    else
      table.insert(normal_cands, cand)
      seen_normal[cand.text] = true
    end

    ::continue::
  end

  for _, cand in ipairs(private_cands) do
    yield(cand)
  end

  for _, cand in ipairs(normal_cands) do
    yield(cand)
  end
end

return M
