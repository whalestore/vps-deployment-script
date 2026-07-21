#!/bin/sh
# ================================================================
#  vps-db.sh — VPS 节点和链路的 SQLite 管理工具 (OpenWrt ash 兼容)
#  数据库: /etc/sing-box/vps.db
#
#  用法:
#    vps-db.sh init                                    — 创建数据库 + 表
#    vps-db.sh list-nodes                              — 列出所有 VPS 节点 (JSON 数组)
#    vps-db.sh get-node <id>                           — 获取单个节点 (JSON 对象)
#    vps-db.sh add-node '<json>'                       — 从 JSON 添加节点
#    vps-db.sh update-node <id> '<json>'               — 从 JSON 更新节点
#    vps-db.sh delete-node <id>                        — 删除节点
#    vps-db.sh list-chains                             — 列出所有链路 (JSON 数组)
#    vps-db.sh get-chain <id>                          — 获取链路含 hops 详情 (JSON)
#    vps-db.sh add-chain '<json>'                      — 从 JSON 添加链路
#    vps-db.sh update-chain <id> '<json>'              — 从 JSON 更新链路
#    vps-db.sh delete-chain <id>                       — 删除链路
#    vps-db.sh get-chain-config                        — 获取所有启用链路含 hops (供配置生成)
#    vps-db.sh list-subnets                           - 列出所有子网 (JSON 数组)
#    vps-db.sh get-subnet <id>                        - 获取单个子网 (JSON)
#    vps-db.sh add-subnet '<json>'                    - 添加子网
#    vps-db.sh update-subnet <id> '<json>'            - 更新子网
#    vps-db.sh delete-subnet <id>                     - 删除子网
#    vps-db.sh bind-subnet <id> <chain_id>            - 绑定子网到链路
#    vps-db.sh unbind-subnet <id>                     - 解绑子网
#    vps-db.sh get-active-config                      - 获取启用链路+绑定子网cidr (供配置生成)
#
#  依赖: sqlite3, jq
#  无 python3 依赖
# ================================================================

DB_FILE="/etc/sing-box/vps.db"

# ---------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------

# SQL 字符串转义: 单引号加倍, 防 SQL 注入
sql_escape() {
    printf '%s' "$1" | sed "s/'/''/g"
}

# 执行查询并以 JSON 输出; 无结果时输出空 (调用方决定补 [] 或 {})
db_json() {
    sqlite3 -json "$DB_FILE" "$1" 2>/dev/null
}

# 执行非查询 SQL (INSERT/UPDATE/DELETE/CREATE), 不输出
db_exec() {
    sqlite3 "$DB_FILE" "$1" 2>/dev/null
}

# 从 JSON 中提取字符串字段 (带默认值)
jstr() {
    local json="$1" key="$2" def="$3"
    echo "$json" | jq -r --arg k "$key" --arg d "$def" '.[$k] // $d'
}

# 从 JSON 中提取整数字段 (带默认值)
jint() {
    local json="$1" key="$2" def="$3"
    echo "$json" | jq -r --arg k "$key" --argjson d "$def" '.[$k] // $d'
}

# ---------------------------------------------------------------
# init: 创建数据库和表
# ---------------------------------------------------------------

