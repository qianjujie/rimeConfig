local rime = require("sbxlm.lib")
local lib = require("private_phrase.lib")
local M = {}

function M.func(key_event, env)
  if key_event:release() or key_event:alt() or key_event:ctrl() or key_event:super() or key_event:caps() then
    return rime.process_results.kNoop
  end

  local key = key_event:repr()
  local context = env.engine.context
  local input = context.input or ""

  if key:match("^%d$") then
    if input == "" then
      if lib.has_numeric_prefix(env, key) then
        context:push_input(key)
        return rime.process_results.kAccepted
      end
      return rime.process_results.kNoop
    end

    if input:match("^%d+$") then
      local next_input = input .. key
      if lib.is_numeric_trigger(env, input) or not lib.has_numeric_prefix(env, next_input) then
        env.engine:commit_text(next_input)
        context:clear()
        return rime.process_results.kAccepted
      end

      context:push_input(key)
      return rime.process_results.kAccepted
    end
  end

  if input:match("^%d+$") then
    if key == "Return" or key == "KP_Enter" then
      env.engine:commit_text(input)
      context:clear()
      return rime.process_results.kAccepted
    end

    if lib.is_numeric_trigger(env, input) and (key == "space" or key == "Tab") then
      local entries = lib.lookup(env, input)
      if entries and entries[1] then
        env.engine:commit_text(entries[1].text)
        context:clear()
        return rime.process_results.kAccepted
      end
    end

    if #key == 1 then
      env.engine:commit_text(input .. key)
      context:clear()
      return rime.process_results.kAccepted
    end
  end

  if key ~= "Tab" then
    return rime.process_results.kNoop
  end

  local cand = context:get_selected_candidate()
  if not cand then
    return rime.process_results.kNoop
  end

  local entries = lib.lookup(env, cand.text)
  if entries and entries[1] then
    env.engine:commit_text(entries[1].text)
    context:clear()
    return rime.process_results.kAccepted
  end

  return rime.process_results.kNoop
end

return M
