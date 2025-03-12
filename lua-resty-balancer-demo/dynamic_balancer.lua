-- dynamic_balancer.lua
local _M = {}

-- 引入 ngx 模块
local balancer = require "ngx.balancer" -- openresty/lualib/ngx/balancer.lua
local state_dict = ngx.shared.upstream_state

-- 引入 lua-resty-balancer 模块
local roundrobin = require "resty.roundrobin"

-- 保存每个 upstream 的负载均衡器实例
local balancers = {}

-- 地址映射表，保存服务器地址到ID的映射
local addr_to_id = {}

-- 初始化负载均衡器
local function init_balancer(upstream_name)
    -- 从 upstream 模块获取所有服务器
    local upstream = require "ngx.upstream"
    local servers = upstream.get_servers(upstream_name)

    -- 创建初始节点表
    local nodes = {}

    -- 为每个服务器设置初始权重
    addr_to_id[upstream_name] = {}
    local id_counter = 1

    for _, server in ipairs(servers) do
        local server_addr = server.addr
        if server.name then
            server_addr = server.name
        end

        -- 从共享内存中获取权重，如果没有则使用默认权重
        local state_key = upstream_name .. ":" .. server_addr
        local weight = state_dict:get(state_key .. ":weight") or server.weight or 1
        local is_disabled = state_dict:get(state_key .. ":disabled")

        -- 为每个服务器地址分配一个唯一ID
        local server_id = id_counter
        id_counter = id_counter + 1

        -- 保存地址到ID的映射
        addr_to_id[upstream_name][server_addr] = server_id

        -- 如果服务器被禁用，将权重设为0，否则使用正常权重
        if is_disabled then
            nodes[server_id] = 0
        else
            nodes[server_id] = weight
        end

        ngx.log(ngx.INFO, "Mapped server address: ", server_addr, " to ID: ", server_id, " with weight: ",
            nodes[server_id])
    end

    -- 创建一个新的 roundrobin 实例
    local rb, err = roundrobin:new(nodes)
    if not rb then
        ngx.log(ngx.ERR, "Failed to create roundrobin: ", err)
        return nil
    end

    balancers[upstream_name] = rb
    return rb
end

-- 根据服务器地址获取服务器ID
local function get_server_id(upstream_name, server_address)
    if not addr_to_id[upstream_name] then
        return nil
    end

    -- 检查地址中是否包含端口号
    if not string.find(server_address, ":") then
        -- 尝试匹配不带端口的地址
        for addr, id in pairs(addr_to_id[upstream_name]) do
            local host = addr:match("([^:]+):")
            if host == server_address then
                return id
            end
        end
    end

    local server_id = addr_to_id[upstream_name][server_address]
    if not server_id then
        ngx.log(ngx.ERR, "No server ID found for address: ", server_address, " in upstream: ", upstream_name)
        return nil
    end

    return server_id
end

-- 负载均衡实现
function _M.balance()
    -- 获取上游信息
    local upstream_name = ngx.var.proxy_host
    if not upstream_name then
        ngx.log(ngx.ERR, "No upstream name found")
        return ngx.exit(500)
    end

    -- 确保有负载均衡器实例
    local my_balancer = balancers[upstream_name]
    if not my_balancer then
        my_balancer = init_balancer(upstream_name)
        if not my_balancer then
            ngx.log(ngx.ERR, "Failed to initialize balancer for: ", upstream_name)
            return ngx.exit(500)
        end
    end

    -- 使用 resty.balancer 选择一个后端服务器
    local server_id, err = my_balancer:find()
    if not server_id then
        ngx.log(ngx.ERR, "Failed to find server: ", err)
        return ngx.exit(500)
    end

    -- 从ID映射中找到对应的服务器地址
    local server_address = nil
    for addr, id in pairs(addr_to_id[upstream_name]) do
        if id == server_id then
            server_address = addr
            break
        end
    end

    if not server_address then
        ngx.log(ngx.ERR, "No server address found for ID: ", server_id)
        return ngx.exit(500)
    end

    -- 解析服务器地址（格式：host:port）
    local host, port = server_address:match("([^:]+):(%d+)")
    if not host or not port then
        ngx.log(ngx.ERR, "Invalid server address: ", server_address)
        return ngx.exit(500)
    end

    port = tonumber(port)

    -- 设置当前选择的服务器
    local ok, err = balancer.set_current_peer(host, port)
    if not ok then
        ngx.log(ngx.ERR, "Failed to set current peer: ", err)
        return ngx.exit(500)
    end

    -- 记录日志，方便调试
    ngx.log(ngx.INFO, "Balancer selected server: ", host, ":", port, " (ID: ", server_id, ")")
end

-- 更新服务器权重
function _M.update_weight(upstream_name, server_address, weight)
    -- 获取或初始化负载均衡器
    local my_balancer = balancers[upstream_name]
    if not my_balancer then
        my_balancer = init_balancer(upstream_name)
        if not my_balancer then
            ngx.log(ngx.ERR, "Failed to initialize balancer for weight update")
            return false
        end
    end

    -- 获取服务器ID
    local server_id = get_server_id(upstream_name, server_address)
    if not server_id then
        ngx.log(ngx.ERR, "Failed to get server ID for weight update")
        return false
    end

    -- 更新权重
    local ok, err = my_balancer:set(server_id, weight)
    ngx.log(ngx.INFO, "Result of set: " .. tostring(ok))
    ngx.log(ngx.INFO, "Result of set: " .. tostring(err))
    if not ok and err then
        ngx.log(ngx.ERR, "Failed to update weight: ", err)
        return false
    end

    ngx.log(ngx.INFO, "Updated weight for server ID: ", server_id, " (", server_address, ") in ", upstream_name, " to ",
        weight)
    return true
