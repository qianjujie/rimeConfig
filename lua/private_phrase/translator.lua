local lib = require("private_phrase.lib")

local function translator(input, seg, env)
  local entries = lib.lookup(env, input)
  if entries then
    for _, entry in ipairs(entries) do
      yield(lib.make_candidate(input, seg, entry))
    end
    return
  end
end

return translator
