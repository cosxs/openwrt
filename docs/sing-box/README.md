# sing-box 配置模板

[`config.json`](config.json) 是在这台固件上逐项审核、实测过的 sing-box 配置，适用于固件内置的 sing-box 1.14.x。目标是：

- 国内 IP 直连，在 nftables 层就绕过 sing-box；
- 其他流量经节点转发，国外域名由节点那端解析，不受本地 DNS 污染影响；
- 用 TUN 同时接管局域网设备和路由器本机的流量，设备上不需要任何设置；
- sing-box 停止后，国内网络立即恢复，不需要看门狗。

模板里的节点（`node`，Shadowsocks 2022，地址 `203.0.113.1`）和面板密钥（`CHANGE_ME`）都是占位值。真实的节点地址、密钥只写在设备上的 `/etc/sing-box/config.json`，不要提交到这个公开仓库。

## 工作方式

### DNS

局域网设备照常把 DNS 发给路由器（`192.168.72.1`）。dnsmasq 再向它的上游 `223.5.5.5`、`119.29.29.29` 发普通的 53 端口查询，这些查询被 TUN 劫持（`hijack-dns`），交给 sing-box 的 DNS 模块：

1. 先通过 DoQ 问国内 DNS `223.5.5.5`（`dns-direct`），最多等 2 秒。
2. 答案是国内 IP（在规则集 `cn-mainland-ip` 里）：原样返回真实 IP。
3. 答案不是国内 IP 的 A/AAAA 查询：返回 fakeip（`198.18.0.0/15`、`fc00::/18`）。
4. 其他有效答案（TXT 等）和“域名不存在”：原样返回国内 DNS 的结果。
5. 国内 DNS 没有响应时，A/AAAA 一律返回 fakeip，也就是降级为全部走代理；其余查询交给 `final`，即经代理的 Cloudflare DoH。

设备自己写死的 DNS（例如 `8.8.8.8`）同样会被劫持，结果一致。

dnsmasq 必须使用固定上游：WAN 下发的 DNS 里可能有上游路由器的 IPv6 链路本地地址，发往它的查询不会被劫持，实测会全部绕过 sing-box、拿到被污染的答案。出厂固件已经这样设置（见 `files/etc/uci-defaults/97-dnsmasq-upstream`）。sing-box 停止后劫持随之消失，dnsmasq 直接查询这两个上游，国内网络照常可用。

### 连接

| 目标 | 处理 |
|---|---|
| 国内 IP | TUN 的 `route_exclude_address_set` 在 nftables 层直接绕过，不经过 sing-box |
| 局域网、私有地址 | 直连 |
| fakeip | sing-box 还原出域名，把域名交给 `proxy`，由节点解析并连接 |
| 853 端口（DoT/DoQ）、UDP 443（QUIC） | 拒绝，应用会回退到系统 DNS 和 TCP |
| 其他 | `proxy` |

决定走不走代理的是域名解析出来的 IP，而不是域名本身。所以 `dl.google.com`、`www.gstatic.com` 这类在国内解析到国内 IP 的域名会直连。

## 部署

以下命令在电脑上执行，`192.168.72.1` 是出厂管理地址。

1. 复制模板，填入真实节点（见“outbounds”一节），把 `services` 里的 `secret` 换成强密码，然后上传并检查：

   ```sh
   scp -O config.json root@192.168.72.1:/etc/sing-box/config.json
   ssh root@192.168.72.1 'sing-box check -c /etc/sing-box/config.json && echo OK'
   ```

   设备上没有 `sftp-server`，`scp` 要加 `-O`。`/etc/sing-box/config.json` 是软件包登记的配置文件，保留配置的 sysupgrade 会沿用它。

2. 工作目录放到数据分区，然后启用：

   ```sh
   ssh root@192.168.72.1 'mkdir -p /data/sing-box && uci set sing-box.main.workdir=/data/sing-box && uci set sing-box.main.enabled=1 && uci commit sing-box && service sing-box restart'
   ```

   工作目录里有规则集缓存、fakeip 映射、节点选择和面板文件。默认目录 `/usr/share/sing-box` 在系统分区上，sysupgrade 后会清空。

   **第一次启动时节点必须可用**：规则集经 `proxy` 下载，下载失败 sing-box 会直接退出。下载成功一次后就写入缓存，以后即使节点暂时不通也能启动（规则集 URL 不变的前提下）。

