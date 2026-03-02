-- yasio_socket_adapter.lua
-- 用 yasio 模拟 luasocket TCP 接口，供 LuaPanda 调试器使用

local yasio = require("yasio")

local M = {}

----------------------------------------------------------------------
-- 精确计时（秒），用于超时控制
----------------------------------------------------------------------
local function clock()
    return yasio.highp_clock() / 1000000000
end

----------------------------------------------------------------------
-- 轮询 dispatch 直到 cond() 返回 true 或超时
----------------------------------------------------------------------
local function poll_until(svc, cond, timeout)
    local t0 = clock()
    while true do
        svc:dispatch(128)
        if cond() then return true end
        if timeout and clock() - t0 >= timeout then return false end
    end
end

----------------------------------------------------------------------
-- TCP Client Socket
----------------------------------------------------------------------
local ClientSock = {}
ClientSock.__index = ClientSock

function ClientSock.new()
    return setmetatable({
        _svc     = nil,
        _tp      = nil,     -- transport handle
        _up      = false,   -- 是否已连接
        _buf     = "",      -- 接收缓冲区
        _timeout = 5,
    }, ClientSock)
end

function ClientSock:settimeout(sec)
    self._timeout = sec or 5
end

function ClientSock:connect(host, port)
    local svc = yasio.io_service({ host = host, port = port })
    local ct = math.max(math.ceil(self._timeout), 1)
    svc:set_option(yasio.YOPT_S_CONNECT_TIMEOUT, ct)
    self._svc = svc

    local result -- nil=pending, true=成功, false=失败
    local me = self

    svc:start(function(ev)
        local k = ev:kind()
        if k == yasio.YEK_ON_OPEN then
            if ev:status() == 0 then
                me._tp = ev:transport()
                me._up = true
                result = true
            else
                result = false
            end
        elseif k == yasio.YEK_ON_CLOSE then
            me._up = false
            me._tp = nil
        elseif k == yasio.YEK_ON_PACKET then
            local d = ev:packet(yasio.BUFFER_RAW)
            if d and #d > 0 then
                me._buf = me._buf .. d
            end
        end
    end)

    svc:open(0, yasio.YCK_TCP_CLIENT)

    if poll_until(svc, function() return result ~= nil end, self._timeout) and result then
        return 1
    end
    return nil, "connection refused"
end

function ClientSock:send(data)
    if not self._up or not self._tp then return nil, "closed" end
    self._svc:write(self._tp, data)
    return #data
end

function ClientSock:receive(pattern)
    -- LuaPanda 只使用 "*l" (读取一行直到 \n)
    if not self._up and self._buf == "" then return nil, "closed" end

    poll_until(self._svc, function()
        return self._buf:find("\n", 1, true) ~= nil or not self._up
    end, self._timeout)

    local p = self._buf:find("\n", 1, true)
    if p then
        local line = self._buf:sub(1, p - 1)
        self._buf = self._buf:sub(p + 1)
        return line
    end
    return nil, self._up and "timeout" or "closed"
end

function ClientSock:close()
    if self._svc then
        if self._tp then
            pcall(function() self._svc:close(self._tp) end)
        end
        pcall(function() self._svc:stop() end)
    end
    self._up  = false
    self._tp  = nil
    self._svc = nil
end

----------------------------------------------------------------------
-- TCP Server Socket
----------------------------------------------------------------------
local ServerSock = {}
ServerSock.__index = ServerSock

function ServerSock.new()
    return setmetatable({
        _svc     = nil,
        _timeout = 5,
        _state   = nil,  -- 共享状态表，回调和 accepted socket 共用
    }, ServerSock)
end

function ServerSock:settimeout(sec)
    self._timeout = sec or 5
end

function ServerSock:bind(host, port)
    self._svc = yasio.io_service({ host = host, port = port })
    return 1
end

function ServerSock:setoption(name, value)
    if name == "reuseaddr" and self._svc then
        self._svc:set_option(yasio.YOPT_C_MOD_FLAGS, 0, yasio.YCF_REUSEADDR, 0)
    end