cmd_init() {
    mkdir -p "$(dirname "$DB_FILE")"
    db_exec "
CREATE TABLE IF NOT EXISTS vps_nodes (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    name              TEXT NOT NULL,
    ip                TEXT NOT NULL,
    role              TEXT DEFAULT 'relay',
    ssh_port          INTEGER DEFAULT 22,
    ssh_user          TEXT DEFAULT 'root',
    ssh_password      TEXT DEFAULT '',
    protocol          TEXT DEFAULT 'vless',
    vless_port        INTEGER DEFAULT 443,
    vless_uuid        TEXT DEFAULT '',
    reality_sni       TEXT DEFAULT 'www.paypal.com',
    reality_public_key TEXT DEFAULT '',
    reality_private_key TEXT DEFAULT '',
    api_port          INTEGER DEFAULT 8765,
    api_deployed      INTEGER DEFAULT 0,
    notes             TEXT DEFAULT '',
    node_uuid         TEXT DEFAULT '',
    init_status       TEXT DEFAULT 'pending',
    init_message      TEXT DEFAULT '',
    init_port         INTEGER DEFAULT 0,
    created_at        TEXT DEFAULT (datetime('now','localtime')),
    updated_at        TEXT DEFAULT (datetime('now','localtime'))
);
CREATE TABLE IF NOT EXISTS chains (
    id                INTEGER PRIMARY KEY AUTOINCREMENT,
    name              TEXT NOT NULL,
    enabled           INTEGER DEFAULT 1,
    source_ip         TEXT DEFAULT '',
    source_cidr       TEXT DEFAULT '',
    wifi_ssid         TEXT DEFAULT '',
    ap_mac            TEXT DEFAULT '',
    ap_ip             TEXT DEFAULT '',
    hop_path          TEXT NOT NULL,
    created_at        TEXT DEFAULT (datetime('now','localtime')),
    updated_at        TEXT DEFAULT (datetime('now','localtime'))
);
CREATE TABLE IF NOT EXISTS settings (
    id                         INTEGER PRIMARY KEY DEFAULT 1,
    default_protocol           TEXT DEFAULT 'vless',
    default_ssh_port           INTEGER DEFAULT 22,
    default_ssh_user           TEXT DEFAULT 'root',
    default_vless_port         INTEGER DEFAULT 443,
    default_vless_uuid         TEXT DEFAULT '',
    default_reality_sni        TEXT DEFAULT 'www.paypal.com',
    default_reality_public_key TEXT DEFAULT '',
    default_reality_private_key TEXT DEFAULT '',
    default_api_port           INTEGER DEFAULT 8765,
    updated_at                 TEXT DEFAULT (datetime('now','localtime'))
);
CREATE TABLE IF NOT EXISTS subnets (
    id          INTEGER PRIMARY KEY AUTOINCREMENT,
    name        TEXT NOT NULL,
    interface   TEXT NOT NULL,
    cidr        TEXT NOT NULL,
    gateway     TEXT DEFAULT '',
    ap_ip       TEXT DEFAULT '',
    ap_mac      TEXT DEFAULT '',
    wifi_ssid   TEXT DEFAULT '',
    chain_id    INTEGER DEFAULT NULL,
    enabled     INTEGER DEFAULT 1,
    created_at  TEXT DEFAULT (datetime('now','localtime')),
    updated_at  TEXT DEFAULT (datetime('now','localtime'))
);
INSERT OR IGNORE INTO settings (id) VALUES (1);
"
    # 兼容已存在数据库: 逐字段检测并 ALTER TABLE ADD COLUMN
    for col in node_uuid init_status init_message init_port reality_private_key; do
        if ! sqlite3 "$DB_FILE" "PRAGMA table_info(vps_nodes);" 2>/dev/null | grep -q "$col"; then
            case "$col" in
                node_uuid|init_status|init_message|reality_private_key)
                    sqlite3 "$DB_FILE" "ALTER TABLE vps_nodes ADD COLUMN $col TEXT DEFAULT '';" 2>/dev/null
                    ;;
                init_port)
                    sqlite3 "$DB_FILE" "ALTER TABLE vps_nodes ADD COLUMN $col INTEGER DEFAULT 0;" 2>/dev/null
                    ;;
            esac
        fi
    done
    # 兼容 settings 表: 检测 default_reality_private_key
    if ! sqlite3 "$DB_FILE" "PRAGMA table_info(settings);" 2>/dev/null | grep -q "default_reality_private_key"; then
        sqlite3 "$DB_FILE" "ALTER TABLE settings ADD COLUMN default_reality_private_key TEXT DEFAULT '';" 2>/dev/null
    fi
    if [ $? -eq 0 ]; then
        chmod 600 "$DB_FILE" 2>/dev/null
        echo "{\"status\":\"ok\",\"db\":\"$DB_FILE\"}"
    else
        echo "{\"status\":\"error\",\"message\":\"failed to init database\"}"
        exit 1
    fi
}

# ---------------------------------------------------------------
# 节点 CRUD
# ---------------------------------------------------------------

cmd_list_nodes() {
    local out
    out=$(db_json "SELECT * FROM vps_nodes ORDER BY id")
    if [ -z "$out" ]; then
        echo "[]"
    else
        echo "$out"
    fi
}

