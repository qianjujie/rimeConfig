local M = {}

local function trim(s)
  return (s or ""):gsub("^\239\187\191", ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function split_tab(line)
  local fields = {}
  for field in (line .. "\t"):gmatch("([^\t]*)\t") do
    table.insert(fields, field)
  end
  return fields
end

local function sort_entries(entries)
  table.sort(entries, function(a, b)
    return a.weight > b.weight
  end)
end

local function parse_weight(s)
  local value = trim(s)
  if value == "" then
    return 100
  end
  return tonumber(value, 10) or 100
end

function M.load(env)
  if env.private_phrase_loaded then
    return
  end

  env.private_phrase_loaded = true
  env.private_phrase = {}

  local path = rime_api.get_user_data_dir() .. "/custom_phrase/private_phrase.txt"
  local file = io.open(path, "r")
  if not file then
    return
  end

  for raw_line in file:lines() do
    local line = trim(raw_line)
    if line ~= "" and line:sub(1, 1) ~= "#" then
      local fields = split_tab(line)
      local text = trim(fields[1])
      local trigger = trim(fields[2])
      local weight = parse_weight(fields[3])
      if text ~= "" and trigger ~= "" then
        env.private_phrase[trigger] = env.private_phrase[trigger] or {}
        table.insert(env.private_phrase[trigger], {
          text = text,
          trigger = trigger,
          weight = weight,
        })
      end
    end
  end

  file:close()

  for _, entries in pairs(env.private_phrase) do
    sort_entries(entries)
  end
end

function M.lookup(env, trigger)
  M.load(env)
  return env.private_phrase[trigger]
end

function M.is_numeric_trigger(env, input)
  M.load(env)
  return input:match("^%d+$") and env.private_phrase[input] ~= nil
end

function M.has_numeric_prefix(env, input)
  M.load(env)
  if input == "" or not input:match("^%d+$") then
    return false
  end

  for trigger, _ in pairs(env.private_phrase) do
    if trigger:match("^%d+$") and trigger:sub(1, #input) == input then
      return true
    end
  end

  return false
end

function M.make_candidate(input, seg, entry)
  local cand = Candidate("private_phrase", seg.start, seg._end, entry.text, "快捷")
  cand.quality = 1000000 + entry.weight
  return cand
end

return M
