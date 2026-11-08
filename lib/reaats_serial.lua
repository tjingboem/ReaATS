-- reaats_serial.lua -- the tool's OWN save format for the ReaSnap Integration Contract (piece 1).
-- A safe table serializer (no load(): a hand-written parser that can never run code). Taken from
-- ReaSnap's doc/ReaSnap_Serializer_Template.lua (which was extracted from ReaMaskM) with the tool name
-- replaced. Self-contained: it works the same whether or not ReaSnap is installed.

local ReaATS_Serial = (function()
    local M = {}

    local function is_array(t)
        local n = 0
        for _ in pairs(t) do n = n + 1 end
        for i = 1, n do
            if t[i] == nil then return false, n end
        end
        return true, n
    end

    local function encode_string(s)
        return string.format("%q", s)
    end

    local function encode_number(n)
        if n ~= n then return "0/0" end
        if n == math.huge then return "1/0" end
        if n == -math.huge then return "-1/0" end
        return string.format("%.17g", n)
    end

    local encode_value

    local function encode_table(t, seen)
        seen = seen or {}
        if seen[t] then
            error("ReaATS_Serial.encode: cannot serialize a table with a cycle")
        end
        seen[t] = true

        local arr, n = is_array(t)
        local parts = {}

        if arr then
            for i = 1, n do
                parts[#parts + 1] = encode_value(t[i], seen)
            end
        else
            local keys = {}
            for k in pairs(t) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b)
                local ta, tb = type(a), type(b)
                if ta ~= tb then return ta < tb end
                return tostring(a) < tostring(b)
            end)
            for _, k in ipairs(keys) do
                local v = t[k]
                local key_str
                if type(k) == "string" and k:match("^[%a_][%w_]*$") then
                    key_str = k
                else
                    key_str = "[" .. encode_value(k, seen) .. "]"
                end
                parts[#parts + 1] = key_str .. "=" .. encode_value(v, seen)
            end
        end

        seen[t] = nil
        return "{" .. table.concat(parts, ",") .. "}"
    end

    encode_value = function(v, seen)
        local t = type(v)
        if t == "nil" then
            return "nil"
        elseif t == "boolean" then
            return tostring(v)
        elseif t == "number" then
            return encode_number(v)
        elseif t == "string" then
            return encode_string(v)
        elseif t == "table" then
            return encode_table(v, seen)
        else
            error("ReaATS_Serial.encode: unsupported type " .. t)
        end
    end

    function M.encode(value)
        return encode_value(value, {})
    end

    local Parser = {}
    Parser.__index = Parser

    local function new_parser(str)
        return setmetatable({ s = str, pos = 1, len = #str }, Parser)
    end

    function Parser:peek()
        return self.s:sub(self.pos, self.pos)
    end

    function Parser:skip_ws()
        while self.pos <= self.len do
            local c = self:peek()
            if c == " " or c == "\t" or c == "\n" or c == "\r" then
                self.pos = self.pos + 1
            else
                break
            end
        end
    end

    function Parser:error(msg)
        error(string.format("ReaATS_Serial.decode: %s at position %d (near %q)",
            msg, self.pos, self.s:sub(math.max(1, self.pos - 10), self.pos + 10)))
    end

    function Parser:expect(ch)
        if self:peek() ~= ch then
            self:error("expected '" .. ch .. "'")
        end
        self.pos = self.pos + 1
    end

    function Parser:parse_string()
        self:expect('"')
        local out = {}
        while true do
            if self.pos > self.len then self:error("unterminated string") end
            local c = self.s:sub(self.pos, self.pos)
            if c == '"' then
                self.pos = self.pos + 1
                break
            elseif c == "\\" then
                local nxt = self.s:sub(self.pos + 1, self.pos + 1)
                if nxt == "n" then out[#out + 1] = "\n"; self.pos = self.pos + 2
                elseif nxt == "t" then out[#out + 1] = "\t"; self.pos = self.pos + 2
                elseif nxt == "r" then out[#out + 1] = "\r"; self.pos = self.pos + 2
                elseif nxt == '"' then out[#out + 1] = '"'; self.pos = self.pos + 2
                elseif nxt == "\\" then out[#out + 1] = "\\"; self.pos = self.pos + 2
                elseif nxt == "\n" then out[#out + 1] = "\n"; self.pos = self.pos + 2
                elseif nxt:match("%d") then
                    local digits = self.s:sub(self.pos + 1, self.pos + 3):match("^(%d%d?%d?)")
                    out[#out + 1] = string.char(tonumber(digits))
                    self.pos = self.pos + 1 + #digits
                else
                    self:error("unknown escape \\" .. nxt)
                end
            else
                out[#out + 1] = c
                self.pos = self.pos + 1
            end
        end
        return table.concat(out)
    end

    function Parser:parse_number()
        local rest = self.s:sub(self.pos)
        local inf = rest:match("^%-?1/0")
        if inf then
            self.pos = self.pos + #inf
            return inf == "1/0" and math.huge or -math.huge
        end
        local nan = rest:match("^0/0")
        if nan then
            self.pos = self.pos + #nan
            return 0 / 0
        end
        local num = rest:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*")
        if not num or num == "" then self:error("expected number") end
        self.pos = self.pos + #num
        local n = tonumber(num)
        if not n then self:error("malformed number literal " .. num) end
        return n
    end

    function Parser:parse_identifier()
        local rest = self.s:sub(self.pos)
        local id = rest:match("^[%a_][%w_]*")
        if not id then self:error("expected identifier") end
        self.pos = self.pos + #id
        return id
    end

    local parse_value

    function Parser:parse_table()
        self:expect("{")
        local t = {}
        local arr_idx = 1
        self:skip_ws()
        if self:peek() == "}" then
            self.pos = self.pos + 1
            return t
        end
        while true do
            self:skip_ws()
            local c = self:peek()
            local key
            if c == "[" then
                self.pos = self.pos + 1
                self:skip_ws()
                key = parse_value(self)
                self:skip_ws()
                self:expect("]")
                self:skip_ws()
                self:expect("=")
                self:skip_ws()
                t[key] = parse_value(self)
            elseif c:match("[%a_]") then
                local save = self.pos
                local id = self:parse_identifier()
                self:skip_ws()
                if self:peek() == "=" then
                    self.pos = self.pos + 1
                    self:skip_ws()
                    t[id] = parse_value(self)
                else
                    self.pos = save
                    t[arr_idx] = parse_value(self)
                    arr_idx = arr_idx + 1
                end
            else
                t[arr_idx] = parse_value(self)
                arr_idx = arr_idx + 1
            end
            self:skip_ws()
            local sep = self:peek()
            if sep == "," then
                self.pos = self.pos + 1
                self:skip_ws()
                if self:peek() == "}" then
                    self.pos = self.pos + 1
                    break
                end
            elseif sep == "}" then
                self.pos = self.pos + 1
                break
            else
                self:error("expected ',' or '}'")
            end
        end
        return t
    end

    parse_value = function(p)
        p:skip_ws()
        local c = p:peek()
        if c == "{" then
            return p:parse_table()
        elseif c == '"' then
            return p:parse_string()
        elseif c == "-" or c:match("%d") then
            return p:parse_number()
        elseif c == "t" and p.s:sub(p.pos, p.pos + 3) == "true" then
            p.pos = p.pos + 4
            return true
        elseif c == "f" and p.s:sub(p.pos, p.pos + 4) == "false" then
            p.pos = p.pos + 5
            return false
        elseif c == "n" and p.s:sub(p.pos, p.pos + 2) == "nil" then
            p.pos = p.pos + 3
            return nil
        else
            p:error("unexpected character '" .. c .. "'")
        end
    end

    function M.decode(str)
        local p = new_parser(str)
        local v = parse_value(p)
        p:skip_ws()
        if p.pos <= p.len then
            p:error("trailing data after top-level value")
        end
        return v
    end

    return M
end)()

local function serialize_table(t)
    return ReaATS_Serial.encode(t)
end

local function deserialize_table(str)
    local ok, result = pcall(ReaATS_Serial.decode, str)
    if ok then
        return result
    else
        reaper.ShowConsoleMsg("[ReaATS] Deserialize error: " .. tostring(result) .. "\n")
        return nil
    end
end

return { serialize = serialize_table, deserialize = deserialize_table }