cmd_get_node() {
    local id="$1"
    local out
    out=$(db_json "SELECT * FROM vps_nodes WHERE id=$id")
    if [ -z "$out" ]; then
        echo "{}"
    else
        echo "$out" | jq -c '.[0]'
    fi
}

cmd_add_node() {
    local json="$1"
    local name ip role ssh_port ssh_user ssh_password protocol
    local vless_port vless_uuid reality_sni reality_public_key
    local api_port api_deployed notes

    name=$(jstr "$json" name "")
    ip=$(jstr "$json" ip "")
    role=$(jstr "$json" role "relay")
    ssh_port=$(jint "$json" ssh_port 22)
    ssh_user=$(jstr "$json" ssh_user "root")
    ssh_password=$(jstr "$json" ssh_password "")
    protocol=$(jstr "$json" protocol "vless")
    vless_port=$(jint "$json" vless_port 443)
    vless_uuid=$(jstr "$json" vless_uuid "")
    reality_sni=$(jstr "$json" reality_sni "www.paypal.com")
    reality_public_key=$(jstr "$json" reality_public_key "")
    api_port=$(jint "$json" api_port 8765)
    api_deployed=$(jint "$json" api_deployed 0)
    notes=$(jstr "$json" notes "")

    if [ -z "$name" ] || [ -z "$ip" ]; then
        echo "{\"status\":\"error\",\"message\":\"name and ip are required\"}"
        exit 1
    fi

    local sql
    sql="INSERT INTO vps_nodes (name,ip,role,ssh_port,ssh_user,ssh_password,protocol,vless_port,vless_uuid,reality_sni,reality_public_key,api_port,api_deployed,notes) VALUES ('$(sql_escape "$name")','$(sql_escape "$ip")','$(sql_escape "$role")',$ssh_port,'$(sql_escape "$ssh_user")','$(sql_escape "$ssh_password")','$(sql_escape "$protocol")',$vless_port,'$(sql_escape "$vless_uuid")','$(sql_escape "$reality_sni")','$(sql_escape "$reality_public_key")',$api_port,$api_deployed,'$(sql_escape "$notes")'); SELECT last_insert_rowid();"
    local new_id
    new_id=$(sqlite3 "$DB_FILE" "$sql" 2>/dev/null)
    if [ -n "$new_id" ]; then
        echo "{\"status\":\"ok\",\"id\":$new_id}"
    else
        echo "{\"status\":\"error\",\"message\":\"insert failed\"}"
        exit 1
    fi
}

cmd_update_node() {
    local id="$1"
    local json="$2"
    local set_clause=""
    local sep=""

    # 逐字段检查: 仅更新 JSON 中存在的字段
    _add_set_str() {
        local col="$1" key="$2"
        local present
        present=$(echo "$json" | jq -r --arg k "$key" 'has($k)')
        if [ "$present" = "true" ]; then
            local val
            val=$(echo "$json" | jq -r --arg k "$key" '.[$k]')
            set_clause="$set_clause$sep$col='$(sql_escape "$val")'"
            sep=", "
        fi
    }
    _add_set_int() {
        local col="$1" key="$2"
        local present
        present=$(echo "$json" | jq -r --arg k "$key" 'has($k)')
        if [ "$present" = "true" ]; then
            local val
            val=$(echo "$json" | jq -r --arg k "$key" '.[$k]')
            set_clause="$set_clause$sep$col=$val"
            sep=", "
        fi
    }

    _add_set_str name name
    _add_set_str ip ip
    _add_set_str role role
    _add_set_int ssh_port ssh_port
    _add_set_str ssh_user ssh_user
    _add_set_str ssh_password ssh_password
    _add_set_str protocol protocol
    _add_set_int vless_port vless_port
    _add_set_str vless_uuid vless_uuid
    _add_set_str reality_sni reality_sni
    _add_set_str reality_public_key reality_public_key
    _add_set_str reality_private_key reality_private_key
    _add_set_int api_port api_port
    _add_set_int api_deployed api_deployed
    _add_set_str notes notes
    _add_set_str node_uuid node_uuid
    _add_set_str init_status init_status
    _add_set_str init_message init_message
    _add_set_int init_port init_port

    if [ -z "$set_clause" ]; then
        echo "{\"status\":\"error\",\"message\":\"no fields to update\"}"
        exit 1
    fi

    local sql
    sql="UPDATE vps_nodes SET $set_clause, updated_at=datetime('now','localtime') WHERE id=$id;"
    db_exec "$sql"
    echo "{\"status\":\"ok\",\"id\":$id}"
}

