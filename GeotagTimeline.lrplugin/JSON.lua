--
-- Minimal JSON encoder/decoder for the GeotagTimeline plugin.
-- Handles objects, arrays, strings, numbers, booleans, and null.
--

local JSON = {}

----------------------------------------------------------------
-- Encode
----------------------------------------------------------------

local encode_value -- forward declaration

local escape_map = {
    ['\\'] = '\\\\',
    ['"']  = '\\"',
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\t'] = '\\t',
    ['\b'] = '\\b',
    ['\f'] = '\\f',
}

local function encode_string(s)
    return '"' .. s:gsub('[\\"\n\r\t\b\f]', escape_map) .. '"'
end

local function encode_table(t)
    -- Determine if array: all keys are consecutive integers starting at 1
    local n = #t
    local isArray = true
    if n == 0 then
        -- Could be empty array or empty object; check for any keys
        if next(t) ~= nil then
            isArray = false
        end
    else
        local count = 0
        for _ in pairs(t) do count = count + 1 end
        if count ~= n then isArray = false end
    end

    if isArray then
        local parts = {}
        for i = 1, n do
            parts[i] = encode_value(t[i])
        end
        return '[' .. table.concat(parts, ',') .. ']'
    else
        local parts = {}
        for k, v in pairs(t) do
            parts[#parts + 1] = encode_string(tostring(k)) .. ':' .. encode_value(v)
        end
        return '{' .. table.concat(parts, ',') .. '}'
    end
end

encode_value = function(val)
    if val == nil then return 'null' end
    local t = type(val)
    if t == 'boolean' then return val and 'true' or 'false' end
    if t == 'number'  then
        if val ~= val then return 'null' end               -- NaN
        if val == math.huge or val == -math.huge then return 'null' end
        if val == math.floor(val) and math.abs(val) < 1e15 then
            return string.format('%d', val)
        end
        return string.format('%.17g', val)
    end
    if t == 'string' then return encode_string(val) end
    if t == 'table'  then return encode_table(val) end
    return 'null'
end

function JSON.encode(val)
    return encode_value(val)
end

----------------------------------------------------------------
-- Decode
----------------------------------------------------------------

local decode_value -- forward declaration

local function skip_ws(str, pos)
    local p = str:find('[^ \t\n\r]', pos)
    return p or (#str + 1)
end

local function decode_string(str, pos)
    -- pos is at the opening "
    local parts = {}
    local i = pos + 1
    while i <= #str do
        local c = str:sub(i, i)
        if c == '"' then
            return table.concat(parts), i + 1
        elseif c == '\\' then
            i = i + 1
            local esc = str:sub(i, i)
            if     esc == 'n'  then parts[#parts + 1] = '\n'
            elseif esc == 'r'  then parts[#parts + 1] = '\r'
            elseif esc == 't'  then parts[#parts + 1] = '\t'
            elseif esc == 'b'  then parts[#parts + 1] = '\b'
            elseif esc == 'f'  then parts[#parts + 1] = '\f'
            elseif esc == '"'  then parts[#parts + 1] = '"'
            elseif esc == '\\' then parts[#parts + 1] = '\\'
            elseif esc == '/'  then parts[#parts + 1] = '/'
            elseif esc == 'u'  then
                local hex = str:sub(i + 1, i + 4)
                local code = tonumber(hex, 16)
                if code and code < 128 then
                    parts[#parts + 1] = string.char(code)
                else
                    parts[#parts + 1] = '\\u' .. hex
                end
                i = i + 4
            end
        else
            parts[#parts + 1] = c
        end
        i = i + 1
    end
    error('JSON: unterminated string')
end

local function decode_number(str, pos)
    local s = str:match('^-?%d+%.%d+[eE][%+%-]?%d+', pos)
           or str:match('^-?%d+[eE][%+%-]?%d+', pos)
           or str:match('^-?%d+%.%d+', pos)
           or str:match('^-?%d+', pos)
    if not s then error('JSON: invalid number at position ' .. pos) end
    return tonumber(s), pos + #s
end

local function decode_object(str, pos)
    local result = {}
    pos = skip_ws(str, pos + 1) -- skip {
    if str:sub(pos, pos) == '}' then return result, pos + 1 end

    while true do
        pos = skip_ws(str, pos)
        if str:sub(pos, pos) ~= '"' then
            error('JSON: expected string key at position ' .. pos)
        end
        local key
        key, pos = decode_string(str, pos)

        pos = skip_ws(str, pos)
        if str:sub(pos, pos) ~= ':' then
            error('JSON: expected ":" at position ' .. pos)
        end
        pos = skip_ws(str, pos + 1)

        local val
        val, pos = decode_value(str, pos)
        result[key] = val

        pos = skip_ws(str, pos)
        local c = str:sub(pos, pos)
        if c == '}' then return result, pos + 1 end
        if c ~= ',' then error('JSON: expected "," or "}" at position ' .. pos) end
        pos = pos + 1
    end
end

local function decode_array(str, pos)
    local result = {}
    pos = skip_ws(str, pos + 1) -- skip [
    if str:sub(pos, pos) == ']' then return result, pos + 1 end

    while true do
        pos = skip_ws(str, pos)
        local val
        val, pos = decode_value(str, pos)
        result[#result + 1] = val

        pos = skip_ws(str, pos)
        local c = str:sub(pos, pos)
        if c == ']' then return result, pos + 1 end
        if c ~= ',' then error('JSON: expected "," or "]" at position ' .. pos) end
        pos = pos + 1
    end
end

decode_value = function(str, pos)
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == '"' then return decode_string(str, pos) end
    if c == '{' then return decode_object(str, pos) end
    if c == '[' then return decode_array(str, pos) end
    if str:sub(pos, pos + 3) == 'true'  then return true,  pos + 4 end
    if str:sub(pos, pos + 4) == 'false' then return false, pos + 5 end
    if str:sub(pos, pos + 3) == 'null'  then return nil,   pos + 4 end
    if c == '-' or (c >= '0' and c <= '9') then return decode_number(str, pos) end
    error('JSON: unexpected character at position ' .. pos .. ': ' .. c)
end

function JSON.decode(str)
    if not str or str == '' then error('JSON: empty input') end
    local val = decode_value(str, 1)
    return val
end

return JSON
