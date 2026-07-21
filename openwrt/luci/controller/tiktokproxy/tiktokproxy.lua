module("luci.controller.tiktokproxy", package.seeall)
-- 路径常量 (不用 local, 避免 module 环境下 upvalue 丢失)
GENERATOR = "/etc/sing-box/generate-config.sh"
DIAGNOSTICS = "/usr/bin/chain-diagnostics.sh"
VPS_DB = "/usr/bin/vps-db.sh"
-- ---------------------------------------------------------------
-- 辅助函数
-- ---------------------------------------------------------------
function is_running()
    return os.execute("pidof sing-box > /dev/null 2>&1") == 0
end
function get_exit_ip()
    local ip = shell_exec("curl -s --max-time 5 http://ifconfig.me 2>/dev/null")
    return string.gsub(ip, "%s+", "")
end
function do_stop()
    log_api("do_stop", "START")
    shell_exec("/etc/init.d/sing-box stop 2>/dev/null")
    shell_exec("sleep 3")
    local still = is_running()
    if still then
        log_api("do_stop", "init.d stop 后仍运行, 强制 killall + 删 TUN")
        shell_exec("killall -9 sing-box 2>/dev/null")
        shell_exec("ip link del singbox-tun 2>/dev/null")
        shell_exec("sleep 2")
        still = is_running()
    end
    log_api("do_stop", "END running=" .. tostring(still))
end
function do_start()
    log_api("do_start", "START")
    shell_exec("/etc/init.d/sing-box start 2>/dev/null")
    shell_exec("sleep 5")
    local running = is_running()
    local pid = shell_exec("pidof sing-box 2>/dev/null"):gsub("%s+", "")
    log_api("do_start", "END running=" .. tostring(running) .. " pid=" .. (pid ~= "" and pid or "none"))
    return running
end
-- 执行 shell 命令并返回输出 (兼容 LuCI HTTP 上下文和纯 CLI 上下文)
function shell_exec(cmd)
    if luci and luci.sys and luci.sys.exec then
        return luci.sys.exec(cmd) or ""
    end
    local f = io.popen(cmd .. " 2>&1")
    if not f then return "" end
    local out = f:read("*a") or ""
    f:close()
    return out
end
-- 执行 shell 命令并返回 (输出, 退出码)。
-- 退出码通过命令末尾追加 `echo EXIT=$?` 解析得到，避免依赖 os.execute
-- (os.execute 在 LuCI CGI 环境下会挂起)。退出码为字符串，失败时 "?"。
function run_capture(cmd)
    local out = shell_exec(cmd .. "; echo EXIT=$?")
    local code = out:match("EXIT=(%d+)") or "?"
    -- 去掉末尾的 EXIT= 行，只保留真实输出
    out = out:gsub("%s*EXIT=%d+%s*$", "")
    return out, code
end
-- 获取物理 WAN 接口名 (用于 curl --interface 绕过 sing-box TUN)。
-- sing-box strict_route 会用策略路由表把所有 TCP 流量 (含路由器自身 curl)
-- 捕获进 singbox-tun; 直接 curl VPS 会在 Lua 子进程环境下超时。
-- 从 `ip route show default` 取 dev, 排除 tun/lan 接口。
function get_wan_iface()
    local out = shell_exec("ip route show default 2>/dev/null")
    local iface = out:match("dev (%S+)")
    if iface and iface ~= "singbox-tun" and not iface:match("^br%-lan") then
        return iface
    end
    return nil
end
-- 用 io.popen 执行带管道的命令并返回输出。
-- 注意: shell_exec 在 LuCI CGI 环境下走 luci.sys.exec, 对含 `|` 管道的命令
-- (如 ping | grep | awk) 可能行为异常。诊断测量里的管道命令统一用本函数。
function shell_popen(cmd)
    local f = io.popen(cmd .. " 2>&1")
    if not f then return "" end
    local out = f:read("*a") or ""
    f:close()
    return out
end
-- 执行 vps-db.sh 命令并返回输出
function db_cmd(args)
    local cmd = VPS_DB .. " " .. args .. " 2>/dev/null"
    local output = shell_exec(cmd)
    output = string.gsub(output, "^%s+", "")
    output = string.gsub(output, "%s+$", "")
    return output
end
-- 执行 shell 命令并返回输出 (截断防止过长)
function exec_output(cmd)
    local out = shell_exec(cmd)
    if #out > 65536 then
        out = string.sub(out, 1, 65536)
    end
    return out
end
-- 解析 JSON 字符串
function parse_json(str)
    if not str or #str == 0 then
        return nil
    end
    str = string.gsub(str, "^%s+", "")
    str = string.gsub(str, "%s+$", "")
    return require("luci.jsonc").parse(str)
end
-- 写操作日志到 /tmp/tiktokproxy-api.log
function log_api(action, msg)
    local line = os.date("%Y-%m-%d %H:%M:%S") .. " [" .. action .. "] " .. (msg or "")
    os.execute("logger -t tiktokproxy '" .. line:gsub("'", "'\\''") .. "' 2>/dev/null")
    os.execute("printf '%s\\n' '" .. line:gsub("'", "'\\''") .. "' >> /tmp/tiktokproxy-api.log 2>/dev/null")
end
-- 自动分配子网: 从 192.168.5.0/24 开始递增, 跳过已占用的
-- 返回如 "192.168.7.0/24"
function auto_allocate_cidr()
    local used = {}
    -- chains.source_cidr (向后兼容)
    local chains = parse_json(db_cmd("list-chains")) or {}
    for _, c in ipairs(chains) do
        local cidr = c.source_cidr or ""
        local third = cidr:match("^192%.168%.(%d+)%.0/24$")
        if third then used[tonumber(third)] = true end
    end
    -- subnets.cidr (新)
    local subnets = parse_json(db_cmd("list-subnets")) or {}
    for _, s in ipairs(subnets) do
        local cidr = s.cidr or ""
        local third = cidr:match("^192%.168%.(%d+)%.0/24$")
        if third then used[tonumber(third)] = true end
    end
    for i = 5, 254 do
        if not used[i] then
            return "192.168." .. i .. ".0/24"
        end
    end
    return nil  -- 全占满, 返回 nil 让调用方处理