cmd_delete_node() {
    local id="$1"
    db_exec "DELETE FROM vps_nodes WHERE id=$id;"
    echo "{\"status\":\"ok\",\"id\":$id}"
}

# ---------------------------------------------------------------
# 全局设置 CRUD
# ---------------------------------------------------------------

cmd_get_settings() {
    local out
    out=$(db_json "SELECT * FROM settings WHERE id=1")
    if [ -z "$out" ]; then
        echo "{}"
    else
        echo "$out" | jq -c '.[0]'
    fi
}

cmd_set_settings() {
    local json="$1"
    local set_clause=""
    local sep=""

    _ss_add_set_str() {
        local col="$1" key="$2"
        local present
        present=$(echo "$json" | jq -r --arg k "$key" 'has($k)')
        if [ "$present" = "true" ]; then
            local val
            val=$(echo "$json" | jq -r --arg k "$key" '.[$k]')
            set_clause="$set_clause$sep$col='$(sql_escape "$val")'"
            sep=", "
        fi
    }
    _ss_add_set_int() {
        local col="$1" key="$2"
        local present
        present=$(echo "$json" | jq -r --arg k "$key" 'has($k)')
        if [ "$present" = "true" ]; then
            local val
            val=$(echo "$json" | jq -r --arg k "$key" '.[$k]')
            set_clause="$set_clause$sep$col=$val"
            sep=", "
        fi
    }

    _ss_add_set_str default_protocol default_protocol
    _ss_add_set_int default_ssh_port default_ssh_port
    _ss_add_set_str default_ssh_user default_ssh_user
    _ss_add_set_int default_vless_port default_vless_port
    _ss_add_set_str default_vless_uuid default_vless_uuid
    _ss_add_set_str default_reality_sni default_reality_sni
    _ss_add_set_str default_reality_public_key default_reality_public_key
    _ss_add_set_str default_reality_private_key default_reality_private_key
    _ss_add_set_int default_api_port default_api_port

    if [ -z "$set_clause" ]; then
        echo "{\"status\":\"error\",\"message\":\"no fields to update\"}"
        exit 1
    fi

    local sql
    sql="UPDATE settings SET $set_clause, updated_at=datetime('now','localtime') WHERE id=1;"
    db_exec "$sql"
    echo "{\"status\":\"ok\"}"
}

# ---------------------------------------------------------------
# 链路 CRUD
# ---------------------------------------------------------------

cmd_list_chains() {
    local out
    out=$(db_json "SELECT * FROM chains ORDER BY id")
    if [ -z "$out" ]; then
        echo "[]"
    else
        echo "$out"
    fi
}

# 将 hop_path (逗号分隔的节点 ID) 展开为节点对象数组 (hops)
# 输出: [node1,node2,...]  (缺失节点为 null)
build_hops() {
    local hop_path="$1"
    local hops="[" first=1 nid node_json node_obj
    for nid in $(echo "$hop_path" | tr ',' ' '); do
        node_json=$(db_json "SELECT * FROM vps_nodes WHERE id=$nid")
        if [ -z "$node_json" ]; then
            node_obj="null"
        else
            node_obj=$(echo "$node_json" | jq -c '.[0]' 2>/dev/null)
            if [ -z "$node_obj" ] || [ "$node_obj" = "null" ]; then
                node_obj="null"
            fi
        fi
        if [ "$first" = "1" ]; then
            hops="$hops$node_obj"
            first=0
        else
            hops="$hops,$node_obj"
        fi
    done
    hops="$hops]"
    printf '%s' "$hops"
}

get_one_chain_with_hops() {
    local chain_json="$1" hop_path="$2"
    local hops
    hops=$(build_hops "$hop_path")
    echo "$chain_json" | jq -c --argjson h "$hops" '. + {hops: $h}'
}

