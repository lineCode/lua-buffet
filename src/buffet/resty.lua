local error = error
local select = select
local setmetatable = setmetatable
local tonumber = tonumber
local tostring = tostring
local type = type

local math_floor = math.floor

local str_find = string.find
local str_format = string.format
local str_gsub = string.gsub
local str_sub = string.sub

local table_concat = table.concat
local table_insert = table.insert

local ERR_CLOSED = 'closed'
local ERR_RECEIVE_BAD_PATTERN = "bad argument #2 to 'receive' (bad pattern argument)"

local _M = {}

local mt = {}
mt.__index = mt

local _get_table_iterator = function(tbl)
    local index = 0
    return function()
        index = index + 1
        return tbl[index]
    end
end

local _get_chunk = function(bf)
    local chunk = bf._chunk
    if chunk then
        bf._chunk = nil
        return chunk
    end
    local iterator = bf._iterator
    if not iterator then
        return nil
    end
    while true do
        local chunk, err = iterator()   -- luacheck: ignore 421
        if not chunk then
            if err then
                bf._iterator_error = err
            end
            return nil
        elseif chunk ~= '' then
            return chunk
        end
    end
end

local _store_chunk = function(bf, chunk)
    if bf._chunk then
        return error('buffet already has a chunk', 0)
    end
    if chunk == '' then
        return
    end
    bf._chunk = chunk
end

local _remove_cr = function(str)
    str = str_gsub(str, '\r', '')
    return str
end

local _receive_line = function(bf)
    if bf._closed then
        return nil, ERR_CLOSED
    end
    local buffer = {}
    while true do
        local chunk = _get_chunk(bf)
        if not chunk then
            bf:close()
            return nil, ERR_CLOSED, _remove_cr(table_concat(buffer))
        end
        local lf_at = str_find(chunk, '\n', 1, true)
        if lf_at then
            table_insert(buffer, str_sub(chunk, 1, lf_at - 1))
            _store_chunk(bf, str_sub(chunk, lf_at + 1))
            return _remove_cr(table_concat(buffer))
        end
        table_insert(buffer, chunk)
    end
end

local _receive_all = function(bf)
    if bf._closed then
        return ''
    end
    local buffer = {}
    while true do
        local chunk = _get_chunk(bf)
        if not chunk then
            break
        end
        table_insert(buffer, chunk)
    end
    bf:close()
    return table_concat(buffer)
end

local _receive_size = function(bf, size)
    if bf._closed then
        return nil, ERR_CLOSED
    end
    size = math_floor(size)
    if size < 0 then
        return error(ERR_RECEIVE_BAD_PATTERN, 0)
    elseif size == 0 then
        return ''
    end
    local have_bytes = 0
    local buffer = {}
    while true do
        local chunk = _get_chunk(bf)
        if not chunk then
            bf:close()
            return nil, ERR_CLOSED, table_concat(buffer)
        end
        have_bytes = have_bytes + #chunk
        if have_bytes == size then
            table_insert(buffer, chunk)
            return table_concat(buffer)
        elseif have_bytes > size then
            _store_chunk(bf, str_sub(chunk, size - have_bytes))
            table_insert(buffer, str_sub(chunk, 1, size - have_bytes - 1))
            return table_concat(buffer)
        end
        table_insert(buffer, chunk)
    end
end

mt.receive = function(self, ...)
    if select('#', ...) == 0 then
        return _receive_line(self)
    end
    local pattern = ...
    local pattern_type = type(pattern)
    if pattern_type == 'string' then
        if pattern == '*l' then
            return _receive_line(self)
        elseif pattern == '*a' then
            return _receive_all(self)
        else
            pattern = tonumber(pattern)
            if not pattern then
                return error(ERR_RECEIVE_BAD_PATTERN, 0)
            end
            return _receive_size(self, pattern)
        end
    elseif pattern_type == 'number' then
        return _receive_size(self, pattern)
    end
    return error(ERR_RECEIVE_BAD_PATTERN, 0)
end

local _find_pattern = function(str, pattern, search_start, search_stop)
    if search_stop and #str > search_stop then
        str = str_sub(str, 1, search_stop)
    end
    return str_find(str, pattern, search_start, true)
end