3. 确认 dnsmasq 的上游是固定的两个地址（出厂固件已设置；从旧配置升级来的设备可能没有）：

   ```sh
   ssh root@192.168.72.1 'uci -q get dhcp.@dnsmasq[0].noresolv; uci -q get dhcp.@dnsmasq[0].server'
   ```

   应输出 `1` 和 `223.5.5.5 119.29.29.29`。否则执行：

   ```sh
   ssh root@192.168.72.1 "uci set dhcp.@dnsmasq[0].noresolv=1 && uci -q delete dhcp.@dnsmasq[0].server; uci add_list dhcp.@dnsmasq[0].server=223.5.5.5 && uci add_list dhcp.@dnsmasq[0].server=119.29.29.29 && uci commit dhcp && service dnsmasq restart"
   ```

4. 验证（在路由器上执行）：

   ```sh
   logread -e sing-box | tail          # 没有 ERROR/FATAL
   nslookup www.google.com 127.0.0.1   # 198.18.x.x（fakeip）
   nslookup www.baidu.com 127.0.0.1    # 真实 IP
   curl -s https://api.ipify.org       # 节点出口 IP
   curl -s http://myip.ipip.net        # 宽带的公网 IP
   ```

5. 浏览器打开 `http://192.168.72.1:9090/`，用 `secret` 登录面板，查看节点和连接。

### 停用

```sh
ssh root@192.168.72.1 'uci set sing-box.main.enabled=0 && uci commit sing-box && service sing-box stop'
```

sing-box 退出时会撤掉 TUN、路由规则和 nftables 表。dnsmasq 的两个上游可以保留，国内网络不受影响；国外站点在停用后无法访问。

## 各部分说明

### `log`

| 字段 | 值 | 说明 |
|---|---|---|
| `level` | `warn` | 只记录异常。排查问题时临时改成 `info` 或 `debug`（会记录访问的域名），用完改回 |
| `timestamp` | `true` | 每行带时间 |
| `output` | 不设 | 输出交给 procd 进入系统日志，用 `logread -e sing-box` 查看。设置后系统日志里就看不到了；如果要写文件，放在 `/data` 下，sing-box 不做日志轮转 |

### `dns`

| 服务器 | 说明 |
|---|---|
| `dns-direct` | 阿里 DNS 的 DoQ（`223.5.5.5`），所有查询先问它；也用来解析节点域名（`route.default_domain_resolver`） |
| `dns-fakeip` | 非国内域名的 A/AAAA 答案 |
| `dns-cloudflare` | Cloudflare DoH（`1.1.1.1`），经 `proxy`，只作为 `final` 兜底 |

规则的顺序和含义见上面的“工作方式 → DNS”。几个要点：

- 第一条规则 `evaluate` 只查询、不直接作答，后面的规则用 `match_response` 检查它的答案。
- 判断依据是答案里的 IP 是否属于 `cn-mainland-ip`，而不是域名列表。国外域名被国内 DNS 污染成国内 IP 的情况极少，一旦发生，这个域名会被当成国内直连而打不开。
- fakeip 映射存入 `experimental.cache_file`（`store_fakeip`），重启后客户端手里的旧 fakeip 仍然有效。

### `inbounds`

| 入站 / 字段 | 说明 |
|---|---|
| `tun-in` | 接管局域网设备和路由器本机的流量 |
| `interface_name` | `sb-tun` |
| `address` | `10.255.255.1/30`、`fd10:255:255::1/126`，避开 LAN、Docker 和 fakeip 的网段 |
| `auto_route`、`auto_redirect` | 自动设置策略路由，并用 nftables 处理 TCP，与 OpenWrt 的 fw4 和 Docker 兼容 |
| `route_exclude_address_set` | `cn-mainland-ip` 里的地址在 nftables 层直接绕过 |
| `mixed-in` | 手动代理端口 `6088`，HTTP 和 SOCKS5 共用，监听所有地址，WAN 一侧由防火墙挡住。局域网设备可以设置 `http_proxy=http://192.168.72.1:6088` |

`mtu`、`stack`、`strict_route` 等其余字段使用默认值。

### `outbounds`

```json
{ "type": "shadowsocks", "tag": "node", "server": "203.0.113.1", "server_port": 8388,
  "method": "2022-blake3-aes-128-gcm", "password": "Q0hBTkdFX01FX0tFWV8xNg==" },
{ "type": "selector", "tag": "proxy", "outbounds": ["node"], "default": "node" },
{ "type": "direct", "tag": "direct" }
```

