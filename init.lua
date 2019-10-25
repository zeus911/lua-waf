-- 函数库
-- 设置纯 Lua 扩展库的搜寻路径(';;' 是默认路径):
--package.path = package.path .. ';/usr/lib64/lua/5.1/?.lua;/usr/lib64/lua/5.1/?/init.lua;/www/server/nginx/lualib/resty/?.lua;;'
-- 设置 C 编写的 Lua 扩展模块的搜寻路径(也可以用 ';;'):
--package.cpath = package.cpath .. ';/usr/lib64/lua/5.1/?.so;/www/server/nginx/lualib/?.so;;'
require 'luarocks.loader'
local conf = require 'config'
local sqliteDriver = require('luasql.sqlite3')
local memcached = require "memcached"
local socket = require "socket"
local cjson = require('cjson')

kutil = {}

-- 获取当前脚本的目录路径,带有'/'
function kutil:currDir()
    local info = debug.getinfo(1, "S") -- 第二个参数 "S" 表示仅返回 source,short_src等字段， 其他还可以 "n", "f", "I", "L"等 返回不同的字段信息
    local path = info.source

    path = string.sub(path, 2, -1) -- 去掉开头的"@"

    path = string.match(path, "^.*/") -- 捕获最后一个 "/" 之前的部分 就是我们最终要的目录部分
    return path
end

-- 获取当前时间戳,毫秒
function kutil:getMilliseconds()
    return socket.gettime() * 1000
end

-- 生成随机数
function kutil:random(min, max)
    math.randomseed(kutil:getMilliseconds())
    return math.random(min, max)
end

-- 返回要打印的字符串
function kutil:dump(o)
    if type(o) == 'table' then
        local s = '{ '
        for k, v in pairs(o) do
            if type(k) ~= 'number' then k = '"' .. k .. '"' end
            s = s .. '[' .. k .. '] = ' .. self:dump(v) .. ','
        end
        return s .. '} '
    else
        return tostring(o)
    end
end

-- 字符串分割为table
function kutil:split(inputstr, delimiter)
    local result = {}
    local from = 1
    local delim_from, delim_to = string.find(inputstr, delimiter, from)
    while delim_from do
        table.insert(result, string.sub(inputstr, from, delim_from - 1))
        from = delim_to + 1
        delim_from, delim_to = string.find(inputstr, delimiter, from)
    end
    table.insert(result, string.sub(inputstr, from))
    return result
end

-- 统计表元素的长度
function kutil:count(tbl)
    local count = 0
    for _ in pairs(tbl) do
        count = count + 1
    end
    return count
end

-- 表是否为空
function kutil:isEmpty(tbl)
    for _, _ in pairs(tbl) do
        return false
    end
    return true
end

-- 表是否有某键
function kutil:hasKey(tbl, key)
    if tbl[key] ~= nil then
        return true
    end

    return false
end

-- 获取客户端IP
function kutil:getClientIp()
    local headers = ngx.req.get_headers()
    local ip = headers["X-REAL-IP"] or headers["X_FORWARDED_FOR"] or ngx.var.remote_addr or "0.0.0.0"
    return ip
end

-- ip转整型
function kutil:ipToInt(str)
    local num = 0
    if str and type(str) == "string" then
        local o1, o2, o3, o4 = str:match("(%d+)%.(%d+)%.(%d+)%.(%d+)")
        num = 2 ^ 24 * o1 + 2 ^ 16 * o2 + 2 ^ 8 * o3 + o4
    end
    return num
end

-- 整型转ip
function kutil:intToIp(n)
    if n then
        n = tonumber(n)
        local n1 = math.floor(n / (2 ^ 24))
        local n2 = math.floor((n - n1 * (2 ^ 24)) / (2 ^ 16))
        local n3 = math.floor((n - n1 * (2 ^ 24) - n2 * (2 ^ 16)) / (2 ^ 8))
        local n4 = math.floor((n - n1 * (2 ^ 24) - n2 * (2 ^ 16) - n3 * (2 ^ 8)))
        return n1 .. "." .. n2 .. "." .. n3 .. "." .. n4
    end
    return "0.0.0.0"
end

-- 写文件
function kutil:write(logfile, msg)
    local fd = io.open(logfile, "ab")
    if fd == nil then return end
    fd:write(msg)
    fd:flush()
    fd:close()
end

-- 打开sqlite数据库
function kutil:openSqlite(filename)
    filename = filename or self:currDir() .. "ips.db" -- 默认值
    local env = assert(sqliteDriver.sqlite3())
    local db = assert(env:connect(filename))
    return db, env
end

-- 执行sqlite查询
function kutil:sqliteQuery(sql)
    local db, env = self:openSqlite()
    local res = assert(db:execute(sql))
    local tb = {}
    local t = {}
    local i = 1
    while (nil ~= res:fetch(t, 'a')) do
        tb[i] = {}
        tb[i] = t
        t = {}  --must
    end

    res:close()
    db:close()
    env:close()

    return tb    --tb每个元素都是一个table
end

-- 获取IP记录
function kutil:getIpRow(ip)
    local ipInt = self:ipToInt(ip)
    local sql = [[
SELECT *
FROM ips
WHERE
being_ip <= %s AND end_ip >= %s
LIMIT 1
  ]]
    local res = self:sqliteQuery(string.format(sql, ipInt, ipInt))
    return self:isEmpty(res) and nil or res[1]
end

-- 获取memcache连接
function kutil:openMemcache(host, port)
    host = host or "127.0.0.1" -- 默认值
    port = port or "11211" -- 默认值

    local memc, _ = memcached:new()
    local ok, _ = memc:connect(host, port)

    return memc, ok
end

-- 输出拒绝页面
function kutil:sayDeny(ip)
    local html, _ = string.gsub(conf.denyHtml, "denyIp", ip)

    ngx.header.content_type = "text/html"
    ngx.status = ngx.HTTP_FORBIDDEN
    ngx.print(html)
    ngx.exit(ngx.status)
end

-- 写日志
function kutil:log(data)
    if conf.openlog then
        local url = ngx.var.uri
        local realIp = self:getClientIp()
        local ua = ngx.var.http_user_agent
        local servername = ngx.var.server_name
        local method = ngx.req.get_method()
        local time = ngx.localtime()

        if data == nil or type(data) ~= 'table' then
            data = {}
        end

        local useTime = self:getMilliseconds() - ngx.ctx.startTime --处理时间
        local tag = ngx.ctx.allowIp and '[allow] ' or '[deny] '

        data.allowIp = ngx.ctx.allowIp
        data.errors = ngx.ctx.errors
        data.startTime = ngx.ctx.startTime
        data.requestTime = ngx.var.request_time --请求执行时间
        data.tipMst = ngx.ctx.tipMst
        data.useTime = useTime
        data.userAgent = ua

        data = cjson.encode(data)
        local line = "[" .. time .. "] " .. tag .. realIp .. ' "' .. method .. ' ' .. servername .. url .. '" ' .. 'info:' .. data .. '\n'

        local filename = conf.logdir .. '/' .. servername .. "_" .. os.date("%Y-%m", ngx.time()) .. ".log"
        self:write(filename, line)
    end
end