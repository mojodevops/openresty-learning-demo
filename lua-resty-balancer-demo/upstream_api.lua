-- upstream_api.lua
local _M = {}

local upstream = require "ngx.upstream"
local balancer = require "ngx.balancer"
local cjson = require "cjson"
local state_dict = ngx.shared.upstream_state

-- Helper function to validate upstream name
local function validate_upstream(upstream_name)
    local upstreams = upstream.get_upstreams()
    for _, up in ipairs(upstreams) do
        if up == upstream_name then
            return true
        end
    end
    return false
end

-- Helper to get server index by address
local function find_server_index(upstream_name, server_address)
    local servers = upstream.get_servers(upstream_name)
    for i, server in ipairs(servers) do
        local server_addr = server.addr
        if server.name then
            server_addr = server.name
        end
        if server_addr == server_address then
            return i
        end
    end
    return nil
end

-- JSON response helper
local function json_response(status, data)
    ngx.status = status
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode(data))
    return ngx.exit(status)
end

-- Get all servers in an upstream
local function get_servers(upstream_name)
    -- Validate upstream exists
    if not validate_upstream(upstream_name) then
        return json_response(404, {
            error = "Upstream not found"
        })
    end

    local servers = upstream.get_servers(upstream_name)
    local result = {}

    for i, server in ipairs(servers) do
        local server_addr = server.addr
        if server.name then
            server_addr = server.name
        end

        -- Get current state from shared dict
        local state_key = upstream_name .. ":" .. server_addr
        local is_disabled = state_dict:get(state_key .. ":disabled") or false
        local current_weight = state_dict:get(state_key .. ":weight") or server.weight

        table.insert(result, {
            address = server_addr,
            weight = current_weight,
            max_fails = server.max_fails,
            fail_timeout = server.fail_timeout,
            is_backup = server.backup or false,
            is_disabled = is_disabled
        })
    end

    return json_response(200, {
        servers = result
    })
end
-- 修复后的禁用服务器函数
local function disable_server(upstream_name, server_address)
    -- 验证 upstream 和 server
    if not validate_upstream(upstream_name) then
        return json_response(404, {
            error = "Upstream not found"
        })
    end

    local idx = find_server_index(upstream_name, server_address)
    if not idx then
        return json_response(404, {
            error = "Server not found in upstream"
        })
    end

    local state_key = upstream_name .. ":" .. server_address

    -- 使用 lua-upstream-nginx-module 更新状态
    local ok, err = upstream.set_peer_down(upstream_name, false, idx, true)
    if not ok then
        return json_response(500, {
            error = "Failed to disable server with lua-upstream: " .. (err or "unknown error")
        })
    end

    -- 更新共享状态
    state_dict:set(state_key .. ":disabled", true)

    -- 同时更新动态负载均衡器
    local dynamic_balancer = require "dynamic_balancer"
    local balancer_ok = dynamic_balancer.disable_server(upstream_name, server_address)
    if not balancer_ok then
        ngx.log(ngx.WARN, "Failed to disable server in balancer")
        -- 继续执行，不返回错误
    end

    return json_response(200, {
        success = true,
        message = "Server disabled"
    })
end

-- 修复后的启用服务器函数
local function enable_server(upstream_name, server_address)
    -- 验证 upstream 和 server
    if not validate_upstream(upstream_name) then
        return json_response(404, {
            error = "Upstream not found"
        })
    end

    local idx = find_server_index(upstream_name, server_address)
    if not idx then
        return json_response(404, {
            error = "Server not found in upstream"
        })
    end

    local state_key = upstream_name .. ":" .. server_address

    -- 使用 lua-upstream-nginx-module 更新状态
    local ok, err = upstream.set_peer_down(upstream_name, false, idx, false)
    if not ok then
        return json_response(500, {
            error = "Failed to enable server with lua-upstream: " .. (err or "unknown error")
        })
    end

    -- 更新共享状态
    state_dict:set(state_key .. ":disabled", false)

    -- 同时更新动态负载均衡器
    local dynamic_balancer = require "dynamic_balancer"
    local balancer_ok = dynamic_balancer.enable_server(upstream_name, server_address)
    if not balancer_ok then
        ngx.log(ngx.WARN, "Failed to enable server in balancer")
        -- 继续执行，不返回错误
    end

    return json_response(200, {
        success = true,
        message = "Server enabled"
    })
end
-- 修正后的 set_weight 函数
local function set_weight(upstream_name, server_address, weight)
    -- 验证 upstream 和 server
    if not validate_upstream(upstream_name) then
        return json_response(404, {
            error = "Upstream not found"
        })
    end

    local idx = find_server_index(upstream_name, server_address)
    if not idx then
        return json_response(404, {
            error = "Server not found in upstream"
        })
    end

    -- 验证权重值
    weight = tonumber(weight)
    if not weight or weight < 0 then
        return json_response(400, {
            error = "Invalid weight value"
        })
    end

    local state_key = upstream_name .. ":" .. server_address

    -- 更新共享状态中的权重
    state_dict:set(state_key .. ":weight", weight)

    -- 调用 dynamic_balancer 模块更新 lua-resty-balancer 中的权重
    local dynamic_balancer = require "dynamic_balancer"
    local ok = dynamic_balancer.update_weight(upstream_name, server_address, weight)

    if not ok then
        return json_response(500, {
            error = "Failed to update weight in balancer"
        })
    end

    return json_response(200, {
        success = true,
        message = "Server weight updated successfully"
    })
end

-- Main handler function
function _M.handle()
    local method = ngx.req.get_method()
    local uri = ngx.var.uri
    local uri_parts = {}

    for part in string.gmatch(uri, "[^/]+") do
        table.insert(uri_parts, part)
    end

    -- Parse query parameters
    ngx.req.read_body()
    local args = ngx.req.get_uri_args()

    -- Determine action based on URI and method
    if #uri_parts >= 3 and uri_parts[1] == "api" and uri_parts[2] == "upstream" then
        local upstream_name = uri_parts[3]

        if method == "GET" then
            -- List servers in upstream
            return get_servers(upstream_name)
        elseif method == "POST" and #uri_parts >= 5 then
            local server_address = uri_parts[4]
            local action = uri_parts[5]

            if action == "enable" then
                return enable_server(upstream_name, server_address)
            elseif action == "disable" then
                return disable_server(upstream_name, server_address)
            elseif action == "weight" then
                local weight = args.value
                if not weight then
                    return json_response(400, {
                        error = "Missing weight value"
                    })
                end
                return set_weight(upstream_name, server_address, weight)
                -- 在 upstream_api.lua 的 _M.handle() 函数中添加
            elseif action == "debug" then
                local dynamic_balancer = require "dynamic_balancer"
                dynamic_balancer.debug_upstream(upstream_name)
                return json_response(200, {
                    success = true,
                    message = "Debug info logged"
                })
            end
        end
    end

    return json_response(404, {
        error = "Unknown API endpoint"
    })
end

return _M