local _receive_until = function(bf, pattern, inclusive, size)
    local pattern_len = #pattern
    local search_stop = nil
    if size then
        search_stop = size + pattern_len - 1
    end
    local buffer = ''
    while true do
        local chunk = _get_chunk(bf)
        if not chunk then
            if size and #buffer > size then
                _store_chunk(bf, str_sub(buffer, size + 1))
                return str_sub(buffer, 1, size), false, false
            end
            return buffer, true, false
        end
        local search_start = #buffer - pattern_len
        if search_start < 1 then
            search_start = 1
        end
        buffer = buffer .. chunk
        local pattern_start, pattern_stop = _find_pattern(buffer, pattern, search_start, search_stop)
        if pattern_start then
            if #buffer > pattern_stop then
                _store_chunk(bf, str_sub(buffer, pattern_stop + 1))
            end
            local stop
            if inclusive then
                stop = pattern_stop
            else
                stop = pattern_start - 1
            end
            return str_sub(buffer, 1, stop), false, true
        end
        if search_stop and #buffer > search_stop then
            _store_chunk(bf, str_sub(buffer, size + 1))
            return str_sub(buffer, 1, size), false, false
        end
    end
end

local _normalize_receivenutil_iterator_size_arg = function(...)
    if select('#', ...) == 0 then
        return nil
    end
    local size = ...
    local size_type = type(size)
    if size_type == 'string' then
        size = tonumber(size)
        if size then
            size_type = 'number'
        end
    end
    if size_type ~= 'number' then
        return error(str_format(
            'bad argument #1 to iterator (number expected, got %s)', size_type), 0)
    end
    if size <= 0 then
        return nil
    end
    return math_floor(size)
end

local _get_receivenutil_iterator = function(bf, pattern, inclusive)
    local emit_nil_on_next_call = false
    return function(...)
        if bf._closed then
            return nil, ERR_CLOSED
        end
        if emit_nil_on_next_call then
            emit_nil_on_next_call = false
            return nil, nil, nil
        end
        local size = _normalize_receivenutil_iterator_size_arg(...)
        local data, done, found = _receive_until(bf, pattern, inclusive, size)
        if size and found then
            emit_nil_on_next_call = true
        end
        if not done then
            return data
        end
        bf:close()
        return nil, ERR_CLOSED, data
    end
end

mt.receiveuntil = function(self, ...)
    if self._closed then
        return nil, ERR_CLOSED
    end
    local args_count = select('#', ...)
    local options = nil
    local pattern
    if args_count == 1 then
        pattern = ...
    elseif args_count == 2 then
        pattern, options = ...
        if type(options) ~= 'table' then
            return error(str_format(
                "bad argument #3 to 'receiveuntil' (table expected, got %s)", type(options)), 0)
        end
    else
        return error(str_format(
            'expecting 2 or 3 arguments (including the object), but got %d', args_count + 1), 0)
    end
    local inclusive = false
    if options then
        inclusive = options.inclusive
        if type(inclusive) ~= 'boolean' then
            return error(str_format('bad "inclusive" option value type: %s', type(inclusive)), 0)
        end
    end
    local pattern_type = type(pattern)
    if pattern_type == 'number' then
        pattern = tostring(pattern)
    elseif pattern_type ~= 'string' then
        return error(str_format(
            "bad argument #2 to 'receiveuntil' (string expected, got %s)", pattern_type), 0)
    end
    if pattern == '' then
        return nil, 'pattern is empty'
    end
    return _get_receivenutil_iterator(self, pattern, inclusive)
end

mt.close = function(self)
    if self._closed then
        return nil, ERR_CLOSED
    end
    self._closed = true
    self._iterator = nil
    self._chunk = nil
    return 1
end

_M.new = function(data)
    local iterator = nil
    local chunk = nil
    local data_type = type(data)
    if data_type == 'function' then
        iterator = data
    elseif data_type == 'table' then
        iterator = _get_table_iterator(data)
    elseif data_type == 'string' then
        chunk = data
    else
        return nil, str_format('argument #1 must be string, table, or function, got: %s', data_type)
    end
    return setmetatable({
        _closed = false,
        _iterator = iterator,
        _chunk = chunk,
    }, mt)
end

return _M