cmd_get_chain() {
    local id="$1"
    local out
    out=$(db_json "SELECT * FROM chains WHERE id=$id")
    if [ -z "$out" ]; then
        echo "{}"
        return
    fi
    local chain_json hop_path
    chain_json=$(echo "$out" | jq -c '.[0]')
    hop_path=$(echo "$chain_json" | jq -r '.hop_path')
    get_one_chain_with_hops "$chain_json" "$hop_path"
}

cmd_add_chain() {
    local json="$1"
    local name enabled source_ip source_cidr wifi_ssid ap_mac ap_ip hop_path

    name=$(jstr "$json" name "")
    enabled=$(jint "$json" enabled 1)
    source_ip=$(jstr "$json" source_ip "")
    source_cidr=$(jstr "$json" source_cidr "")
    wifi_ssid=$(jstr "$json" wifi_ssid "")
    ap_mac=$(jstr "$json" ap_mac "")
    ap_ip=$(jstr "$json" ap_ip "")
    hop_path=$(jstr "$json" hop_path "")

    if [ -z "$name" ] || [ -z "$hop_path" ]; then
        echo "{\"status\":\"error\",\"message\":\"name and hop_path are required\"}"
        exit 1
    fi

    local sql
    sql="INSERT INTO chains (name,enabled,source_ip,source_cidr,wifi_ssid,ap_mac,ap_ip,hop_path) VALUES ('$(sql_escape "$name")',$enabled,'$(sql_escape "$source_ip")','$(sql_escape "$source_cidr")','$(sql_escape "$wifi_ssid")','$(sql_escape "$ap_mac")','$(sql_escape "$ap_ip")','$(sql_escape "$hop_path")'); SELECT last_insert_rowid();"
    local new_id
    new_id=$(sqlite3 "$DB_FILE" "$sql" 2>/dev/null)
    if [ -n "$new_id" ]; then
        echo "{\"status\":\"ok\",\"id\":$new_id}"
    else
        echo "{\"status\":\"error\",\"message\":\"insert failed\"}"
        exit 1
    fi
}

cmd_update_chain() {
    local id="$1"
    local json="$2"
    local set_clause=""
    local sep=""

    _add_set_str() {
        local col="$1" key="$2"
        local present
        present=$(echo "$json" | jq -r --arg k "$key" 'has($k)')
        if [ "$present" = "true" ]; then
            local val
            val=$(echo "$json" | jq -r --arg k "$key" '.[$k]')
            set_clause="$set_clause$sep$col='$(sql_escape "$val")'"
            sep=", "
        fi
    }
    _add_set_int() {
        local col="$1" key="$2"
        local present
        present=$(echo "$json" | jq -r --arg k "$key" 'has($k)')
        if [ "$present" = "true" ]; then
            local val
            val=$(echo "$json" | jq -r --arg k "$key" '.[$k]')
            set_clause="$set_clause$sep$col=$val"
            sep=", "
        fi
    }

    _add_set_str name name
    _add_set_int enabled enabled
    _add_set_str source_ip source_ip
    _add_set_str source_cidr source_cidr
    _add_set_str wifi_ssid wifi_ssid
    _add_set_str ap_mac ap_mac
    _add_set_str ap_ip ap_ip
    _add_set_str hop_path hop_path
    _add_set_str policy_name policy_name

    if [ -z "$set_clause" ]; then
        echo "{\"status\":\"error\",\"message\":\"no fields to update\"}"
        exit 1
    fi

    local sql
    sql="UPDATE chains SET $set_clause, updated_at=datetime('now','localtime') WHERE id=$id;"
    db_exec "$sql"
    echo "{\"status\":\"ok\",\"id\":$id}"
}

cmd_delete_chain() {
    local id="$1"
    db_exec "DELETE FROM chains WHERE id=$id;"
    echo "{\"status\":\"ok\",\"id\":$id}"
}

