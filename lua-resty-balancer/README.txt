# 安装 openresty

https://openresty.org/en/installation.html

https://openresty.org/en/linux-packages.html

# 依赖 git@github.com:openresty/lua-resty-balancer

下载 lua-resty-balancer 后 sudo make install 文件到 /usr/local/lib/lua，并在 nginx 配置文件用 lua_package_path 和 lua_package_cpath 指定。

自己的脚本也在 /usr/local/lib/lua， 并在 nginx 配置文件用 lua_package_path 指定，如下
http {
    # Load required modules
    lua_package_path "/usr/local/lib/lua/?.lua;;";
    ......
}

ll -htr /usr/local/lib/lua
total 68K
drwxr-xr-x 3 root root 4.0K 2025-03-11 18:02 resty
-rwxr-xr-x 1 root root  29K 2025-03-11 18:02 librestychash.so
-rwxr-xr-x 1 root root 7.6K 2025-03-11 16:46 upstream_api.lua
-rwxr-xr-x 1 root root  12K 2025-03-11 18:04 dynamic_balancer.lua


ll -htr /usr/local/lib/lua/resty 
total 20K
-rwxr-xr-x 1 root root 3.0K 2025-03-11 18:02 swrr.lua
-rwxr-xr-x 1 root root 3.7K 2025-03-11 18:02 roundrobin.lua
-rwxr-xr-x 1 root root 7.4K 2025-03-11 18:02 chash.lua
drwxr-xr-x 2 root root 4.0K 2025-03-11 18:02 balancer


nginx.conf 文件替换 openresty 的 nginx.conf 后重启可以试验效果。

# 访问 nginx 
curl http://127.0.0.1:8089

# 查询 my_backend upstream 中的所有服务器状态
curl http://127.0.0.1:8089/api/upstream/my_backend

# 禁用特定的服务器
curl -X POST http://127.0.0.1:8089/api/upstream/my_backend/127.0.0.1:11280/disable

# 启用特定的服务器
curl -X POST http://127.0.0.1:8089/api/upstream/my_backend/127.0.0.1:11280/enable

# 设置服务器权重
curl -X POST http://127.0.0.1:8089/api/upstream/my_backend/127.0.0.1:11280/weight?value=10