- `node` 是一个 Shadowsocks 2022 的假节点，换成自己的节点。`2022-blake3-aes-128-gcm` 的密码是 16 字节密钥的 base64（模板里是 `CHANGE_ME_KEY_16` 的编码），`aes-256-gcm` 和 `chacha20-poly1305` 是 32 字节；服务端没有给出时可以用 `sing-box generate rand --base64 16` 生成。
- `proxy` 是 selector，即使只有一个节点也保留：DNS、规则集下载和 `route.final` 都引用 `proxy`，加节点时只需要把节点追加到它的 `outbounds` 里，其他地方不用改。在面板里选定的节点会写入缓存，重启后保留。
- 节点的 `tag` 可以带 emoji，`proxy` 里列出的名字要与节点的 `tag` 一致。
- 其他协议（vless、trojan、hysteria2、tuic、anytls、snell 等）的写法见 [sing-box 出站文档](https://sing-box.sagernet.org/configuration/outbound/)。

**从 Surge 的 Snell 节点转写**（sing-box 1.14.0 起支持 Snell v4/v6）：

| Surge | sing-box |
|---|---|
| `snell, 主机, 端口` | `"type": "snell"`、`server`、`server_port` |
| `psk=…` | `psk`（v6 要求 12–255 字节） |
| `version=6` | `"version": 6` |
| `mode=default` | `"mode": "default"`（仅 v6，另有 `unshaped`、`unsafe-raw`） |
| `reuse=true` | `"reuse": true` |
| `tfo=true` | `"tcp_fast_open": true` |
| `ecn=true` | 不支持，去掉 |
| `obfs=http` | `obfs_mode`、`obfs_host`（仅 v4） |

### `http_clients`

`via-proxy` 经 `proxy` 发起 HTTP 请求，用于下载规则集和面板文件。直连 GitHub 在这台设备上实测不稳定，所以这两项都经节点下载。

### `route`

| 规则 / 字段 | 说明 |
|---|---|
| `sniff` | 嗅探协议和域名 |
| `protocol: dns` → `hijack-dns` | 识别出的 DNS 流量交给 DNS 模块 |
| `ip_is_private` → `direct` | 局域网、内网目标直连 |
| `cn-mainland-ip` → `direct` | 国内 IP 直连。TUN 已在 nftables 层绕过，这条主要作用于 `mixed-in` |
| 853 端口或 UDP 443 → `reject` | 防止私人 DNS（DoT）绕开劫持；QUIC 经代理效率低，拒绝后浏览器回退到 TCP。国内的 QUIC 已在 nftables 层绕过，不受影响 |
| `rule_set` | 国内 IP 段 [cosxs/cn-mainland-ip](https://github.com/cosxs/cn-mainland-ip)，经 `via-proxy` 下载 |
| `final` | `proxy` |
| `auto_detect_interface` | 出站绑定默认网卡，避免回环 |
| `default_domain_resolver` | `dns-direct`，解析节点域名和直连出站的域名 |

### `services`

`api` 是 sing-box 1.14 新增的原生 API，基于 gRPC，供官方客户端和 [sing-box dashboard](https://github.com/SagerNet/sing-box-dashboard) 使用：

- 面板文件第一次启动时经 `proxy` 下载到工作目录的 `dashboard` 目录，下载失败不影响 sing-box 运行，只是页面暂时 404。
- 监听 `::` 的 9090 端口，WAN 一侧由防火墙挡住。面板能查看连接、切换节点，`secret` 必须设置为强密码。
- 它不是 Clash API，`/proxies` 之类的 REST 路径都返回 404。脚本需要用 REST 切换节点或测延迟时，另在 `experimental` 里加只监听本机的 `clash_api`：

  ```json
  "clash_api": { "external_controller": "127.0.0.1:9091", "secret": "另一个强密码" }
  ```

### `experimental.cache_file`

开启缓存，保存规则集、`proxy` 的节点选择，以及 fakeip 映射（`store_fakeip`）。文件在工作目录的 `cache.db`。

## 注意事项

- **路由器本机的国外流量也走代理**：`apk update`、Docker 拉取国外镜像等都经节点；sing-box 停止或节点全部不可用时，这些操作会失败，国内的不受影响。
- **节点不可用时**，国外连接会等到超时才失败，而不是立即失败。
- **DDNS 用“通过网页查询公网 IP”时**，查询网址要选国内服务（如 `http://myip.ipip.net`）。国外服务会经代理，查到的是节点出口 IP。
- **Docker 容器的流量**经 TUN 的情况还没有验证过。

## 参考

- [sing-box 配置文档](https://sing-box.sagernet.org/configuration/)
- [Snell 出站](https://sing-box.sagernet.org/configuration/outbound/snell/)
- [TUN 入站](https://sing-box.sagernet.org/configuration/inbound/tun/)