# 获取所有启用链路含 hops 展开 (供 generate-config.sh 消费)
cmd_get_chain_config() {
    local out
    out=$(db_json "SELECT * FROM chains WHERE enabled=1 ORDER BY id")
    if [ -z "$out" ]; then
        echo "[]"
        return
    fi

    local result="[" first_chain=1 cid one hop_path enriched
    for cid in $(echo "$out" | jq -r '.[].id'); do
        one=$(echo "$out" | jq -c --argjson cid "$cid" '.[] | select(.id==$cid)')
        hop_path=$(echo "$one" | jq -r '.hop_path')
        enriched=$(get_one_chain_with_hops "$one" "$hop_path")
        if [ "$first_chain" = "1" ]; then
            result="$result$enriched"
            first_chain=0
        else
            result="$result,$enriched"
        fi
    done
    result="$result]"
    echo "$result"
}

# ---------------------------------------------------------------
# 子网 (subnets) CRUD
# ---------------------------------------------------------------

cmd_list_subnets() {
    local out
    out=$(db_json "SELECT * FROM subnets ORDER BY id")
    if [ -z "$out" ]; then
        echo "[]"
    else
        echo "$out"
    fi
}

cmd_get_subnet() {
    local id="$1"
    local out
    out=$(db_json "SELECT * FROM subnets WHERE id=$id")
    if [ -z "$out" ]; then
        echo "{}"
    else
        echo "$out" | jq -c '.[0]'
    fi
}

cmd_add_subnet() {
    local json="$1"
    local name interface cidr gateway ap_ip ap_mac wifi_ssid chain_id enabled

    name=$(jstr "$json" name "")
    interface=$(jstr "$json" interface "")
    cidr=$(jstr "$json" cidr "")
    gateway=$(jstr "$json" gateway "")
    ap_ip=$(jstr "$json" ap_ip "")
    ap_mac=$(jstr "$json" ap_mac "")
    wifi_ssid=$(jstr "$json" wifi_ssid "")
    chain_id=$(jstr "$json" chain_id "")
    enabled=$(jint "$json" enabled 1)

    if [ -z "$name" ] || [ -z "$interface" ] || [ -z "$cidr" ]; then
        echo "{\"status\":\"error\",\"message\":\"name, interface, cidr are required\"}"
        exit 1
    fi
    # chain_id 空 -> NULL, 否则整数
    local chain_val
    if [ -z "$chain_id" ] || [ "$chain_id" = "null" ] || [ "$chain_id" = "" ]; then
        chain_val="NULL"
    else
        chain_val="$chain_id"
    fi

    local sql
    sql="INSERT INTO subnets (name,interface,cidr,gateway,ap_ip,ap_mac,wifi_ssid,chain_id,enabled) VALUES ('$(sql_escape "$name")','$(sql_escape "$interface")','$(sql_escape "$cidr")','$(sql_escape "$gateway")','$(sql_escape "$ap_ip")','$(sql_escape "$ap_mac")','$(sql_escape "$wifi_ssid")',$chain_val,$enabled); SELECT last_insert_rowid();"
    local new_id
    new_id=$(sqlite3 "$DB_FILE" "$sql" 2>/dev/null)
    if [ -n "$new_id" ]; then
        echo "{\"status\":\"ok\",\"id\":$new_id}"
    else
        echo "{\"status\":\"error\",\"message\":\"insert failed\"}"
        exit 1
    fi
}