end

function ServerSock:listen(backlog)
    local state = { tp = nil, up = false, buf = "" }
    self._state = state

    self._svc:start(function(ev)
        local k = ev:kind()
        if k == yasio.YEK_ON_OPEN and ev:status() == 0 then
            state.tp = ev:transport()
            state.up = true
        elseif k == yasio.YEK_ON_CLOSE then
            state.up = false
            state.tp = nil
        elseif k == yasio.YEK_ON_PACKET then
            local d = ev:packet(yasio.BUFFER_RAW)
            if d and #d > 0 then
                state.buf = state.buf .. d
            end
        end
    end)

    self._svc:open(0, yasio.YCK_TCP_SERVER)
    return 1
end

function ServerSock:accept()
    local state = self._state
    if not state then return nil end

    state.tp  = nil
    state.up  = false
    state.buf = ""

    if not poll_until(self._svc, function() return state.up end, self._timeout) then
        return nil
    end

    -- 返回一个兼容 luasocket 的 accepted socket
    -- 它和 server 共享同一个 io_service + 回调 state
    local accepted = {
        _svc     = self._svc,
        _state   = state,
        _timeout = self._timeout,
    }

    function accepted:settimeout(sec) self._timeout = sec or 5 end

    function accepted:send(data)
        if not self._state.up or not self._state.tp then return nil, "closed" end
        self._svc:write(self._state.tp, data)
        return #data
    end

    function accepted:receive(pattern)
        local st = self._state
        if not st.up and st.buf == "" then return nil, "closed" end

        poll_until(self._svc, function()
            return st.buf:find("\n", 1, true) ~= nil or not st.up
        end, self._timeout)

        local p = st.buf:find("\n", 1, true)
        if p then
            local line = st.buf:sub(1, p - 1)
            st.buf = st.buf:sub(p + 1)
            return line
        end
        return nil, st.up and "timeout" or "closed"
    end

    function accepted:close()
        if self._state.tp then
            pcall(function() self._svc:close(self._state.tp) end)
        end
        self._state.up = false
        self._state.tp = nil
    end

    return accepted
end

function ServerSock:close()
    if self._svc then
        pcall(function() self._svc:close(0) end)  -- 关闭监听 channel
        -- 注意：不调用 stop()，因为 accepted socket 还在用同一个 service
    end
end

----------------------------------------------------------------------
-- 工厂函数：模拟 require("socket.core").tcp()
-- 返回一个同时支持 client 和 server 操作的对象
----------------------------------------------------------------------
function M.tcp()
    local obj = {
        _client = ClientSock.new(),
        _server = nil,
        _mode   = nil,  -- "client" or "server"
        _timeout = 5,
    }

    local wrapper = {}

    function wrapper:settimeout(sec)
        obj._timeout = sec or 5
        if obj._client then obj._client:settimeout(sec) end
        if obj._server then obj._server:settimeout(sec) end
    end

    -- Client 方法
    function wrapper:connect(host, port)
        obj._mode = "client"
        obj._client:settimeout(obj._timeout)
        return obj._client:connect(host, port)
    end

    function wrapper:send(data)
        return obj._client:send(data)
    end

    function wrapper:receive(pattern)
        return obj._client:receive(pattern)
    end

    -- Server 方法
    function wrapper:bind(host, port)
        obj._mode = "server"
        obj._server = ServerSock.new()
        obj._server:settimeout(obj._timeout)
        return obj._server:bind(host, port)
    end

    function wrapper:setoption(name, value)
        if obj._server then obj._server:setoption(name, value) end
    end

    function wrapper:listen(backlog)
        if obj._server then return obj._server:listen(backlog) end
    end

    function wrapper:accept()
        if obj._server then
            obj._server:settimeout(obj._timeout)
            return obj._server:accept()
        end
    end

    function wrapper:close()
        if obj._mode == "client" then
            obj._client:close()
        elseif obj._mode == "server" then
            if obj._server then obj._server:close() end
        else
            obj._client:close()
        end
    end

    return wrapper
end

return M