end
-- 探测可用 LAN 网口: br-lan 成员中未被 subnets 占用的, 排除 WAN (eth1)
-- 返回 JSON 数组字符串, 如 [{"name":"eth0"},{"name":"eth2"}]
function get_available_interfaces()
    -- 当前 br-lan 成员
    local br_out = shell_exec("brctl show br-lan 2>/dev/null | awk 'NR>1 {print $NF}'")
    local br_members = {}
    for line in br_out:gmatch("[^\r\n]+") do
        local iface = line:gsub("^%s+",""):gsub("%s+$",""):match("^eth%d+$")
        if iface then br_members[#br_members+1] = iface end
    end
    -- 已被 subnets 占用的网口
    local used = {}
    local subnets = parse_json(db_cmd("list-subnets")) or {}
    for _, s in ipairs(subnets) do
        used[s.interface] = true
    end
    -- 组装可用列表 (无管理口, 所有 LAN 口平等)
    local result = {}
    for _, iface in ipairs(br_members) do
        if not used[iface] then
            local label = iface
            result[#result+1] = {name = iface, label = label}
        end
    end
    return require("luci.jsonc").stringify(result)
end
-- 重新生成 sing-box 配置并重启
function apply_config()
    log_api("apply_config", "START")
    local gen_out, gen_code = run_capture(GENERATOR .. " 2>&1")
    log_api("apply_config", "generate exit=" .. gen_code .. ": " .. (gen_out:gsub("%s+$", "")))
    if gen_code ~= "0" then
        log_api("apply_config", "FAILED generate exit=" .. gen_code .. ", 中止 (不重启 sing-box)")
        return false
    end
    local chk_out, chk_code = run_capture("/usr/bin/sing-box check -c /etc/sing-box/config.json 2>&1")
    if chk_code ~= "0" then
        log_api("apply_config", "FAILED check exit=" .. chk_code .. " out=" .. chk_out)
        return false
    end
    log_api("apply_config", "check OK (exit=0)")
    do_stop()
    do_start()
    log_api("apply_config", "END running=" .. tostring(is_running()))
    return true
end
-- 生成 8 位十六进制 UUID
function gen_node_uuid()
    math.randomseed(os.time())
    local hex = "0123456789abcdef"
    local uuid = ""
    for i = 1, 8 do
        uuid = uuid .. string.sub(hex, math.random(1, 16), math.random(1, 16))
    end
    -- 确保不与已有节点重复
    local existing = db_cmd("list-nodes")
    local nodes = parse_json(existing) or {}
    for _, n in ipairs(nodes) do
        if n.node_uuid == uuid then
            -- 冲突则追加随机字符
            uuid = uuid .. string.sub(hex, math.random(1, 16), math.random(1, 16))
            break
        end
    end
    return uuid
end
-- 步骤名称表
INIT_STEPS = {
    {step = 1, name = "连接 VPS"},
    {step = 2, name = "安装 sing-box"},
    {step = 3, name = "检测可用端口"},
    {step = 4, name = "生成 REALITY 密钥"},
    {step = 5, name = "写入配置文件"},
    {step = 6, name = "启动服务"},
    {step = 7, name = "连通测试"}
}
-- 更新节点 init_status + init_message (纯文本, 避免 JSON 嵌套转义问题)
function update_init_status(node_id, status, message)
    local safe_msg = (message or ""):gsub("\\", "\\\\"):gsub("'", "'\\''"):gsub("%s+", " ")
    db_cmd("update-node " .. node_id .. " '{\"init_status\":\"" .. status .. "\",\"init_message\":\"" .. safe_msg .. "\"}' 2>/dev/null")
end
-- SSH 执行远程命令并返回输出 (Dropbear 兼容)
-- 只返回最后一行 JSON (Dropbear ssh -y 会输出 host key 通知到 stderr, 但 2>/dev/null 可能漏过)
function ssh_exec(node, cmd)
    local ssh_pass = (node.ssh_password or ""):gsub("'", "'\\''")
    local ssh_port = node.ssh_port or 22
    local ssh_user = node.ssh_user or "root"
    local full_cmd = "sshpass -p '" .. ssh_pass .. "' ssh -y -p " .. ssh_port ..
        " " .. ssh_user .. "@" .. node.ip .. " '" .. cmd:gsub("'", "'\\''") .. "' 2>/dev/null"
    local out = shell_exec(full_cmd)
    -- 提取最后一行 (JSON 输出行), 跳过 Dropbear 的 host key 通知
    local json_line = ""
    for line in out:gmatch("[^\r\n]+") do
        line = line:match("^%s*(.-)%s*$")
        if line and #line > 0 and line:sub(1, 1) == "{" then
            json_line = line
        end
    end
    return json_line
end
function scp_to_vps(node, local_path, remote_path)
    local ssh_pass = (node.ssh_password or ""):gsub("'", "'\\''")
    local ssh_port = node.ssh_port or 22
    local ssh_user = node.ssh_user or "root"
    -- Dropbear scp 有 host key 交互问题, 改用 cat | ssh 管道传输
    local cmd = "cat " .. local_path .. " | sshpass -p '" .. ssh_pass .. "' ssh -y -p " .. ssh_port ..
        " " .. ssh_user .. "@" .. node.ip .. " 'cat > " .. remote_path .. "' 2>/dev/null"
    return os.execute(cmd)
end
-- 初始化单个节点 (后台调用, 逐步更新 init_message)
function init_node(node_id)
    local node = parse_json(db_cmd("get-node " .. node_id))
    if not node or not node.ip then
        log_api("init", "ERROR: node " .. node_id .. " not found")
        return
    end
    -- 生成 UUID 并写入
    local node_uuid = gen_node_uuid()
    db_cmd("update-node " .. node_id .. " '{\"node_uuid\":\"" .. node_uuid .. "\",\"init_status\":\"running\",\"init_message\":\"步骤 1/7: 连接 VPS\"}'")
    log_api("init", "START node=" .. node_id .. " uuid=" .. node_uuid .. " ip=" .. node.ip)
    local cfg = parse_json(db_cmd("get-settings")) or {}
    local reality_sni = cfg.default_reality_sni or "www.paypal.com"
    -- 优先用节点已有的密钥对 (reinit 时复用), 其次用 settings 默认值
    local reality_pub = node.reality_public_key or ""
    local reality_priv = node.reality_private_key or ""
    if #reality_pub == 0 then reality_pub = cfg.default_reality_public_key or "" end
    if #reality_priv == 0 then reality_priv = cfg.default_reality_private_key or "" end
    -- scp vps-init.sh 到 VPS
    scp_to_vps(node, "/usr/bin/vps-init.sh", "/tmp/vps-init.sh")
    local out = ssh_exec(node, "chmod +x /tmp/vps-init.sh && bash /tmp/vps-init.sh step1-check-connection --uuid " .. node_uuid)
    local result = parse_json(out)
    if not result or result.status ~= "ok" then
        update_init_status(node_id, "failed", "步骤 1/7 失败: " .. (out or ""))
        log_api("init", "FAILED node=" .. node_id .. " step1: " .. (out or ""))
        return
    end
    -- step2: install sing-box (传路由器版本号, 确保 VPS 与路由器版本一致)
    update_init_status(node_id, "running", "步骤 2/7: 安装 sing-box")
    local router_sb_version = shell_exec("sing-box version 2>/dev/null | head -1 | sed 's/\\x1b\\[[0-9;]*m//g' | grep -oE '[0-9]+\\.[0-9]+\\.[0-9]+' | head -1"):gsub("%s+", "")
    if router_sb_version == "" then router_sb_version = "1.11.5" end
    out = ssh_exec(node, "bash /tmp/vps-init.sh step2-install-singbox --uuid " .. node_uuid .. " --version " .. router_sb_version)
    result = parse_json(out)
    if not result or result.status ~= "ok" then
        update_init_status(node_id, "failed", "步骤 2/7 失败: " .. (out or ""))
        log_api("init", "FAILED node=" .. node_id .. " step2: " .. (out or ""))
        return
    end
    -- 版本检查: VPS 安装的版本必须和路由器一致
    local vps_sb_version = (result.version or ""):gsub("%s+", "")
    if vps_sb_version ~= "" and vps_sb_version ~= router_sb_version then
        update_init_status(node_id, "failed", "步骤 2/7 版本不匹配: 路由器=" .. router_sb_version .. " VPS=" .. vps_sb_version)
        log_api("init", "FAILED node=" .. node_id .. " 版本不匹配: 路由器=" .. router_sb_version .. " VPS=" .. vps_sb_version)
        return
    end
    log_api("init", "step2 OK: node=" .. node_id .. " VPS sing-box 版本=" .. (vps_sb_version ~= "" and vps_sb_version or "(未提取)") .. " (路由器=" .. router_sb_version .. ")")
    -- step3: find port
    update_init_status(node_id, "running", "步骤 3/7: 检测可用端口")
    out = ssh_exec(node, "bash /tmp/vps-init.sh step3-find-port --vless-port auto")
    result = parse_json(out)
    if not result or result.status ~= "ok" then
        update_init_status(node_id, "failed", "步骤 3/7 失败: " .. (out or ""))
        log_api("init", "FAILED node=" .. node_id .. " step3: " .. (out or ""))
        return
    end
    local port = result.port
    -- step4: gen reality (传已有密钥对时复用, 否则生成新的)
    update_init_status(node_id, "running", "步骤 4/7: 生成 REALITY 密钥")
    local step4_cmd = "bash /tmp/vps-init.sh step4-gen-reality --uuid " .. node_uuid .. " --reality-sni " .. reality_sni
    if #reality_pub > 0 and #reality_priv > 0 then
        step4_cmd = step4_cmd .. " --reality-public-key " .. reality_pub .. " --reality-private-key " .. reality_priv
    end
    out = ssh_exec(node, step4_cmd)
    result = parse_json(out)
    if not result or result.status ~= "ok" then
        update_init_status(node_id, "failed", "步骤 4/7 失败: " .. (out or ""))
        log_api("init", "FAILED node=" .. node_id .. " step4: " .. (out or ""))
        return
    end
    local vless_uuid = result.vless_uuid
    local reality_public_key = result.reality_public_key
    local reality_private_key = result.reality_private_key
    -- step4 成功后立即写回 DB (防止后续步骤失败导致 DB 与 VPS 不一致)
    local step4_json = '{"vless_uuid":"' .. vless_uuid ..
        '","reality_public_key":"' .. reality_public_key ..
        '","reality_private_key":"' .. reality_private_key .. '"}'
    db_cmd("update-node " .. node_id .. " '" .. step4_json:gsub("'", "'\\''") .. "'")
    log_api("init", "step4 OK: node=" .. node_id .. " 密钥对已写回 DB (pub=" .. reality_public_key:sub(1, 12) .. "... priv=" .. reality_private_key:sub(1, 12) .. "...)")
    -- step5: write config (先备份 VPS 现有配置, 失败可回滚)
    update_init_status(node_id, "running", "步骤 5/7: 写入配置文件")
    ssh_exec(node, "cp -r /etc/chb-sing-box-" .. node_uuid .. " /tmp/chb-sing-box-backup 2>/dev/null; true")
    out = ssh_exec(node, "bash /tmp/vps-init.sh step5-write-config --uuid " .. node_uuid ..
        " --port " .. port .. " --vless-uuid " .. vless_uuid ..
        " --reality-sni " .. reality_sni ..
        " --reality-public-key " .. reality_public_key ..
        " --reality-private-key " .. reality_private_key)
    result = parse_json(out)
    if not result or result.status ~= "ok" then
        -- step5 失败: 回滚 VPS 配置
        ssh_exec(node, "rm -rf /etc/chb-sing-box-" .. node_uuid .. "; mv /tmp/chb-sing-box-backup /etc/chb-sing-box-" .. node_uuid .. " 2>/dev/null; true")
        log_api("init", "ROLLBACK node=" .. node_id .. " step5 失败, 恢复 VPS 旧配置")
        update_init_status(node_id, "failed", "步骤 5/7 失败: " .. (out or ""))
        log_api("init", "FAILED node=" .. node_id .. " step5: " .. (out or ""))
        return
    end
    -- step6: start service
    update_init_status(node_id, "running", "步骤 6/7: 启动服务")
    out = ssh_exec(node, "bash /tmp/vps-init.sh step6-start-service --uuid " .. node_uuid)
    result = parse_json(out)
    if not result or result.status ~= "ok" then
        -- step6 失败: 回滚 VPS 配置
        ssh_exec(node, "rm -rf /etc/chb-sing-box-" .. node_uuid .. "; mv /tmp/chb-sing-box-backup /etc/chb-sing-box-" .. node_uuid .. " 2>/dev/null; true")
        log_api("init", "ROLLBACK node=" .. node_id .. " step6 失败, 恢复 VPS 旧配置")
        update_init_status(node_id, "failed", "步骤 6/7 失败: " .. (out or ""))
        log_api("init", "FAILED node=" .. node_id .. " step6: " .. (out or ""))
        return
    end
    -- step7: health check
    update_init_status(node_id, "running", "步骤 7/7: 连通测试")
    out = ssh_exec(node, "bash /tmp/vps-init.sh step7-health-check --uuid " .. node_uuid .. " --port " .. port)
    result = parse_json(out)
    if not result or result.status ~= "ok" then
        -- step7 失败: 回滚 VPS 配置
        ssh_exec(node, "rm -rf /etc/chb-sing-box-" .. node_uuid .. "; mv /tmp/chb-sing-box-backup /etc/chb-sing-box-" .. node_uuid .. " 2>/dev/null; true")
        log_api("init", "ROLLBACK node=" .. node_id .. " step7 失败, 恢复 VPS 旧配置")
        update_init_status(node_id, "failed", "步骤 7/7 失败: " .. (out or ""))
        log_api("init", "FAILED node=" .. node_id .. " step7: " .. (out or ""))
        return
    end
    -- 全部成功: 清理备份, 写入 init_status + init_port (密钥对已在 step4 后写回)
    ssh_exec(node, "rm -rf /tmp/chb-sing-box-backup 2>/dev/null")
    local success_json = '{"init_status":"ok","init_port":' .. port ..
        ',"init_message":"初始化完成 (port ' .. port .. ')"}'
    db_cmd("update-node " .. node_id .. " '" .. success_json:gsub("'", "'\\''") .. "'")
    log_api("init", "OK node=" .. node_id .. " port=" .. port .. " uuid=" .. node_uuid)
end
-- 卸载单个节点 (SSH 到 VPS 执行 uninstall)
function uninit_node(node)
    if not node or not node.ip or not node.node_uuid or #node.node_uuid == 0 then
        return
    end
    if node.init_status ~= "ok" and node.init_status ~= "failed" then
        return
    end
    log_api("uninit", "node=" .. node.id .. " ip=" .. node.ip .. " uuid=" .. node.node_uuid)
    ssh_exec(node, "bash /tmp/vps-init.sh uninstall --uuid " .. node.node_uuid .. " 2>/dev/null")
    log_api("uninit", "OK node=" .. node.id)
end
-- ---------------------------------------------------------------
-- 路由注册
-- ---------------------------------------------------------------
function index()
    if not nixio.fs.access("/etc/init.d/sing-box") then
        return
    end
    entry({"admin", "services", "tiktokproxy"}, firstchild(), _("TikTok 直播网络"), 90)
    entry({"admin", "services", "tiktokproxy", "vps"}, template("tiktokproxy/vps"), _("节点与链路管理"), 15)
    entry({"admin", "services", "tiktokproxy", "network"}, template("tiktokproxy/network"), _("网络状态"), 20)
    entry({"admin", "services", "tiktokproxy", "settings"}, template("tiktokproxy/settings"), _("全局设置"), 25)
    entry({"admin", "services", "tiktokproxy", "traffic"}, template("tiktokproxy/traffic"), _("流量监控"), 40)
    -- 控制面板 API
    entry({"admin", "services", "tiktokproxy", "status"}, call("action_status"))
    entry({"admin", "services", "tiktokproxy", "on"}, call("action_on"))
    entry({"admin", "services", "tiktokproxy", "off"}, call("action_off"))
    entry({"admin", "services", "tiktokproxy", "toggle"}, call("action_toggle"))
    -- VPS 节点管理 API (chains 内部使用 + 部署 API)
    entry({"admin", "services", "tiktokproxy", "vps_list"}, call("action_vps_list"))
    entry({"admin", "services", "tiktokproxy", "vps_get"}, call("action_vps_get"))
    entry({"admin", "services", "tiktokproxy", "vps_add"}, call("action_vps_add"))
    entry({"admin", "services", "tiktokproxy", "vps_update"}, call("action_vps_update"))
    entry({"admin", "services", "tiktokproxy", "vps_delete"}, call("action_vps_delete"))
    entry({"admin", "services", "tiktokproxy", "vps_deploy_api"}, call("action_vps_deploy_api"))
    -- 链路管理 API
    entry({"admin", "services", "tiktokproxy", "chains_list"}, call("action_chains_list"))
    entry({"admin", "services", "tiktokproxy", "chains_get"}, call("action_chains_get"))
    entry({"admin", "services", "tiktokproxy", "chains_add"}, call("action_chains_add"))
    entry({"admin", "services", "tiktokproxy", "chains_update"}, call("action_chains_update"))
    entry({"admin", "services", "tiktokproxy", "chains_delete"}, call("action_chains_delete"))
    entry({"admin", "services", "tiktokproxy", "chains_apply"}, call("action_chains_apply"))
    entry({"admin", "services", "tiktokproxy", "chains_activate"}, call("action_chains_activate"))
    entry({"admin", "services", "tiktokproxy", "chains_disable"}, call("action_chains_disable"))
    -- 子网 (设备) 管理 API (网络层增删改已挪到 SSH 脚本, 网页只读 + 换绑链路)
    entry({"admin", "services", "tiktokproxy", "subnets_list"}, call("action_subnets_list"))
    entry({"admin", "services", "tiktokproxy", "network_topology"}, call("action_network_topology"))
    entry({"admin", "services", "tiktokproxy", "subnets_bind"}, call("action_subnets_bind"))
    entry({"admin", "services", "tiktokproxy", "subnets_unbind"}, call("action_subnets_unbind"))
    entry({"admin", "services", "tiktokproxy", "interfaces_list"}, call("action_interfaces_list"))
    -- 全局设置 API
    entry({"admin", "services", "tiktokproxy", "settings_get"}, call("action_settings_get"))
    entry({"admin", "services", "tiktokproxy", "settings_save"}, call("action_settings_save"))
    -- 节点初始化状态 API
    entry({"admin", "services", "tiktokproxy", "node_init_status"}, call("action_node_init_status"))
    -- 网络状态 + 测速 + 流量 API
    entry({"admin", "services", "tiktokproxy", "network_data"}, call("action_network_data"))
    entry({"admin", "services", "tiktokproxy", "run_speedtest"}, call("action_run_speedtest"))
    entry({"admin", "services", "tiktokproxy", "diagnostics"}, call("action_diagnostics"))
    entry({"admin", "services", "tiktokproxy", "traffic_devices"}, call("action_traffic_devices"))
    entry({"admin", "services", "tiktokproxy", "traffic_device"}, call("action_traffic_device"))
    -- 设备更新管理
    entry({"admin", "services", "tiktokproxy", "update"}, template("tiktokproxy/update"), _("系统更新"), 50)
    entry({"admin", "services", "tiktokproxy", "check_update"}, call("action_check_update"))
    entry({"admin", "services", "tiktokproxy", "do_update"}, call("action_do_update"))
    entry({"admin", "services", "tiktokproxy", "update_status"}, call("action_update_status"))
    entry({"admin", "services", "tiktokproxy", "update_config"}, call("action_update_config"))
end
-- ---------------------------------------------------------------
-- 控制面板 API
-- ---------------------------------------------------------------
function action_status()
    local running = is_running()
    local exit_ip = ""
    if running then
        exit_ip = get_exit_ip()
    end
    -- 从 vps.db 读取链路信息
    local chains_json = db_cmd("list-chains")
    local chains = parse_json(chains_json) or {}
    -- 为每条链路展开 hop 详情（名称/IP/角色/协议/国家）
    local chains_info = {}
    for _, chain in ipairs(chains) do
        local hop_path = chain.hop_path or ""
        local hops = {}
        local hop_names = {}
        local hop_ips = {}
        for hop_id in string.gmatch(hop_path, "[^,]+") do
            local node_json = db_cmd("get-node " .. hop_id)
            local node = parse_json(node_json)
            if node then
                hops[#hops+1] = {
                    id = node.id,
                    name = node.name or "?",
                    ip = node.ip or "",
                    role = node.role or "relay",
                    protocol = node.protocol or "vless",
                    api_port = tonumber(node.api_port) or 8765
                }
                hop_names[#hop_names+1] = node.name or "?"
                hop_ips[#hop_ips+1] = node.ip or ""
            else
                hops[#hops+1] = { id = nil, name = "?", ip = "", role = "relay", protocol = "vless", api_port = 8765 }
                hop_names[#hop_names+1] = "?"
                hop_ips[#hop_ips+1] = ""
            end
        end
        chains_info[#chains_info+1] = {
            id = chain.id,
            name = chain.name,
            enabled = chain.enabled,
            hop_path = chain.hop_path,
            hops = hops,
            hop_names = table.concat(hop_names, " → "),
            hop_ips = table.concat(hop_ips, ","),
            source_ip = chain.source_ip,
            wifi_ssid = chain.wifi_ssid
        }
    end
    local tun_status = shell_exec("ip link show singbox-tun 2>/dev/null | grep -q . && echo created || echo missing"):gsub("%s+", "")
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        status = running and "running" or "stopped",
        exit_ip = exit_ip,
        tun = tun_status,
        chains = chains_info
    })
end
function action_on()
    log_api("on", "START")
    -- 重新生成配置 (确保 config.json 是最新的)
    local gen_out, gen_code = run_capture(GENERATOR .. " 2>&1")
    log_api("on", "generate exit=" .. gen_code .. ": " .. (gen_out:gsub("%s+$", "")))
    if gen_code ~= "0" then
        log_api("on", "FAILED generate exit=" .. gen_code .. ", 中止 (不重启 sing-box, 保留旧配置)")
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "failed", exit_ip = "", error = "config generate failed"})
        return
    end
    local chk_out, chk_code = run_capture("/usr/bin/sing-box check -c /etc/sing-box/config.json 2>&1")
    if chk_code ~= "0" then
        log_api("on", "FAILED check exit=" .. chk_code .. " out=" .. chk_out)
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "failed", exit_ip = "", error = "config check failed"})
        return
    end
    log_api("on", "check OK (exit=0)")
    do_stop()
    do_start()
    local running = is_running()
    local exit_ip = ""
    if running then
        exit_ip = get_exit_ip()
        log_api("on", "running pid=" .. (shell_exec("pidof sing-box 2>/dev/null"):gsub("%s+", "")) .. " exit_ip=" .. (exit_ip ~= "" and exit_ip or "(empty/timeout)"))
    else
        log_api("on", "FAILED sing-box 未运行, tail log: " .. shell_exec("tail -5 /var/log/sing-box.log 2>/dev/null"):gsub("%s+", " "))
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = running and "running" or "failed", exit_ip = exit_ip})
end
function action_off()
    log_api("off", "START")
    do_stop()
    local running = is_running()
    log_api("off", "END running=" .. tostring(running))
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = running and "running" or "stopped"})
end
function action_toggle()
    local was_running = is_running()
    log_api("toggle", "START was_running=" .. tostring(was_running))
    if was_running then
        do_stop()
    else
        do_start()
    end
    local running = is_running()
    local exit_ip = ""
    if running then
        exit_ip = get_exit_ip()
    end
    log_api("toggle", "END running=" .. tostring(running) .. " exit_ip=" .. (exit_ip ~= "" and exit_ip or "(empty)"))
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = running and "running" or "stopped", exit_ip = exit_ip})
end
-- ---------------------------------------------------------------
-- VPS 节点管理 API
-- ---------------------------------------------------------------
function action_vps_list()
    local output = db_cmd("list-nodes")
    local data = parse_json(output) or {}
    luci.http.prepare_content("application/json")
    luci.http.write_json({nodes = data})