cmd_update_subnet() {
    local id="$1"
    local json="$2"
    local set_clause=""
    local sep=""

    _su_str() {
        local col="$1" key="$2"
        local present
        present=$(echo "$json" | jq -r --arg k "$key" 'has($k)')
        if [ "$present" = "true" ]; then
            local val
            val=$(echo "$json" | jq -r --arg k "$key" '.[$k]')
            set_clause="$set_clause$sep$col='$(sql_escape "$val")'"
            sep=", "
        fi
    }
    _su_int() {
        local col="$1" key="$2"
        local present
        present=$(echo "$json" | jq -r --arg k "$key" 'has($k)')
        if [ "$present" = "true" ]; then
            local val
            val=$(echo "$json" | jq -r --arg k "$key" '.[$k]')
            set_clause="$set_clause$sep$col=$val"
            sep=", "
        fi
    }

    _su_str name name
    _su_str interface interface
    _su_str cidr cidr
    _su_str gateway gateway
    _su_str ap_ip ap_ip
    _su_str ap_mac ap_mac
    _su_str wifi_ssid wifi_ssid
    _su_int enabled enabled

    # chain_id 特殊: null 字符串 -> SQL NULL
    local has_chain
    has_chain=$(echo "$json" | jq -r 'has("chain_id")')
    if [ "$has_chain" = "true" ]; then
        local cval
        cval=$(echo "$json" | jq -r '.chain_id')
        if [ "$cval" = "null" ] || [ -z "$cval" ]; then
            set_clause="$set_clause$sep chain_id=NULL"
        else
            set_clause="$set_clause$sep chain_id=$cval"
        fi
        sep=", "
    fi

    if [ -z "$set_clause" ]; then
        echo "{\"status\":\"ok\",\"id\":$id,\"note\":\"no changes\"}"
        return
    fi
    db_exec "UPDATE subnets SET $set_clause, updated_at=datetime('now','localtime') WHERE id=$id;"
    echo "{\"status\":\"ok\",\"id\":$id}"
}

cmd_delete_subnet() {
    local id="$1"
    db_exec "DELETE FROM subnets WHERE id=$id;"
    echo "{\"status\":\"ok\",\"id\":$id}"
}

cmd_bind_subnet() {
    local id="$1" chain_id="$2"
    db_exec "UPDATE subnets SET chain_id=$chain_id, updated_at=datetime('now','localtime') WHERE id=$id;"
    echo "{\"status\":\"ok\",\"id\":$id,\"chain_id\":$chain_id}"
}

cmd_unbind_subnet() {
    local id="$1"
    db_exec "UPDATE subnets SET chain_id=NULL, updated_at=datetime('now','localtime') WHERE id=$id;"
    echo "{\"status\":\"ok\",\"id\":$id}"
}

# 获取所有启用链路 + 绑定子网的 cidr 聚合 (供 generate-config.sh 消费)
# 每条 chain 输出含 hops 数组 + cidrs 数组
# cidrs 来源: subnets 表中 chain_id=本链路且 enabled=1 的记录
#   若无子网绑定, 回退到 chain.source_cidr (向后兼容)
cmd_get_active_config() {
    local out
    out=$(db_json "SELECT * FROM chains WHERE enabled=1 ORDER BY id")
    if [ -z "$out" ]; then
        echo "[]"
        return
    fi

    local result="[" first_chain=1 cid one hop_path enriched subnets_out subnets_cidrs
    for cid in $(echo "$out" | jq -r '.[].id'); do
        one=$(echo "$out" | jq -c --argjson cid "$cid" '.[] | select(.id==$cid)')
        hop_path=$(echo "$one" | jq -r '.hop_path')
        enriched=$(get_one_chain_with_hops "$one" "$hop_path")
        # 聚合绑定此链路的子网 cidr
        subnets_out=$(db_json "SELECT cidr FROM subnets WHERE chain_id=$cid AND enabled=1 ORDER BY id")
        if [ -n "$subnets_out" ]; then
            subnets_cidrs=$(echo "$subnets_out" | jq -c '[.[].cidr]')
        else
            # 回退: 用 chain.source_cidr
            local src_cidr
            src_cidr=$(echo "$one" | jq -r '.source_cidr // ""')
            if [ -n "$src_cidr" ]; then
                subnets_cidrs='["'"$src_cidr"'"]'
            else
                subnets_cidrs="[]"
            fi
        fi
        enriched=$(echo "$enriched" | jq -c --argjson c "$subnets_cidrs" '. + {cidrs: $c}')
        if [ "$first_chain" = "1" ]; then
            result="$result$enriched"
            first_chain=0
        else
            result="$result,$enriched"
        fi
    done
    result="$result]"
    echo "$result"
}

# ---------------------------------------------------------------
# 主入口
# ---------------------------------------------------------------

