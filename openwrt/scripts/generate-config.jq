# generate-config.jq - sing-box 配置生成的 jq 脚本
# 由 generate-config.sh 调用, 输入: --slurpfile chains + --slurpfile routing + --arg dns_detour + --arg final_tag

# 输入: chains 数组 (含 hops + resolved_cidrs) + routing rules
def chains: $chains[0];
def routing: $routing[0];

# 为单个 hop 生成 VLESS outbound 对象
def hop_vless_outbound(chain_id; hop_idx; hop; prev_tag):
    {
        tag: ("chain" + (chain_id|tostring) + "-hop" + (hop_idx|tostring)),
        type: "vless"
    } as $base
    | (if prev_tag == null then $base else $base + {detour: prev_tag} end) as $b2
    | $b2 + {
        server: hop.ip,
        server_port: (hop.init_port // hop.vless_port // 443),
        uuid: (hop.vless_uuid // ""),
        flow: "xtls-rprx-vision",
        tls: {
            enabled: true,
            server_name: (hop.reality_sni // "www.paypal.com"),
            utls: { enabled: true, fingerprint: "chrome" },
            reality: {
                enabled: true,
                public_key: (hop.reality_public_key // ""),
                short_id: ""
            }
        }
    };

# 为一条链路遍历 hops, 收集 vless outbounds
def chain_hops(chain):
    chain as $c |
    reduce range(0; ($c.hops | length)) as $i (
        {outbounds: [], prev_tag: null};
        ($c.hops[$i]) as $hop
        | {
            outbounds: (.outbounds + [hop_vless_outbound($c.id; ($i+1); $hop; .prev_tag)]),
            prev_tag: ("chain" + ($c.id|tostring) + "-hop" + (($i+1)|tostring))
        }
    );

# 汇总所有链路的 vless outbounds
def all_vless_outbounds:
    [chains[] | chain_hops(.).outbounds[]];

# 链路最终 hop tag (用于分流规则的 outbound)
def chain_final_tag(chain):
    "chain" + (chain.id|tostring) + "-hop" + ((chain.hops|length)|tostring);

# 生成分流规则: 对每条链路的每个子网, 按 routing-rules.json 生成域名级分流
# 规则顺序: 强制代理域名 -> geosite-cn 直连 -> geoip-cn 直连 -> 自定义直连域名 -> 默认走链路
# 注意: 链路未绑定子网时 (resolved_cidrs 为空或无效), 不生成分流规则
def is_valid_cidr:
    # 判断是否是有效的 CIDR (x.x.x.x/n 格式), 不用 test 正则 (jq 可能没编译 oniguruma)
    (type == "string") and (contains("/") and contains(".")) and (startswith("/") | not);
def chain_routing_rules(chain):
    chain as $c |
    (chain_final_tag($c)) as $tag |
    # 过滤无效 cidr: 只保留有效的 "x.x.x.x/n" 前缀
    ($c.resolved_cidrs | map(select(is_valid_cidr))) as $valid_cidrs |
    (routing.rule_sets // []) as $rule_sets |
    (routing.direct_domain_suffix // []) as $direct_domains |
    (routing.proxy_domain_suffix // []) as $proxy_domains |
    # 没有有效 cidr 时返回空数组 (不生成分流规则, 链路 outbound 仍存在)
    if ($valid_cidrs | length) == 0 then []
    else
        ($valid_cidrs) as $cidrs |
        # 1. 强制代理域名 (优先级最高, 确保这些域名一定走链路)
        (if ($proxy_domains | length) > 0 then
            [{source_ip_cidr: $cidrs, domain_suffix: $proxy_domains, outbound: $tag}]
           else [] end)
        # 2. geosite-cn 直连 (国内域名走直连, 不走 VLESS)
        + (if ($rule_sets | any(.tag == "geosite-cn")) then
            [{source_ip_cidr: $cidrs, rule_set: "geosite-cn", outbound: "direct"}]
         else [] end)
        # 3. geoip-cn 直连 (国内 IP 走直连)
        + (if ($rule_sets | any(.tag == "geoip-cn")) then
            [{source_ip_cidr: $cidrs, rule_set: "geoip-cn", outbound: "direct"}]
           else [] end)
        # 4. 自定义直连域名
        + (if ($direct_domains | length) > 0 then
            [{source_ip_cidr: $cidrs, domain_suffix: $direct_domains, outbound: "direct"}]
           else [] end)
        # 5. 默认走链路 (绑定了链路的子网流量默认走 VLESS)
        + [{source_ip_cidr: $cidrs, outbound: $tag}]
    end;

# 汇总所有链路的分流规则
def all_routing_rules:
    [chains[] | chain_routing_rules(.) | .[]];

# 组装完整配置
{
    log: { level: "debug", output: "/var/log/sing-box.log", timestamp: true },
    dns: {
        # strategy=ipv4_only: 只解析 A 记录, 避免 VPS 无 IPv6 上行时 AAAA 导致 no route to host
        strategy: "ipv4_only",
        servers: [
            # 本地 DNS (走直连, 用于国内域名解析)
            { tag: "local-dns", address: "223.5.5.5", detour: "direct" },
            # 远程 DNS (走直连, 用于国外域名解析, 避免 DNS 污染)
            { tag: "proxy-dns", address: "8.8.8.8", detour: "direct" }
        ],
        rules: [
            # 国内域名用本地 DNS 解析 (快速)
            { rule_set: "geosite-cn", server: "local-dns" },
            # 其他域名用 8.8.8.8 解析 (避免污染)
            { domain_suffix: (routing.proxy_domain_suffix // []), server: "proxy-dns" }
        ],
        final: "proxy-dns"
    },
    inbounds: [{
        type: "tun", tag: "tun-in",
        interface_name: "singbox-tun",
        address: ["172.19.0.1/30"], mtu: 1500,
        auto_route: true, strict_route: true,
        sniff: true,
        # sniff_override_destination=true: 用嗅探到的域名覆盖目标地址
        # 这样 route.rules 里的 domain_suffix/rule_set 才能按域名匹配
        sniff_override_destination: true
    }],
    outbounds: (all_vless_outbounds + [{tag: "direct", type: "direct"}]),
    route: {
        rule_set: (routing.rule_sets // []),
        rules: all_routing_rules,
        final: $final_tag,
        auto_detect_interface: true
    }
}
