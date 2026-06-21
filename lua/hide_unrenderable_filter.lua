local M = {}

local function single_codepoint(text)
    local first = nil
    local count = 0
    for _, codepoint in utf8.codes(text) do
        count = count + 1
        if count > 1 then
            return nil
        end
        first = codepoint
    end
    return first
end

local function should_hide(text)
    if text == "�" or text == "□" then
        return true
    end

    local codepoint = single_codepoint(text)
    if not codepoint then
        return false
    end

    -- Many CJK extension characters render as a boxed question mark in Squirrel.
    -- Keep BMP characters, including CJK Extension A; hide rarer planes.
    return codepoint > 0xffff
end

function M.func(input, env)
    for cand in input:iter() do
        if not should_hide(cand.text) then
            yield(cand)
        end
    end
end

return M