case "${1:-}" in
    init)
        cmd_init
        ;;
    list-nodes)
        cmd_list_nodes
        ;;
    get-node)
        [ -z "${2:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: get-node <id>\"}"; exit 1; }
        cmd_get_node "$2"
        ;;
    add-node)
        [ -z "${2:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: add-node '<json>'\"}"; exit 1; }
        cmd_add_node "$2"
        ;;
    update-node)
        [ -z "${2:-}" ] || [ -z "${3:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: update-node <id> '<json>'\"}"; exit 1; }
        cmd_update_node "$2" "$3"
        ;;
    delete-node)
        [ -z "${2:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: delete-node <id>\"}"; exit 1; }
        cmd_delete_node "$2"
        ;;
    list-chains)
        cmd_list_chains
        ;;
    get-chain)
        [ -z "${2:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: get-chain <id>\"}"; exit 1; }
        cmd_get_chain "$2"
        ;;
    add-chain)
        [ -z "${2:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: add-chain '<json>'\"}"; exit 1; }
        cmd_add_chain "$2"
        ;;
    update-chain)
        [ -z "${2:-}" ] || [ -z "${3:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: update-chain <id> '<json>'\"}"; exit 1; }
        cmd_update_chain "$2" "$3"
        ;;
    delete-chain)
        [ -z "${2:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: delete-chain <id>\"}"; exit 1; }
        cmd_delete_chain "$2"
        ;;
    get-chain-config)
        cmd_get_chain_config
        ;;
    get-active-config)
        cmd_get_active_config
        ;;
    list-subnets)
        cmd_list_subnets
        ;;
    get-subnet)
        [ -z "${2:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: get-subnet <id>\"}"; exit 1; }
        cmd_get_subnet "$2"
        ;;
    add-subnet)
        [ -z "${2:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: add-subnet '<json>'\"}"; exit 1; }
        cmd_add_subnet "$2"
        ;;
    update-subnet)
        [ -z "${2:-}" ] || [ -z "${3:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: update-subnet <id> '<json>'\"}"; exit 1; }
        cmd_update_subnet "$2" "$3"
        ;;
    delete-subnet)
        [ -z "${2:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: delete-subnet <id>\"}"; exit 1; }
        cmd_delete_subnet "$2"
        ;;
    bind-subnet)
        [ -z "${2:-}" ] || [ -z "${3:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: bind-subnet <id> <chain_id>\"}"; exit 1; }
        cmd_bind_subnet "$2" "$3"
        ;;
    unbind-subnet)
        [ -z "${2:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: unbind-subnet <id>\"}"; exit 1; }
        cmd_unbind_subnet "$2"
        ;;
    get-settings)
        cmd_get_settings
        ;;
    set-settings)
        [ -z "${2:-}" ] && { echo "{\"status\":\"error\",\"message\":\"usage: set-settings '<json>'\"}"; exit 1; }
        cmd_set_settings "$2"
        ;;
    *)
        echo "用法: vps-db.sh <command> [args]"
        echo "  init                                    — 创建数据库 + 表"
        echo "  list-nodes                              — 列出所有 VPS 节点 (JSON)"
        echo "  get-node <id>                           — 获取单个节点 (JSON)"
        echo "  add-node '<json>'                       — 添加节点"
        echo "  update-node <id> '<json>'               — 更新节点"
        echo "  delete-node <id>                        — 删除节点"
        echo "  list-chains                             — 列出所有链路 (JSON)"
        echo "  get-chain <id>                          — 获取链路含 hops (JSON)"
        echo "  add-chain '<json>'                      — 添加链路"
        echo "  update-chain <id> '<json>'              — 更新链路"
        echo "  delete-chain <id>                       — 删除链路"
        echo "  get-chain-config                        — 获取所有启用链路含 hops"
        echo "  get-active-config                       — 获取启用链路含 hops+cidrs (供配置生成)"
        echo "  list-subnets                            — 列出所有子网 (JSON)"
        echo "  get-subnet <id>                         — 获取单个子网 (JSON)"
        echo "  add-subnet '<json>'                     — 添加子网"
        echo "  update-subnet <id> '<json>'             — 更新子网"
        echo "  delete-subnet <id>                      — 删除子网"
        echo "  bind-subnet <id> <chain_id>             — 绑定子网到链路"
        echo "  unbind-subnet <id>                      — 解绑子网"
        echo "  get-settings                             - 获取全局设置 (JSON)"
        echo "  set-settings '<json>'                     - 更新全局设置"
        exit 1
        ;;
esac