end
function action_vps_get()
    local id = luci.http.formvalue("id") or ""
    if not id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id"})
        return
    end
    local output = db_cmd("get-node " .. id)
    local data = parse_json(output) or {}
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end
function action_vps_add()
    local fields = {
        "name", "ip", "role", "ssh_port", "ssh_user", "ssh_password",
        "protocol", "vless_port", "vless_uuid", "reality_sni", "reality_public_key",
        "api_port", "notes"
    }
    local json_parts = {}
    for _, key in ipairs(fields) do
        local val = luci.http.formvalue(key)
        -- 字符串字段：非空才写入；数字字段总是写入；ssh_password 特殊：总是写入（允许空密码）
        if key == "ssh_password" then
            val = (val or ""):gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
            json_parts[#json_parts+1] = '"ssh_password":"' .. val .. '"'
        elseif val and #val > 0 then
            if key == "ssh_port" or key == "vless_port" or key == "api_port" then
                json_parts[#json_parts+1] = '"' .. key .. '":' .. tonumber(val)
            else
                val = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
                json_parts[#json_parts+1] = '"' .. key .. '":"' .. val .. '"'
            end
        end
    end
    local json = "{" .. table.concat(json_parts, ",") .. "}"
    local output = db_cmd("add-node '" .. json:gsub("'", "'\\''") .. "'")
    local data = parse_json(output) or {error = "failed"}
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end
function action_vps_update()
    local id = luci.http.formvalue("id") or ""
    if not id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id"})
        return
    end
    local fields = {
        "name", "ip", "role", "ssh_port", "ssh_user", "ssh_password",
        "protocol", "vless_port", "vless_uuid", "reality_sni", "reality_public_key",
        "api_port", "api_deployed", "notes"
    }
    local json_parts = {}
    for _, key in ipairs(fields) do
        local val = luci.http.formvalue(key)
        -- ssh_password: 非空时更新，空时跳过（保留原值）
        if key == "ssh_password" then
            if val and #val > 0 then
                val = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
                json_parts[#json_parts+1] = '"ssh_password":"' .. val .. '"'
            end
        elseif val and #val > 0 then
            if key == "ssh_port" or key == "vless_port" or key == "api_port" or key == "api_deployed" then
                json_parts[#json_parts+1] = '"' .. key .. '":' .. tonumber(val)
            else
                val = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
                json_parts[#json_parts+1] = '"' .. key .. '":"' .. val .. '"'
            end
        end
    end
    local json = "{" .. table.concat(json_parts, ",") .. "}"
    local output = db_cmd("update-node " .. id .. " '" .. json:gsub("'", "'\\''") .. "'")
    local data = parse_json(output) or {error = "failed"}
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end
function action_vps_delete()
    local id = luci.http.formvalue("id") or ""
    if not id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id"})
        return
    end
    local output = db_cmd("delete-node " .. id)
    local data = parse_json(output) or {error = "failed"}
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end
-- 部署测速 API 到 VPS (SSH)
function action_vps_deploy_api()
    local id = luci.http.formvalue("id") or ""
    if not id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id"})
        return
    end
    local node_json = db_cmd("get-node " .. id)
    local node = parse_json(node_json)
    if not node or not node.ip then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "node not found"})
        return
    end
    if not node.ssh_password or #node.ssh_password == 0 then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "SSH password not set for this node"})
        return
    end
    local ssh_pass = node.ssh_password:gsub("'", "'\\''")
    local ssh_port = node.ssh_port or 22
    local ssh_user = node.ssh_user or "root"
    -- 后台部署 (避免超时)
    os.execute("(sshpass -p '" .. ssh_pass .. "' scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P " .. ssh_port ..
        " /usr/bin/speedtest-api.sh " .. ssh_user .. "@" .. node.ip .. ":/usr/local/bin/speedtest-api.sh 2>/dev/null; " ..
        "sshpass -p '" .. ssh_pass .. "' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p " .. ssh_port ..
        " " .. ssh_user .. "@" .. node.ip ..
        " 'chmod +x /usr/local/bin/speedtest-api.sh; apt-get install -y -qq socat 2>/dev/null; " ..
        "printf \"[Unit]\\nDescription=Speedtest API\\nAfter=network.target\\n\\n[Service]\\nExecStart=/usr/local/bin/speedtest-api.sh\\nRestart=always\\nRestartSec=3\\nUser=root\\n\\n[Install]\\nWantedBy=multi-user.target\\n\" > /etc/systemd/system/speedtest-api.service; " ..
        "systemctl daemon-reload; systemctl enable speedtest-api; systemctl restart speedtest-api; sleep 1; systemctl is-active speedtest-api' 2>/dev/null; " ..
        VPS_DB .. " update-node " .. id .. " '{\"api_deployed\":1}' 2>/dev/null" ..
        ") >/tmp/deploy_api.log 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = "deploying", message = "正在后台部署测速API, 请约10秒后刷新"})
end
-- ---------------------------------------------------------------
-- 链路管理 API
-- ---------------------------------------------------------------
function action_chains_list()
    local output = db_cmd("list-chains")
    local data = parse_json(output) or {}
    for _, chain in ipairs(data) do
        local hop_names = {}
        for hop_id in string.gmatch(chain.hop_path or "", "[^,]+") do
            local node_json = db_cmd("get-node " .. hop_id)
            local node = parse_json(node_json)
            hop_names[#hop_names+1] = (node and node.name) or "?"
        end
        chain.hop_names = table.concat(hop_names, " → ")
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({chains = data})
end
function action_chains_get()
    local id = luci.http.formvalue("id") or ""
    if not id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id"})
        return
    end
    local output = db_cmd("get-chain " .. id)
    local data = parse_json(output) or {}
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end
function action_chains_add()
    -- 1. 读取全局设置默认值
    local cfg = parse_json(db_cmd("get-settings")) or {}
    local chain_name = luci.http.formvalue("name") or "(未命名)"
    local wifi_ssid = luci.http.formvalue("wifi_ssid") or ""
    local source_cidr = luci.http.formvalue("source_cidr") or ""
    -- 子网未填则自动分配
    if #source_cidr == 0 then
        source_cidr = auto_allocate_cidr()
    end
    log_api("chains_add", "name=" .. chain_name .. " wifi=" .. wifi_ssid .. " cidr=" .. source_cidr)
    -- 2. 收集链路元信息
    local chain_fields = {"name", "enabled", "wifi_ssid", "ap_mac", "ap_ip"}
    local chain_parts = {}
    for _, key in ipairs(chain_fields) do
        local val = luci.http.formvalue(key)
        if val and #val > 0 then
            if key == "enabled" then
                chain_parts[#chain_parts+1] = '"' .. key .. '":' .. tonumber(val)
            else
                val = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
                chain_parts[#chain_parts+1] = '"' .. key .. '":"' .. val .. '"'
            end
        end
    end
    -- source_cidr: 用自动分配或用户填写的值 (不从 formvalue 重新读)
    chain_parts[#chain_parts+1] = '"source_cidr":"' .. source_cidr:gsub('"', '\\"') .. '"'
    -- 3. 解析 hops JSON 数组，逐跳创建节点
    local hops_raw = luci.http.formvalue("hops") or "[]"
    local hops = parse_json(hops_raw) or {}
    if #hops == 0 then
        log_api("chains_add", "ERROR: 无跳数")
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "至少需要一跳"})
        return
    end
    local node_ids = {}
    for i, hop in ipairs(hops) do
        if not hop.ip or #hop.ip == 0 then
            log_api("chains_add", "ERROR: 第" .. i .. "跳缺少IP")
            luci.http.prepare_content("application/json")
            luci.http.write_json({error = "第 " .. i .. " 跳缺少 IP"})
            return
        end
        -- 构造节点 JSON: 用户填的 ip/ssh_port/ssh_password + settings 默认值补齐
        local node_parts = {}
        local function add_str(key, val)
            if val and #val > 0 then
                val = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
                node_parts[#node_parts+1] = '"' .. key .. '":"' .. val .. '"'
            end
        end
        local function add_int(key, val)
            if val and #val > 0 then
                node_parts[#node_parts+1] = '"' .. key .. '":' .. tonumber(val)
            end
        end
        -- 用户显式填写的字段
        add_str("name", hop.name or ("hop" .. i))
        add_str("ip", hop.ip)
        add_str("ssh_password", hop.ssh_password or "")
        -- ssh_port: 优先用户填写, 否则 settings 默认
        if hop.ssh_port and #tostring(hop.ssh_port) > 0 then
            add_int("ssh_port", tostring(hop.ssh_port))
        else
            add_int("ssh_port", tostring(cfg.default_ssh_port or 22))
        end
        -- 以下字段从 settings 默认值补齐 (用户可在编辑时单独改)
        add_str("role", "relay")
        add_str("protocol", cfg.default_protocol or "vless")
        add_str("ssh_user", cfg.default_ssh_user or "root")
        add_int("vless_port", tostring(cfg.default_vless_port or 443))
        add_str("vless_uuid", cfg.default_vless_uuid or "")
        add_str("reality_sni", cfg.default_reality_sni or "www.paypal.com")
        add_str("reality_public_key", cfg.default_reality_public_key or "")
        add_int("api_port", tostring(cfg.default_api_port or 8765))
        local node_json = "{" .. table.concat(node_parts, ",") .. "}"
        local node_output = db_cmd("add-node '" .. node_json:gsub("'", "'\\''") .. "'")
        local node_data = parse_json(node_output) or {}
        if not node_data.id then
            log_api("chains_add", "ERROR: 第" .. i .. "跳节点创建失败: " .. (node_data.message or node_output))
            luci.http.prepare_content("application/json")
            luci.http.write_json({error = "第 " .. i .. " 跳节点创建失败: " .. (node_data.message or "")})
            return
        end
        node_ids[#node_ids+1] = node_data.id
    end
    -- 4. 拼 hop_path 并创建链路
    local hop_path = table.concat(node_ids, ",")
    chain_parts[#chain_parts+1] = '"hop_path":"' .. hop_path .. '"'
    local chain_json = "{" .. table.concat(chain_parts, ",") .. "}"
    local chain_output = db_cmd("add-chain '" .. chain_json:gsub("'", "'\\''") .. "'")
    local chain_data = parse_json(chain_output) or {error = "failed"}
    -- 如果链路创建失败, 清理已创建的节点
    if not chain_data.id then
        log_api("chains_add", "ERROR: 链路创建失败, 回滚节点 " .. hop_path .. " out=" .. (chain_output or ""))
        for _, nid in ipairs(node_ids) do
            db_cmd("delete-node " .. nid)
        end
    else
        log_api("chains_add", "OK: chain_id=" .. chain_data.id .. " hop_path=" .. hop_path .. " (" .. #node_ids .. " 跳)")
        -- 新链路默认禁用 (单链路模式: 用户需手动在控制面板选择启用)
        db_cmd("update-chain " .. chain_data.id .. " '{\"enabled\":0}'")
        chain_data.enabled = 0
        -- 后台异步初始化每个节点
        local nid_str = table.concat(node_ids, " ")
        os.execute("(/usr/bin/chb-init-node.sh init " .. nid_str .. " >/tmp/chb-init.log 2>&1) &")
    end
    chain_data.node_ids = node_ids
    luci.http.prepare_content("application/json")
    luci.http.write_json(chain_data)
end
function action_chains_update()
    local id = luci.http.formvalue("id") or ""
    if not id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id"})
        return
    end
    local chain_name = luci.http.formvalue("name") or "(未命名)"
    log_api("chains_update", "id=" .. id .. " name=" .. chain_name)
    -- 1. 读取当前链路的旧 hop_path
    local old_chain = parse_json(db_cmd("get-chain " .. id)) or {}
    local old_hop_ids = {}
    for hid in string.gmatch(old_chain.hop_path or "", "[^,]+") do
        hid = hid:match("^%s*(.-)%s*$")
        if #hid > 0 then old_hop_ids[#old_hop_ids+1] = tonumber(hid) end
    end
    -- 2. 解析新 hops 数组
    local hops_raw = luci.http.formvalue("hops") or "[]"
    local hops = parse_json(hops_raw) or {}
    if #hops == 0 then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "至少需要一跳"})
        return
    end
    -- 3. 读 settings 默认值 (用于新增跳)
    local cfg = parse_json(db_cmd("get-settings")) or {}
    -- 4. 处理每跳: 有 id 的更新, 无 id 的新增
    local new_node_ids = {}
    local seen_ids = {}
    for i, hop in ipairs(hops) do
        if not hop.ip or #hop.ip == 0 then
            luci.http.prepare_content("application/json")
            luci.http.write_json({error = "第 " .. i .. " 跳缺少 IP"})
            return
        end
        local function add_str(parts, key, val)
            if val and #val > 0 then
                val = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
                parts[#parts+1] = '"' .. key .. '":"' .. val .. '"'
            end
        end
        local function add_int(parts, key, val)
            if val and #val > 0 then
                parts[#parts+1] = '"' .. key .. '":' .. tonumber(val)
            end
        end
        local node_parts = {}
        add_str(node_parts, "name", hop.name or ("hop" .. i))
        add_str(node_parts, "ip", hop.ip)
        add_str(node_parts, "ssh_password", hop.ssh_password or "")
        if hop.ssh_port and #tostring(hop.ssh_port) > 0 then
            add_int(node_parts, "ssh_port", tostring(hop.ssh_port))
        end
        -- 高级选项: 如果 hop 中带了这些字段就更新
        if hop.role then add_str(node_parts, "role", hop.role) end
        if hop.protocol then add_str(node_parts, "protocol", hop.protocol) end
        if hop.ssh_user then add_str(node_parts, "ssh_user", hop.ssh_user) end
        if hop.vless_port then add_int(node_parts, "vless_port", tostring(hop.vless_port)) end
        if hop.vless_uuid then add_str(node_parts, "vless_uuid", hop.vless_uuid) end
        if hop.reality_sni then add_str(node_parts, "reality_sni", hop.reality_sni) end
        if hop.reality_public_key then add_str(node_parts, "reality_public_key", hop.reality_public_key) end
        if hop.id then
            -- 更新已有节点
            local node_json = "{" .. table.concat(node_parts, ",") .. "}"
            db_cmd("update-node " .. hop.id .. " '" .. node_json:gsub("'", "'\\''") .. "'")
            new_node_ids[#new_node_ids+1] = hop.id
            seen_ids[tonumber(hop.id)] = true
        else
            -- 新增节点: 用 settings 补齐默认值
            add_str(node_parts, "role", "relay")
            add_str(node_parts, "protocol", cfg.default_protocol or "vless")
            add_str(node_parts, "ssh_user", cfg.default_ssh_user or "root")
            if not hop.ssh_port then add_int(node_parts, "ssh_port", tostring(cfg.default_ssh_port or 22)) end
            add_int(node_parts, "vless_port", tostring(cfg.default_vless_port or 443))
            add_str(node_parts, "vless_uuid", cfg.default_vless_uuid or "")
            add_str(node_parts, "reality_sni", cfg.default_reality_sni or "www.paypal.com")
            add_str(node_parts, "reality_public_key", cfg.default_reality_public_key or "")
            add_int(node_parts, "api_port", tostring(cfg.default_api_port or 8765))
            local node_json = "{" .. table.concat(node_parts, ",") .. "}"
            local node_output = db_cmd("add-node '" .. node_json:gsub("'", "'\\''") .. "'")
            local node_data = parse_json(node_output) or {}
            if not node_data.id then
                luci.http.prepare_content("application/json")
                luci.http.write_json({error = "第 " .. i .. " 跳节点创建失败"})
                return
            end
            new_node_ids[#new_node_ids+1] = node_data.id
            seen_ids[node_data.id] = true
        end
    end
    -- 5. 卸载并删除不在新列表中的旧节点
    local uninit_ids = {}
    for _, old_id in ipairs(old_hop_ids) do
        if not seen_ids[old_id] then
            local node = parse_json(db_cmd("get-node " .. old_id))
            if node and node.ip then
                table.insert(uninit_ids, tostring(old_id))
            end
            db_cmd("delete-node " .. old_id)
        end
    end
    if #uninit_ids > 0 then
        local nid_str = table.concat(uninit_ids, " ")
        os.execute("(/usr/bin/chb-init-node.sh uninit " .. nid_str .. " >/tmp/chb-uninit.log 2>&1) &")
    end
    -- 6. 更新链路
    local chain_fields = {"name", "enabled", "source_cidr", "wifi_ssid", "ap_mac", "ap_ip"}
    local chain_parts = {}
    for _, key in ipairs(chain_fields) do
        local val = luci.http.formvalue(key)
        if val and #val > 0 then
            if key == "enabled" then
                chain_parts[#chain_parts+1] = '"' .. key .. '":' .. tonumber(val)
            else
                val = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
                chain_parts[#chain_parts+1] = '"' .. key .. '":"' .. val .. '"'
            end
        end
    end
    chain_parts[#chain_parts+1] = '"hop_path":"' .. table.concat(new_node_ids, ",") .. '"'
    local chain_json = "{" .. table.concat(chain_parts, ",") .. "}"
    local output = db_cmd("update-chain " .. id .. " '" .. chain_json:gsub("'", "'\\''") .. "'")
    local data = parse_json(output) or {error = "failed"}
    if data.status == "ok" then
        log_api("chains_update", "OK: id=" .. id .. " hop_path=" .. table.concat(new_node_ids, ","))
        -- 后台初始化新增的节点 (init_status 为空或 pending 的)
        local init_ids = {}
        for _, nid in ipairs(new_node_ids) do
            local node = parse_json(db_cmd("get-node " .. nid))
            if node and (not node.init_status or node.init_status == "pending" or #node.node_uuid == 0) then
                table.insert(init_ids, tostring(nid))
            end
        end
        if #init_ids > 0 then
            local nid_str = table.concat(init_ids, " ")
            os.execute("(/usr/bin/chb-init-node.sh init " .. nid_str .. " >/tmp/chb-init.log 2>&1) &")
        end
        data.node_ids = new_node_ids
    else
        log_api("chains_update", "ERROR: id=" .. id .. " out=" .. (output or ""))
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end
function action_chains_delete()
    local id = luci.http.formvalue("id") or ""
    if not id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id"})
        return
    end
    -- 先读取链路的 hop_path, 后台卸载 + 级联删除节点
    local chain = parse_json(db_cmd("get-chain " .. id)) or {}
    local hop_path = chain.hop_path or ""
    log_api("chains_delete", "id=" .. id .. " hop_path=" .. hop_path .. " name=" .. (chain.name or ""))
    local uninit_ids = {}
    for hid in string.gmatch(hop_path, "[^,]+") do
        hid = hid:match("^%s*(.-)%s*$")
        if #hid > 0 and hid:match("^%d+$") then
            local node = parse_json(db_cmd("get-node " .. hid))
            if node and node.ip then
                table.insert(uninit_ids, hid)
            end
        end
    end
    -- 后台卸载
    if #uninit_ids > 0 then
        local nid_str = table.concat(uninit_ids, " ")
        os.execute("(/usr/bin/chb-init-node.sh uninit " .. nid_str .. " >/tmp/chb-uninit.log 2>&1) &")
    end
    -- 级联删除节点
    for _, hid in ipairs(uninit_ids) do
        db_cmd("delete-node " .. hid)
    end
    local output = db_cmd("delete-chain " .. id)
    local data = parse_json(output) or {error = "failed"}
    log_api("chains_delete", "OK: id=" .. id)
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end
-- ---------------------------------------------------------------
-- 子网 (设备) 管理 API
-- ---------------------------------------------------------------

-- 网口拓扑总览: 动态发现所有物理网口, 返回实时状态 + 子网 + 连接设备
function action_network_topology()
    local result = {interfaces = {}, bridges = {}}

    -- 1. 动态发现所有物理网口 (用 /sys/class/net/*/device 目录存在性判断)
    local phys_ifaces = {}
    local f = io.popen("ls /sys/class/net/ 2>/dev/null")
    if f then
        for line in f:lines() do
            local d = io.open("/sys/class/net/" .. line .. "/device")
            if d then d:close(); table.insert(phys_ifaces, line) end
        end
        f:close()
    end

    -- 2. 动态发现所有桥接口
    local bridges = {}
    local br_out = shell_exec("ip -o link show type bridge 2>/dev/null")
    for br_name in br_out:gmatch("([^:%s]+):") do
        br_name = br_name:gsub("^%s+", ""):gsub("%s+$", "")
        if br_name ~= "" and br_name:match("^br") then
            local br_ip = shell_exec("ip -br addr show " .. br_name .. " 2>/dev/null"):match("(%d+%.%d+%.%d+%.%d+/%d+)")
            local members = {}
            local brif_f = io.popen("ls /sys/class/net/" .. br_name .. "/brif/ 2>/dev/null")
            if brif_f then
                for m in brif_f:lines() do table.insert(members, m) end
                brif_f:close()
            end
            bridges[br_name] = {ip = br_ip, members = members}
            table.insert(result.bridges, {name = br_name, ip = br_ip, members = members})
        end
    end

    -- 3. 读取 UCI network 配置, 建立 物理网口 -> UCI接口名 映射
    local iface_roles = {}
    local uci_out = shell_exec("uci show network 2>/dev/null")
    for section in uci_out:gmatch("network%.([^.]+)=interface") do
        local ifname = shell_exec("uci get network." .. section .. ".ifname 2>/dev/null"):gsub("^%s+", ""):gsub("%s+$", "")
        if ifname == "" then
            ifname = shell_exec("uci get network." .. section .. ".device 2>/dev/null"):gsub("^%s+", ""):gsub("%s+$", "")
        end
        for port in ifname:gmatch("%S+") do
            if not iface_roles[port] then iface_roles[port] = {} end
            table.insert(iface_roles[port], section)
        end
    end

    -- 4. 读取 DHCP 租约 (设备名+IP+MAC)
    local leases = {}
    local lf = io.open("/tmp/dhcp.leases", "r")
    if lf then
        for line in lf:lines() do
            local ts, mac, ip, hostname = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S*)")
            if mac and ip then
                local hn = hostname or ""
                if hn == "*" or hn == "" then hn = "unknown" end
                table.insert(leases, {mac = mac, ip = ip, hostname = hn})
            end
        end
        lf:close()
    end

    -- 5. 读取 ARP 邻居表 (设备活跃状态)
    -- 注意: Lua 5.1 pattern 不支持 | (alternation), 不能用 (REACHABLE|STALE|...)
    -- 改用 string.find 逐个查找状态关键字
    local arp = {}
    local neigh_out = shell_exec("ip neigh show 2>/dev/null")
    for line in neigh_out:gmatch("[^\r\n]+") do
        local ip = line:match("^(%d+%.%d+%.%d+%.%d+)")
        if ip then
            local state = "UNKNOWN"
            -- 按优先级匹配 (REACHABLE > STALE > FAILED > DELAY > PERMANENT)
            -- 用 string.find 而不是 pattern alternation
            if string.find(line, "REACHABLE", 1, true) then
                state = "REACHABLE"
            elseif string.find(line, "PERMANENT", 1, true) then
                state = "PERMANENT"
            elseif string.find(line, "DELAY", 1, true) then
                state = "DELAY"
            elseif string.find(line, "STALE", 1, true) then
                state = "STALE"
            elseif string.find(line, "FAILED", 1, true) then
                state = "FAILED"
            end
            arp[ip] = state
        end
    end

    -- 6. 读取子网和链路绑定关系
    local subnets = parse_json(db_cmd("list-subnets")) or {}
    local chains = parse_json(db_cmd("list-chains")) or {}
    local chain_map = {}
    for _, c in ipairs(chains) do chain_map[c.id] = c.name end

    -- 7. 组装每个物理网口的信息
    for _, iface in ipairs(phys_ifaces) do
        local carrier_raw = shell_exec("cat /sys/class/net/" .. iface .. "/carrier 2>/dev/null"):gsub("%s+", "")
        local carrier = tonumber(carrier_raw) or 0
        local speed = shell_exec("cat /sys/class/net/" .. iface .. "/speed 2>/dev/null"):gsub("%s+", "")
        if speed == "" or carrier == 0 then speed = "-" end
        local duplex = shell_exec("cat /sys/class/net/" .. iface .. "/duplex 2>/dev/null"):gsub("%s+", "")
        if carrier == 0 then duplex = "-" end
        local mac = shell_exec("cat /sys/class/net/" .. iface .. "/address 2>/dev/null"):gsub("%s+", "")
        local ip = shell_exec("ip -br addr show " .. iface .. " 2>/dev/null"):match("(%d+%.%d+%.%d+%.%d+/%d+)")

        -- 桥接信息
        local master = shell_exec("ip -d link show " .. iface .. " 2>/dev/null"):match("master (%S+)")
        local in_bridge = master ~= nil and master ~= ""

        -- 角色
        local roles = iface_roles[iface] or {}
        local is_wan = false
        for _, r in ipairs(roles) do
            if r == "wan" or r:match("wan") then is_wan = true end
        end
        local role_label = ""
        if is_wan then role_label = "WAN"
        elseif in_bridge then role_label = "LAN (桥成员)"
        elseif #roles > 0 then role_label = table.concat(roles, ", ")
        else role_label = "未绑定" end

        local entry = {
            name = iface,
            carrier = carrier,
            speed = speed,
            duplex = duplex,
            mac = mac,
            ip = ip,
            in_bridge = in_bridge,
            bridge_name = master or nil,
            roles = roles,
            role_label = role_label,
            is_wan = is_wan,
            subnet = nil,
            devices = {}
        }

        -- 子网信息
        local subnet_found = nil
        -- 情况A: 该口拆出了子网
        for _, s in ipairs(subnets) do
            if s.interface == iface then
                local gw = s.gateway
                if gw == "" or not gw then gw = s.cidr:gsub("%.0/24$", ".1") end
                subnet_found = {
                    id = s.id, name = s.name, cidr = s.cidr, gateway = gw,
                    chain_id = s.chain_id,
                    chain_name = s.chain_id and chain_map[s.chain_id] or "未绑定"
                }
                local uci_name = iface:gsub("eth", "lan")
                local start_v = shell_exec("uci get dhcp." .. uci_name .. ".start 2>/dev/null"):gsub("%s+", "")
                local limit_v = shell_exec("uci get dhcp." .. uci_name .. ".limit 2>/dev/null"):gsub("%s+", "")
                if start_v ~= "" and limit_v ~= "" then
                    local third = s.cidr:match("192%.168%.(%d+)%.")
                    if third then
                        subnet_found.dhcp_pool = "192.168." .. third .. "." .. start_v .. "-192.168." .. third .. "." .. (tonumber(start_v) + tonumber(limit_v) - 1)
                    end
                end
                break
            end
        end

        entry.subnet = subnet_found

        -- 设备信息: 按网段过滤 DHCP 租约 + ARP 状态
        -- 有子网的用子网 CIDR, 桥成员用桥 IP 网段
        local device_cidr_third = nil
        if subnet_found then
            device_cidr_third = subnet_found.cidr:match("192%.168%.(%d+)%.")
        elseif in_bridge and master and bridges[master] and bridges[master].ip then
            device_cidr_third = bridges[master].ip:match("192%.168%.(%d+)%.")
        end
        if device_cidr_third then
            for _, l in ipairs(leases) do
                if l.ip:match("^192%.168%." .. device_cidr_third .. "%.") then
                    local status = "offline"
                    local arp_state = arp[l.ip]
                    if arp_state == "REACHABLE" or arp_state == "PERMANENT" then status = "active"
                    elseif arp_state == "STALE" or arp_state == "DELAY" then status = "stale"
                    end
                    -- 设备类型探测: ping 读 TTL (Windows=128, Linux/Mac/iOS/Android=64)
                    -- 离线设备不 ping (会阻塞), 只对 active/stale 的设备探测
                    local device_type = "未知"
                    if status ~= "offline" then
                        local ttl_raw = shell_exec("ping -c 1 -W 1 " .. l.ip .. " 2>/dev/null")
                        local ttl = tonumber(ttl_raw:match("ttl=(%d+)"))
                        if ttl then
                            if ttl >= 100 and ttl <= 128 then
                                device_type = "Windows"
                            elseif ttl >= 60 and ttl <= 64 then
                                -- TTL=64 的细分: 根据 hostname 推断
                                local hn = l.hostname:lower()
                                if hn:match("iphone") or hn:match("ipad") then
                                    device_type = "iOS"
                                elseif hn:match("mac") or hn:match("macbook") then
                                    device_type = "macOS"
                                elseif hn:match("android") or hn:match("samsung") or hn:match("huawei") or hn:match("xiaomi") or hn:match("redmi") then
                                    device_type = "Android"
                                elseif hn:match("miwifi") or hn:match("router") or hn:match("openwrt") then
                                    device_type = "路由器"
                                else
                                    device_type = "Linux/Mac/移动端"
                                end
                            elseif ttl >= 240 and ttl <= 255 then
                                device_type = "网络设备"
                            else
                                device_type = "其他(ttl=" .. ttl .. ")"
                            end
                        end
                    end
                    table.insert(entry.devices, {
                        hostname = l.hostname,
                        ip = l.ip,
                        mac = l.mac,
                        status = status,
                        device_type = device_type
                    })
                end
            end
        end

        table.insert(result.interfaces, entry)
    end

    luci.http.prepare_content("application/json")
    luci.http.write_json(result)
end

function action_subnets_list()
    log_api("subnets_list", "")
    local output = db_cmd("list-subnets")
    local data = parse_json(output) or {}
    luci.http.prepare_content("application/json")
    luci.http.write_json({subnets = data})
end
function action_interfaces_list()
    log_api("interfaces_list", "")
    local json_str = get_available_interfaces()
    local data = parse_json(json_str) or {}
    luci.http.prepare_content("application/json")
    luci.http.write_json({interfaces = data})
end
function action_subnets_bind()
    local id = luci.http.formvalue("id") or ""
    local chain_id = luci.http.formvalue("chain_id") or ""
    if not id:match("^%d+$") or not chain_id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id or chain_id"})
        return
    end
    log_api("subnets_bind", "subnet=" .. id .. " chain=" .. chain_id)
    -- 绑定
    db_cmd("bind-subnet " .. id .. " " .. chain_id)
    -- 确保链路 enabled=1
    db_cmd("update-chain " .. chain_id .. " '{\"enabled\":1}'")
    -- 重新生成配置 + 重启 sing-box
    local ok = apply_config()
    log_api("subnets_bind", "apply_config=" .. tostring(ok))
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = ok and "ok" or "error", id = tonumber(id), chain_id = tonumber(chain_id)})
end
function action_subnets_unbind()
    local id = luci.http.formvalue("id") or ""
    if not id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id"})
        return
    end
    log_api("subnets_unbind", "subnet=" .. id)
    db_cmd("unbind-subnet " .. id)
    local ok = apply_config()
    log_api("subnets_unbind", "apply_config=" .. tostring(ok))
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = ok and "ok" or "error", id = tonumber(id)})
end
-- 单独关闭某条链路 (enabled=0, 不影响其它链路; 绑定子网临时直连)
function action_chains_disable()
    local id = luci.http.formvalue("id") or ""
    if not id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id"})
        return
    end
    log_api("chains_disable", "id=" .. id)
    db_cmd("update-chain " .. id .. " '{\"enabled\":0}'")
    local ok = apply_config()
    log_api("chains_disable", "apply_config=" .. tostring(ok))
    luci.http.prepare_content("application/json")
    luci.http.write_json({status = ok and "ok" or "error", id = tonumber(id)})
end
-- 应用配置: 后台生成 config.json + 重启 sing-box
function action_chains_apply()
    log_api("chains_apply", "START (后台执行, 结果见 /tmp/chains_apply.log)")
    -- 后台脚本: 生成/校验失败则记录并中止 (不用 set -e, 改显式 || 判断以便落盘失败原因)
    os.execute("( " ..
        "echo \"[chains_apply] $(date) START\"; " ..
        GENERATOR .. " 2>&1 || { echo \"[chains_apply] FAILED generate exit=$? $(date) ABORT\"; exit 1; }; " ..
        "echo \"[chains_apply] generate OK\"; " ..
        "/usr/bin/sing-box check -c /etc/sing-box/config.json 2>&1 || { echo \"[chains_apply] FAILED check exit=$? $(date) ABORT\"; exit 1; }; " ..
        "echo \"[chains_apply] check OK\"; " ..
        "/etc/init.d/sing-box stop 2>/dev/null; sleep 3; " ..
        "killall -9 sing-box 2>/dev/null; ip link del singbox-tun 2>/dev/null; sleep 2; " ..
        "/etc/init.d/sing-box start 2>/dev/null; sleep 5; " ..
        "echo \"[chains_apply] running=$(pidof sing-box > /dev/null && echo yes || echo no) pid=$(pidof sing-box) exit_ip=$(curl -s --max-time 5 http://ifconfig.me) $(date) END\" " ..
        ") >/tmp/chains_apply.log 2>&1 &")
    log_api("chains_apply", "后台任务已派发")
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        status = "applying",
        message = "配置正在后台生成并应用, 请约15秒后刷新状态"
    })
end
-- 激活单条链路 (多链路并发模式: 仅启用选中的, 重新生成配置)
function action_chains_activate()
    local id = luci.http.formvalue("id") or ""
    if not id:match("^%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid id"})
        return
    end
    log_api("chains_activate", "id=" .. id)
    -- 多链路并发模式: 仅启用选中链路, 不禁用其它链路 (去互斥)
    db_cmd("update-chain " .. id .. " '{\"enabled\":1}'")
    -- 重新生成配置 (用 shell_exec 避免 os.execute 在 CGI 环境下挂起)
    local gen_out, gen_code = run_capture(GENERATOR .. " 2>&1")
    log_api("chains_activate", "generate exit=" .. gen_code .. ": " .. (gen_out:gsub("%s+$", "")))
    if gen_code ~= "0" then
        log_api("chains_activate", "FAILED generate exit=" .. gen_code)
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "error", message = "配置生成失败, 链路已激活但配置未更新"})
        return
    end
    local chk_out, chk_code = run_capture("/usr/bin/sing-box check -c /etc/sing-box/config.json 2>&1")
    log_api("chains_activate", "check exit=" .. chk_code .. (chk_code ~= "0" and (" out=" .. chk_out) or ""))
    if chk_code ~= "0" then
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "error", message = "配置校验失败"})
        return
    end
    luci.http.prepare_content("application/json")
    -- 配置校验通过, 重启 sing-box 使配置生效
    local apply_ok = apply_config()
    log_api("chains_activate", "apply_config=" .. tostring(apply_ok))
    if not apply_ok then
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "error", message = "链路已激活但 sing-box 重启失败"})
        return
    end
    luci.http.write_json({status = "ok", message = "链路已激活"})
end
-- ---------------------------------------------------------------
-- 全局设置 API
-- ---------------------------------------------------------------
function action_settings_get()
    local output = db_cmd("get-settings")
    local data = parse_json(output) or {}
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end
function action_settings_save()
    local fields = {
        "default_protocol", "default_ssh_port", "default_ssh_user",
        "default_vless_port", "default_vless_uuid",
        "default_reality_sni", "default_reality_public_key",
        "default_reality_private_key",
        "default_api_port"
    }
    local int_fields = {
        default_ssh_port = true, default_vless_port = true,
        default_api_port = true
    }
    local json_parts = {}
    for _, key in ipairs(fields) do
        local val = luci.http.formvalue(key)
        if val and #val > 0 then
            if int_fields[key] then
                json_parts[#json_parts+1] = '"' .. key .. '":' .. tonumber(val)
            else
                val = val:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
                json_parts[#json_parts+1] = '"' .. key .. '":"' .. val .. '"'
            end
        end
    end
    local json = "{" .. table.concat(json_parts, ",") .. "}"
    local output = db_cmd("set-settings '" .. json:gsub("'", "'\\''") .. "'")
    local data = parse_json(output) or {error = "failed"}
    if data.status == "ok" then
        log_api("settings_save", "OK: " .. #json_parts .. " 个字段")
    else
        log_api("settings_save", "ERROR: out=" .. (output or ""))
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json(data)
end
-- 获取所有节点的初始化状态
function action_node_init_status()
    local nodes = parse_json(db_cmd("list-nodes")) or {}
    local result = {}
    for _, n in ipairs(nodes) do
        result[#result+1] = {
            id = n.id,
            name = n.name,
            ip = n.ip,
            init_status = n.init_status or "pending",
            init_message = n.init_message or "",
            init_port = n.init_port or 0
        }
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({nodes = result})
end
-- ---------------------------------------------------------------
-- 网络状态 API
-- ---------------------------------------------------------------
function action_network_data()
    local output = exec_output(DIAGNOSTICS .. " network 2>/dev/null")
    local data = parse_json(output)
    luci.http.prepare_content("application/json")
    if data then
        luci.http.write_json(data)
    else
        luci.http.write_json({error = "failed to get network data", raw = output})
    end
end
-- ---------------------------------------------------------------
-- 测速 API
-- ---------------------------------------------------------------
function action_run_speedtest()
    local stage = luci.http.formvalue("stage") or ""
    local valid_stages = {leg1 = true, leg2 = true, full = true, vps_tokyo = true, vps_us = true}
    if not valid_stages[stage] then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid stage"})
        return
    end
    local output = exec_output(DIAGNOSTICS .. " speedtest " .. stage .. " 2>/dev/null")
    local data = parse_json(output)
    luci.http.prepare_content("application/json")
    if data then
        luci.http.write_json(data)
    else
        luci.http.write_json({error = "speedtest failed", stage = stage, raw = output})
    end
end
function action_diagnostics()
    local chain_id = luci.http.formvalue("chain")
    if not chain_id then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "missing chain id"})
        return
    end
    local chain_json = db_cmd("get-chain " .. chain_id)
    local chain = parse_json(chain_json)
    if not chain or not chain.hop_path then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "chain not found"})
        return
    end
    -- 解析 hop_path 收集节点 IP
    local hop_ips = {}
    for hop_id in string.gmatch(chain.hop_path, "[^,]+") do
        local node_json = db_cmd("get-node " .. hop_id)
        local node = parse_json(node_json)
        if node and node.ip then
            hop_ips[#hop_ips+1] = {id = node.id, name = node.name, ip = node.ip, port = node.api_port or 8765}
        end
    end
    -- 对每段跳转测延迟:
    --   第一段 (路由器->首跳): ICMP ping 取 avg (ICMP 不被 sing-box TUN 捕获, 反映真实链路延迟)
    --   后续段 (上一跳->当前跳): 调用上一跳的 /ping?host=<当前跳IP> API (在上一跳 VPS 上执行 ping)
    -- 注意: 旧实现用 curl HTTP time_total, 会被 TUN 接管走代理链, 测出来是整条代理往返(1~2s), 不是段延迟。
    local legs = {}
    for i = 1, #hop_ips do
        local hop = hop_ips[i]
        if i == 1 then
            -- 第一段: 路由器 -> 首跳 (ICMP ping, 5 次; ICMP 不被 sing-box TUN 捕获)
            -- OpenWrt ping: "round-trip min/avg/max = 0.105/0.140/0.206 ms"
            -- 用 grep -oE 提取 "min/avg/max" 三个数值, awk 取第2个(avg)
            local cmd = "ping -c 5 -W 2 " .. hop.ip .. " 2>&1 | grep -oE '[0-9.]+/[0-9.]+/[0-9.]+' | head -1 | awk -F/ '{print $2}'"
            local avg = shell_popen(cmd):gsub("[^0-9.]", "")
            local latency = tonumber(avg)
            legs[#legs+1] = {
                segment = i,
                from = "本地网络",
                from_ip = "",
                to = hop.name,
                to_ip = hop.ip,
                -- 取整 ms, 最小 1 (避免 LAN 同网段 0.1ms 被四舍五入成 0 显示为"超时")
                latency_ms = latency and math.max(1, math.floor(latency + 0.5)) or nil,
                status = latency and "ok" or "timeout"
            }
        else
            -- 后续段: 上一跳 -> 当前跳 (经上一跳 VPS 的 ping API)
            -- curl 必须绑定 WAN 接口绕过 singbox-tun, 否则在 strict_route 下会被
            -- 策略路由表捕获进 TUN, Lua 子进程环境下会超时拿不到结果。
            local prev = hop_ips[i-1]
            local wan = get_wan_iface()
            local bind = wan and ("--interface " .. wan) or ""
            local api_result = shell_popen("curl -s --max-time 10 " .. bind .. " 'http://" .. prev.ip .. ":" .. prev.port .. "/ping?host=" .. hop.ip .. "' 2>/dev/null")
            local data = parse_json(api_result)
            local latency = data and tonumber(data.latency_ms)
            legs[#legs+1] = {
                segment = i,
                from = prev.name,
                from_ip = prev.ip,
                to = hop.name,
                to_ip = hop.ip,
                latency_ms = latency and math.floor(latency) or nil,
                status = latency and "ok" or "timeout"
            }
        end
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({chain_id = chain_id, legs = legs})
end
-- ---------------------------------------------------------------
-- 流量监控 API
-- ---------------------------------------------------------------
function action_traffic_devices()
    local log_file = "/var/log/sing-box.log"
    local leases_file = "/tmp/dhcp.leases"
    local devices = {}
    local output = luci.sys.exec("grep -oE 'from [0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+:' " .. log_file .. " 2>/dev/null | sed 's/from //; s/://' | sort | uniq -c | sort -rn")
    if output and #output > 0 then
        for line in output:gmatch("[^\r\n]+") do
            local count, ip = line:match("(%d+)%s+([0-9%.]+)")
            if count and ip then
                local name = luci.sys.exec("grep '" .. ip .. "' " .. leases_file .. " 2>/dev/null | awk '{print $4}' | head -1") or ""
                name = name:gsub("%s+", "")
                if name == "" or name == "*" then name = "" end
                devices[#devices+1] = {ip = ip, name = name, count = tonumber(count) or 0}
            end
        end
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({devices = devices})
end
function action_traffic_device()
    local target_ip = luci.http.formvalue("ip") or ""
    if not target_ip:match("^%d+%.%d+%.%d+%.%d+$") then
        luci.http.prepare_content("application/json")
        luci.http.write_json({error = "invalid ip", connections = {}})
        return
    end
    local log_file = "/var/log/sing-box.log"
    local leases_file = "/tmp/dhcp.leases"
    local name = shell_exec("grep '" .. target_ip .. "' " .. leases_file .. " 2>/dev/null | awk '{print $4}' | head -1") or ""
    name = name:gsub("%s+", "")
    if name == "" or name == "*" then name = target_ip end
    -- 高效方案：一次 grep from 行 + 一次 grep outbound to 行，awk 合并
    -- 避免 per-connection grep 48MB 日志
    local cmd = string.format([[
      grep 'from %s:' %s 2>/dev/null | awk '{cid=$5; gsub(/\[|\//, "", cid); print cid, $2, $3}' > /tmp/_traffic_from.txt
      grep 'outbound.* to ' %s 2>/dev/null | awk '{cid=$5; gsub(/\[|\//, "", cid); match($0, /to [^ ]+/); print cid, substr($0, RSTART+3, RLENGTH-3)}' > /tmp/_traffic_to.txt
      awk 'NR==FNR {to[$1]=$2; next} {dest=($1 in to)?to[$1]:"?"; sub(/:[0-9]+$/, "", dest); print $2" "$3"|"dest}' /tmp/_traffic_to.txt /tmp/_traffic_from.txt | sort -r | head -100
      rm -f /tmp/_traffic_from.txt /tmp/_traffic_to.txt
    ]], target_ip, log_file, log_file)
    local output = shell_exec(cmd)
    local connections = {}
    if output and #output > 0 then
        for line in output:gmatch("[^\r\n]+") do
            local time, dest = line:match("([^|]+)|(.+)")
            if time and dest then
                -- 去掉端口号 (xxx:80 -> xxx)
                dest = dest:gsub(":[0-9]+$", "")
                connections[#connections+1] = {time = time, name = name, dest = dest}
            end
        end
    end
    luci.http.prepare_content("application/json")
    luci.http.write_json({ip = target_ip, name = name, connections = connections})
end
-- ---------------------------------------------------------------
-- 首次配置向导 API
-- ---------------------------------------------------------------
function action_save_config()
    -- 1. 创建东京 VPS 节点
    local tokyo_name = luci.http.formvalue("tokyo_name") or "tokyo"
    local tokyo_ip = luci.http.formvalue("tokyo_ip") or ""
    local tokyo_ssh_port = luci.http.formvalue("tokyo_ssh_port") or "22"
    local tokyo_ssh_user = luci.http.formvalue("tokyo_ssh_user") or "root"
    local tokyo_ssh_password = luci.http.formvalue("tokyo_ssh_password") or ""
    local reality_sni = luci.http.formvalue("reality_sni") or "www.paypal.com"
    local reality_public_key = luci.http.formvalue("reality_public_key") or ""
    local vless_port = luci.http.formvalue("vless_port") or "443"
    local vless_uuid = luci.http.formvalue("vless_uuid") or ""
    if tokyo_ip == "" or vless_uuid == "" then
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "error", message = "东京 VPS IP 和 VLESS UUID 为必填"})
        return
    end
    local tokyo_json = string.format(
        '{"name":"%s","ip":"%s","role":"relay","protocol":"vless",' ..
        '"ssh_port":%s,"ssh_user":"%s","ssh_password":"%s",' ..
        '"vless_port":%s,"vless_uuid":"%s",' ..
        '"reality_sni":"%s","reality_public_key":"%s"}',
        tokyo_name, tokyo_ip, tokyo_ssh_port, tokyo_ssh_user, tokyo_ssh_password,
        vless_port, vless_uuid, reality_sni, reality_public_key
    )
    local tokyo_result = db_cmd("add-node '" .. tokyo_json:gsub("'", "'\\''") .. "'")
    local tokyo_data = parse_json(tokyo_result) or {}
    local tokyo_id = tokyo_data.id
    if not tokyo_id then
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "error", message = "东京 VPS 节点创建失败: " .. (tokyo_data.message or "")})
        return
    end
    -- 2. 创建美国 VPS 节点 (landing, VLESS+REALITY)
    local us_ip = luci.http.formvalue("us_ip") or ""
    local us_ssh_port = luci.http.formvalue("us_ssh_port") or "22"
    local us_ssh_user = luci.http.formvalue("us_ssh_user") or "root"
    local us_ssh_password = luci.http.formvalue("us_ssh_password") or ""
    if us_ip == "" then
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "error", message = "美国 VPS IP 为必填"})
        return
    end
    local us_json = string.format(
        '{"name":"us","ip":"%s","role":"landing","protocol":"vless",' ..
        '"ssh_port":%s,"ssh_user":"%s","ssh_password":"%s",' ..
        '"vless_port":%s,"vless_uuid":"%s",' ..
        '"reality_sni":"%s","reality_public_key":"%s"}',
        us_ip, us_ssh_port, us_ssh_user, us_ssh_password,
        vless_port, vless_uuid, reality_sni, reality_public_key
    )
    local us_result = db_cmd("add-node '" .. us_json:gsub("'", "'\\''") .. "'")
    local us_data = parse_json(us_result) or {}
    local us_id = us_data.id
    if not us_id then
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "error", message = "美国 VPS 节点创建失败: " .. (us_data.message or "")})
        return
    end
    -- 3. 创建链路
    local chain_name = luci.http.formvalue("chain_name") or "mmlive-us1"
    local wifi_ssid = luci.http.formvalue("wifi_ssid") or "mmlive"
    local source_ip = luci.http.formvalue("source_ip") or "192.168.5.10"
    local source_cidr = luci.http.formvalue("source_cidr") or (source_ip .. "/32")
    local hop_path = tostring(tokyo_id) .. "," .. tostring(us_id)
    local chain_json = string.format(
        '{"name":"%s","enabled":1,"source_ip":"%s","source_cidr":"%s",' ..
        '"wifi_ssid":"%s","hop_path":"%s"}',
        chain_name, source_ip, source_cidr, wifi_ssid, hop_path
    )
    db_cmd("add-chain '" .. chain_json:gsub("'", "'\\''") .. "'")
    -- 4. 后台部署测速 API + 生成配置 + 启动
    local ssh_pass = tokyo_ssh_password:gsub("'", "'\\''")
    os.execute("(" ..
        "sshpass -p '" .. ssh_pass .. "' scp -O -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -P " .. tokyo_ssh_port ..
        " /usr/bin/speedtest-api.sh " .. tokyo_ssh_user .. "@" .. tokyo_ip .. ":/usr/local/bin/speedtest-api.sh 2>/dev/null; " ..
        "sshpass -p '" .. ssh_pass .. "' ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -p " .. tokyo_ssh_port ..
        " " .. tokyo_ssh_user .. "@" .. tokyo_ip ..
        " 'chmod +x /usr/local/bin/speedtest-api.sh; apt-get install -y -qq socat 2>/dev/null; " ..
        "printf \"[Unit]\\nDescription=Speedtest API\\nAfter=network.target\\n\\n[Service]\\nExecStart=/usr/local/bin/speedtest-api.sh\\nRestart=always\\nRestartSec=3\\nUser=root\\n\\n[Install]\\nWantedBy=multi-user.target\\n\" > /etc/systemd/system/speedtest-api.service; " ..
        "systemctl daemon-reload; systemctl enable speedtest-api; systemctl restart speedtest-api' 2>/dev/null; " ..
        VPS_DB .. " update-node " .. tostring(tokyo_id) .. " '{\"api_deployed\":1}' 2>/dev/null; " ..
        GENERATOR .. " 2>&1; /usr/bin/sing-box check -c /etc/sing-box/config.json 2>&1; " ..
        "/etc/init.d/sing-box stop 2>/dev/null; sleep 3; killall -9 sing-box 2>/dev/null; ip link del singbox-tun 2>/dev/null; sleep 2; " ..
        "/etc/init.d/sing-box start 2>/dev/null" ..
        ") >/tmp/firstboot_apply.log 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        status = "ok",
        message = "配置已保存, 正在后台部署测速API并启动代理, 请约30秒后刷新页面",
        tokyo_id = tokyo_id,
        us_id = us_id,
        hop_path = hop_path
    })
end
-- ---------------------------------------------------------------
-- 设备更新管理 API
-- ---------------------------------------------------------------
-- 手动检查更新
function action_check_update()
    local output = exec_output("/usr/bin/chb-update --check 2>/dev/null")
    local data = parse_json(output)
    luci.http.prepare_content("application/json")
    if data then
        luci.http.write_json(data)
    else
        luci.http.write_json({success = false, message = "检查失败", raw = output})
    end
end
-- 立即应用更新 (后台执行)
function action_do_update()
    os.execute("(/usr/bin/chb-update --apply-now) >/tmp/chb-apply-update.log 2>&1 &")
    luci.http.prepare_content("application/json")
    luci.http.write_json({
        status = "applying",
        message = "正在后台应用更新, 请稍后查看状态"
    })
end
-- 获取更新状态
function action_update_status()
    local output = exec_output("/usr/bin/chb-update --status 2>/dev/null")
    local data = parse_json(output)
    luci.http.prepare_content("application/json")
    if data then
        luci.http.write_json(data)
    else
        luci.http.write_json({error = "failed to get status", raw = output})
    end
end
-- 获取/保存更新配置 (含 GitHub PAT)
function action_update_config()
    local method = luci.http.getenv("REQUEST_METHOD") or "GET"
    if method == "POST" then
        -- 保存配置
        local repo = luci.http.formvalue("repo")
        local check_interval = luci.http.formvalue("check_interval")
        local apply_window_start = luci.http.formvalue("apply_window_start")
        local apply_window_end = luci.http.formvalue("apply_window_end")
        local github_token = luci.http.formvalue("github_token")
        if repo and #repo > 0 then
            os.execute("uci -q set chb-update.main.repo='" .. repo:gsub("'", "") .. "'")
        end
        if check_interval and #check_interval > 0 then
            os.execute("uci -q set chb-update.main.check_interval='" .. tonumber(check_interval) .. "'")
        end
        if apply_window_start and #apply_window_start > 0 then
            os.execute("uci -q set chb-update.main.apply_window_start='" .. apply_window_start:gsub("'", "") .. "'")
        end
        if apply_window_end and #apply_window_end > 0 then
            os.execute("uci -q set chb-update.main.apply_window_end='" .. apply_window_end:gsub("'", "") .. "'")
        end
        os.execute("uci -q commit chb-update")
        -- 保存 GitHub PAT (非空时更新)
        if github_token and #github_token > 0 then
            os.execute("mkdir -p /etc/chb")
            local token_safe = github_token:gsub("'", "'\\''")
            os.execute("printf '%s' '" .. token_safe .. "' > /etc/chb/github-token && chmod 600 /etc/chb/github-token")
        end
        luci.http.prepare_content("application/json")
        luci.http.write_json({status = "ok", message = "配置已保存"})
    else
        -- 获取当前配置
        local repo = luci.sys.exec("uci -q get chb-update.main.repo 2>/dev/null") or ""
        repo = repo:gsub("%s+", "")
        local check_interval = luci.sys.exec("uci -q get chb-update.main.check_interval 2>/dev/null") or ""
        check_interval = check_interval:gsub("%s+", "")
        local apply_window_start = luci.sys.exec("uci -q get chb-update.main.apply_window_start 2>/dev/null") or ""
        apply_window_start = apply_window_start:gsub("%s+", "")
        local apply_window_end = luci.sys.exec("uci -q get chb-update.main.apply_window_end 2>/dev/null") or ""
        apply_window_end = apply_window_end:gsub("%s+", "")
        local has_token = "false"
        if nixio.fs.access("/etc/chb/github-token") then
            has_token = "true"
        end
        luci.http.prepare_content("application/json")
        luci.http.write_json({
            repo = repo ~= "" and repo or "caoxuefei/wifi",
            check_interval = tonumber(check_interval) or 3600,
            apply_window_start = apply_window_start ~= "" and apply_window_start or "02:00",
            apply_window_end = apply_window_end ~= "" and apply_window_end or "02:30",
            has_token = has_token
        })
    end
end