end

-- 禁用服务器
function _M.disable_server(upstream_name, server_address)
    ngx.log(ngx.INFO, "call _M.disable_server")
    -- 获取或初始化负载均衡器
    local my_balancer = balancers[upstream_name]
    if not my_balancer then
        my_balancer = init_balancer(upstream_name)
        if not my_balancer then
            ngx.log(ngx.ERR, "Failed to initialize balancer for server disable")
            return false
        end
    end

    -- 获取服务器ID
    local server_id = get_server_id(upstream_name, server_address)
    ngx.log(ngx.INFO, "disable_server result: ok=", tostring(ok), ", err=", tostring(err))

    if not server_id then
        ngx.log(ngx.ERR, "Failed to get server ID for disable operation")
        return false
    end

    ngx.log(ngx.INFO, "Attempting to disable server ID: ", server_id, " (", server_address, ") in upstream ",
        upstream_name)
    local current_weight = my_balancer.nodes[server_id] or 0
    if current_weight == 0 then
        ngx.log(ngx.INFO, "Server already disabled, skipping update")
        return true
    end

    local ok, err = my_balancer:set(server_id, 0)
    ngx.log(ngx.INFO, "disable_server result: ok=", tostring(ok), ", err=", tostring(err))
    if not ok and err then
        ngx.log(ngx.ERR, "Failed to disable server in balancer: ", err)
        return false
    end

    ngx.log(ngx.INFO, "Disabled server ", server_address, " (ID: ", server_id, ") in balancer for ", upstream_name)
    return true
end

-- 启用服务器
function _M.enable_server(upstream_name, server_address)
    -- 获取服务器的权重
    local state_key = upstream_name .. ":" .. server_address
    local weight = state_dict:get(state_key .. ":weight")

    -- 如果没有存储的权重，使用默认值1
    if not weight then
        weight = 1
    end

    -- 获取或初始化负载均衡器
    local my_balancer = balancers[upstream_name]
    if not my_balancer then
        my_balancer = init_balancer(upstream_name)
        if not my_balancer then
            ngx.log(ngx.ERR, "Failed to initialize balancer for server enable")
            return false
        end
    end

    -- 获取服务器ID
    local server_id = get_server_id(upstream_name, server_address)
    if not server_id then
        ngx.log(ngx.ERR, "Failed to get server ID for enable operation")
        return false
    end

    -- 恢复服务器的权重
    local ok, err = my_balancer:set(server_id, weight)
    if not ok and err then
        ngx.log(ngx.ERR, "Failed to enable server in balancer: ", err)
        return false
    end

    ngx.log(ngx.INFO, "Enabled server ", server_address, " (ID: ", server_id, ") in balancer for ", upstream_name,
        " with weight ", weight)
    return true
end

-- 重新初始化所有负载均衡器
function _M.reinit_all()
    balancers = {}
    addr_to_id = {}
    ngx.log(ngx.INFO, "All balancers reinitialized")
    return true
end

-- 初始化工作进程
function _M.init_worker()
    ngx.log(ngx.INFO, "Dynamic balancer worker initialized")
    -- 这里可以添加定期任务，如定期重新初始化负载均衡器
    local ok, err = ngx.timer.at(0, function()
        ngx.log(ngx.INFO, "Performing initial balancer setup")
        -- 这里可以预先初始化一些常用的upstream
    end)

    if not ok then
        ngx.log(ngx.ERR, "Failed to create timer: ", err)
    end
end

-- 修改后的 debug_upstream 函数
function _M.debug_upstream(upstream_name)
    -- 强制打印进入函数的日志
    ngx.log(ngx.ERR, "=== ENTERING debug_upstream for: ", upstream_name, " ===")

    -- 尝试获取上游信息
    local upstream = require "ngx.upstream"
    local servers = upstream.get_servers(upstream_name)

    ngx.log(ngx.ERR, "Debug upstream: ", upstream_name, ", server count: ", #servers)

    for i, server in ipairs(servers) do
        local addr = server.addr
        if server.name then
            addr = server.name
        end

        local state_key = upstream_name .. ":" .. addr
        local is_disabled = state_dict:get(state_key .. ":disabled") or false
        local current_weight = state_dict:get(state_key .. ":weight") or server.weight

        local server_id = addr_to_id[upstream_name] and addr_to_id[upstream_name][addr] or "unknown"

        ngx.log(ngx.ERR, "Server[", i, "]: ", addr, ", ID: ", server_id, ", original weight: ", server.weight,
            ", current weight: ", current_weight, ", disabled: ", is_disabled)
    end

    -- 检查负载均衡器状态
    local balancer = balancers[upstream_name]
    if balancer then
        ngx.log(ngx.ERR, "Balancer instance found for upstream: ", upstream_name)

        -- 由于没有 get_nodes 方法，我们尝试检查可用的 balancer 方法
        ngx.log(ngx.ERR, "Available balancer methods:")
        for k, v in pairs(balancer) do
            if type(v) == "function" then
                ngx.log(ngx.ERR, "  Method: ", k)
            end
        end

        -- 检查 balancer 元表
        local mt = getmetatable(balancer)
        if mt then
            ngx.log(ngx.ERR, "Balancer has metatable")
            if type(mt.__index) == "table" then
                for k, v in pairs(mt.__index) do
                    if type(v) == "function" then
                        ngx.log(ngx.ERR, "  Metatable method: ", k)
                    end
                end
            end
        end
    else
        ngx.log(ngx.ERR, "No balancer instance for this upstream")
    end

    ngx.log(ngx.ERR, "=== EXITING debug_upstream for: ", upstream_name, " ===")
end

return _M
