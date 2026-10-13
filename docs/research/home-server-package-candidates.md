# 家庭服务器软件候选：LEDE、QWRT、ImmortalWrt 与官方 OpenWrt

调查日期：2026-10-11。项目目标仍是官方 OpenWrt、N100、预装 Nikki。用户明确要求先列完整候选，之后再决定；本文不确定最终预装集合，不创建构建配置、不安装软件、不运行下载来的脚本。

本清单覆盖家庭路由、远程访问、存储共享、备份、下载、容器、媒体和设备管理的主要应用。这里的“有包”表示在所列源码或发布目录中找到，不等于已预装、已测试或可以跨发行版直接安装。

## 1. 三个固件体系的实际情况

| 体系 | 本次能确认的内容 | 默认预装边界 |
|---|---|---|
| Lean LEDE | 主仓 `coolsnowwolf/lede`，实际 feeds 为 `coolsnowwolf/packages`、`coolsnowwolf/luci` 等，提供广泛的家庭应用 | router 默认集合包含 LuCI DDNS、阿里云/DNSPod 扩展、WOL 等；其他多数是可选包，具体镜像还要看构建配置 |
| ImmortalWrt | 主仓及自有 packages/luci feeds 提供 DDNS-Go、VPN、NAS、下载、Docker、备份等 | 实查稳定版 25.12.2 x86/64 manifest：有 LuCI、automount、block-mount、lm-sensors 等基础组件，没有默认装齐下文应用 |
| QWRT | 可确认 Lean/coolsnowwolf 本人发布 QWRT；公开 GitHub Release 可见特定 ARM 设备镜像 | 本次没有找到当前 N100/x86 QWRT 的可靠完整 manifest，不能把其他作者的“全插件”列表当作 QWRT 默认 |
| iStore 生态（补充） | `linkease/istore` 是易有云 iStoreOS 的软件中心，可以独立集成其他 OpenWrt | 软件中心、可供安装的应用、已经安装的应用是三件事；iStore 自身明确说明插件依赖仍需适配 |

来源：[LEDE feeds][L-feeds]、[LEDE router 默认集合][L-default]、[ImmortalWrt feeds][I-feeds]、[ImmortalWrt 实际 manifest][I-manifest]、[QWRT 作者发布][Q-release]、[iStore 说明][store]。

QWRT 与 `kiddin9/Kwrt` 是不同项目，本调查没有用 Kwrt 的软件目录代替 QWRT 清单。也没有据缺少 manifest 推断 QWRT 所有变体的源码开放情况。

## 2. 如何看官方 OpenWrt 集成状态

- **官方**：本轮在官方 OpenWrt 25.12 分支源码或 x86_64 APK 下载目录中确认对应包；仍需在最终 ImageBuilder 配方中验证依赖及功能。
- **扩展**：在 LEDE/ImmortalWrt/应用上游中确认，但未在本轮官方 25.12 x86_64 包目录中确认相同组件；适配官方 SDK、可信预编译包或容器是后续候选路径。
- **混合**：主要程序在官方源有包，某些第三方 LuCI 页面或自动化脚本需另行适配。

官方实查目录：[LuCI APK][O-L]、[应用 APK][O-P]、[25.12.5 x86/64 核心包][O-core]；对应源码：[LuCI 25.12][O-luci-src]、[packages 25.12][O-packages-src]。以下“官方”不表示官方默认镜像已经安装。

## 3. 域名、证书与从外面访问家里

| 候选 | 精确包名 / 界面 | 家庭用途 | 官方集成状态与取舍 |
|---|---|---|---|
| 传统 DDNS | `ddns-scripts` + `luci-app-ddns`；按 DNS 商选择 `ddns-scripts-cloudflare`、`ddns-scripts-aliyun`、`ddns-scripts-dnspod-v3` 等 | 自动更新域名的 IPv4 A / IPv6 AAAA 记录 | 官方；与 LuCI/UCI 管理一致。LEDE 老扩展使用下划线包名，不能照抄到官方包清单 |
| DDNS-Go | `ddns-go` + `luci-app-ddns-go` | 网页配置多个域名、多个 DNS 商及 IPv4/IPv6 更新 | 扩展；LEDE/ImmortalWrt 都有配方。自身有 Web UI，LuCI 包提供系统集成 |
| ACME 证书 | `luci-app-acme` + `acme-acmesh`（依赖 `acme-common`），DNS 验证选 `acme-acmesh-dnsapi` | 自动申请和续签 HTTPS 证书 | 官方；它处理证书，不负责域名动态解析或建立网络通路 |
| Nginx | `nginx-ssl` / `nginx-full` | 多个家庭 Web 服务统一域名入口、HTTPS 与反向代理 | 官方；需配置服务路由。`luci-nginx` 是让 LuCI 使用 Nginx，不是通用反代管理面板 |
| Tailscale | `tailscale` + `luci-app-tailscale-community` | 手机/电脑在外接入家庭私网；可用子网路由访问不装客户端的设备 | 官方；当前准确 LuCI 名称带 `-community` |
| ZeroTier | `zerotier`；第三方 UI 为 `luci-app-zerotier` | 跨地点虚拟网络、访问家庭设备 | 混合；官方后端已确认，LEDE/ImmortalWrt 提供 UI |
| WireGuard | `wireguard-tools` + `kmod-wireguard` + `luci-proto-wireguard` | 自行管理 VPN 隧道与回家访问 | 官方；LuCI 是协议插件，使用 `luci-proto-wireguard`。需要安排可达的隧道端点 |
| NetBird | `netbird` | 另一套基于 WireGuard 的组网方案，可按其上游方式管理 | 官方后端；本轮未确认官方 LuCI 界面 |
| FRP | 家庭端 `frpc` + `luci-app-frpc`；公网端 `frps` + `luci-app-frps` | 利用公网服务器把家中服务映射出来 | 官方；通常家庭端只需要客户端，服务端放在有公网入口的一端 |
| Cloudflare Tunnel | `cloudflared` | 家中服务主动建立到 Cloudflare 的连接，用于远程发布/访问 | 官方后端；和 DDNS、传统端口转发的工作方式不同 |
| DDNSTO | `ddnsto`、`luci-app-ddnsto`、`luci-i18n-ddnsto-zh-cn` | 通过服务商入口在浏览器中远程访问家中设备 | iStore 扩展；实际是远程访问/穿透服务，不能因名称相近把它当作普通 DDNS 客户端 |
| SSH / SFTP / 反向隧道 | `openssh-server`、`openssh-sftp-server`、`autossh` | 远程管理、文件传输、维护 SSH 隧道 | 官方；是否需要替换系统现有 SSH 服务另行决定 |

来源：[官方 DDNS 配方][O-ddns]、[DDNS-Go 上游][ddns-go]、[LEDE DDNS-Go UI][L-ddnsgo]、[ImmortalWrt DDNS-Go][I-ddnsgo]、[官方 WireGuard UI][O-wg]、[Tailscale 子网路由说明][tailscale-subnet]，其余精确包的发布证据见 [O-L]、[O-P]。

DDNSTO 的组件和用途另据 [iStore 官方应用元数据][store-ddnsto] 与 [服务商说明][ddnsto]。

### DDNS 需要特别分清的事情

DDNS 只负责“地址变了，域名随之更新”。它不会自动给家庭网络分配公网 IPv4，也不解决运营商 CGNAT 入站限制。公网 IPv4 直连通常还需端口转发和防火墙规则；IPv6 直连需要服务端具有可达 IPv6、客户端支持 IPv6，并正确放行服务。若域名指向独立 NAS，AAAA 应对应 NAS 的可达地址，不能当然使用路由器自己的地址。[官方 DDNS 配置][O-ddns-doc]。

传统 DDNS 和 DDNS-Go 是同类候选，通常选择其中一个管理同一条记录即可。DDNS 与 Tailscale/ZeroTier/FRP 则解决不同问题，可以根据访问方案组合。这里没有替用户决定采用哪一种。

## 4. DNS、家庭网络与流量服务

| 候选 | 软件包 | 家庭用途 | 官方集成状态与取舍 |
|---|---|---|---|
| Nikki（已明确需要） | `nikki`、`luci-app-nikki`、`luci-i18n-nikki-zh-cn`、`mihomo-meta` | 透明代理、分流和相关 DNS 配置 | 已有单独调研，使用匹配官方版本的 Nikki 发布包 |
| AdGuard Home | `adguardhome` + `luci-app-adguardhome` | DNS 层广告/追踪域名过滤、查询记录和客户端策略 | 官方；过滤效果取决于规则与流量，不等于所有应用广告都能移除 |
| SmartDNS | `smartdns` + `luci-app-smartdns` | 多上游 DNS 查询与解析优化 | 官方；用途与 AdGuard 的过滤、Nikki 的代理 DNS 有交集，启用前设计查询链 |
| SQM | `sqm-scripts` + `luci-app-sqm` | 下载占满带宽时改善交互延迟 | 官方；按实际线路和 CPU 负载配置 |
| 多 WAN 管理 | `mwan3` + `luci-app-mwan3` | 多宽带/备用链路的策略、故障切换 | 官方；有第二条链路时才有实际意义 |
| UPnP / NAT-PMP | `miniupnpd` 相应变体 + `luci-app-upnp` | 游戏机或局域网应用申请动态端口映射 | 官方；属于按需求启用的网络服务 |
| 网络故障监测 | `watchcat` + `luci-app-watchcat` | 按连通性检查触发重连或其他恢复动作 | 官方；动作要与实际网络拓扑匹配 |

来源：[官方 LuCI 应用树][O-luci-src]、[官方网络包树][O-net-src]。Nikki 参考同目录的 [固件调研](openwrt-custom-firmware-projects.md)。Nikki、dnsmasq、AdGuard Home、SmartDNS 可以有合理组合，但必须明确监听端口、上游关系和谁负责 DNS 劫持，不能把包同时安装当作组合已验证。

## 5. 文件共享、同步与备份

| 候选 | 软件包 / 界面 | 家庭用途 | 官方集成状态与取舍 |
|---|---|---|---|
| Samba4 | `samba4-server` + `luci-app-samba4` | Windows/macOS/Linux 使用 SMB 网络共享 | 官方；适合常规家庭共享盘 |
| ksmbd | `ksmbd-server` + `kmod-fs-ksmbd` + `luci-app-ksmbd` | 内核侧 SMB 服务 | 官方；与 Samba4 功能重叠，按功能需求选择实现 |
| NFS | `nfs-kernel-server`、`nfs-kernel-server-utils` 等；第三方 UI `luci-app-nfs` | Linux 主机、虚拟化主机挂载共享目录 | 混合；官方有服务端包，LEDE/ImmortalWrt 的 LuCI 页面另行适配 |
| WebDAV | LEDE 的 `gowebdav`（对应 `hacdias/webdav` 服务端） | 向支持 WebDAV 的客户端提供文件目录 | 扩展；需匹配的官方构建包或另选容器，不能按名字误当客户端库 |
| LuCI 文件浏览 | `luci-app-filebrowser` | 在路由器管理界面操作文件 | 官方；只依赖 LuCI 基础组件，不是独立 Go File Browser 服务 |
| 独立 File Browser | `filebrowser` + `luci-app-filebrowser-go` | 独立 Web 页面上传、下载和管理文件 | 扩展；LEDE/ImmortalWrt 已确认对应后端和 UI |
| Syncthing | `syncthing`；第三方 UI `luci-app-syncthing` | 多台家庭电脑/服务器同步目录 | 混合；官方后端存在。同步删除也可能传播，历史版本/备份需单独设置 |
| Rsync | `rsync` | 计划式增量传输、镜像或备份脚本 | 官方；保留历史版本、排除目录等由任务设计决定 |
| Rclone | `rclone`；第三方 UI `luci-app-rclone`，另有配置脚本包 `rclone-config` | 对接云存储、对象存储，复制/同步/挂载 | 混合；官方后端存在，不把单向同步自动视为版本化备份 |
| Restic | `restic` | 加密、去重、版本化备份到本地或远程仓库 | 官方；本轮没有确认默认 LuCI 管理页 |
| BorgBackup | `borgbackup` | 另一套去重、版本化备份方案 | ImmortalWrt 源配方已确认；官方目标包及依赖需另行核对 |

来源：[官方 NAS 说明][O-nas]、[官方 Samba/ksmbd 区别][O-ksmbd]、[官方 LuCI filebrowser 定义][O-filebrowser]、[LEDE WebDAV][L-webdav]、[ImmortalWrt 独立 File Browser][I-filebrowser]、[ImmortalWrt 备份配方][I-borg]，官方后端二进制见 [O-P]。

服务程序是否预装与数据放在哪里应分别确定。共享目录、备份仓库、同步目录都应有明确的持久数据路径及升级保留方案。

## 6. 下载、媒体与容器

| 候选 | 软件包 / 界面 | 家庭用途 | 官方集成状态与取舍 |
|---|---|---|---|
| Aria2 + AriaNg | `aria2`、`ariang`、`luci-app-aria2` | HTTP/FTP/BT 等下载与网页管理 | 官方；适合多协议任务 |
| Transmission | `transmission-daemon`、`transmission-web`、`luci-app-transmission` | BT 下载与网页管理 | 官方；第三方 feed 的 web-control 组合与官方包名可能不同 |
| qBittorrent | `qbittorrent` + `luci-app-qbittorrent` | BT/PT 任务管理，使用无桌面的 Web UI | 扩展；LEDE/ImmortalWrt 有配方，可评估官方 SDK 或容器方案 |
| MiniDLNA | `minidlna` + `luci-app-minidlna` | 把视频/音乐目录提供给电视或 DLNA 播放器 | 官方；偏媒体目录共享，不等同完整转码媒体平台 |
| Docker + Compose | `dockerd`、`docker`、`docker-compose` | 承载独立家庭应用 | 官方；明确 Docker 数据目录、容器网络、资源分配和服务端口 |
| Dockerman | `luci-app-dockerman` | 在 LuCI 管理 Docker 容器、镜像等 | 官方；实际依赖 Docker/Compose，安装管理页也会引入服务组件 |
| iStore | `luci-app-store` | 提供应用发现、安装和相关教程入口 | 扩展；第三方应用中心，需要逐项处理应用依赖，不能代替版本固定 |

来源：[官方 APK][O-P]、[官方 Dockerman 依赖][O-dockerman]、[ImmortalWrt qBittorrent][I-qbit]、[LEDE qBittorrent][L-qbit]、[iStore][store]。

Docker 数据建议使用独立、适合容器的持久存储路径；官方文档说明把容器数据留在默认固件 overlay 可能导致使用效率较低的存储驱动。是否把 N100 同时作为容器服务器尚未决定，本轮只列候选。[官方 Docker Host 文档][O-docker-doc]。

## 7. 磁盘、监控、唤醒与家庭外设

| 候选 | 软件包 / 界面 | 家庭用途 | 官方集成状态与取舍 |
|---|---|---|---|
| 挂载管理 | `block-mount`，按介质选择文件系统与 USB/NVMe 驱动 | 挂载系统盘之外的数据分区/硬盘 | 官方；ImmortalWrt 的 `automount` 是另一套自动挂载脚本，不能视为同一个包 |
| Diskman | `luci-app-diskman` | 图形化查看/管理磁盘、分区和文件系统 | 扩展；LEDE/ImmortalWrt 有包，会引入相关磁盘工具及可选文件系统依赖 |
| 磁盘健康 | `smartmontools`、按需 `smartd`、`nvme-cli` | SMART 状态、NVMe 信息、磁盘健康监测 | 官方；依实际硬盘和监控需求选用 |
| 硬盘休眠 | `hd-idle` + `luci-app-hd-idle` | 机械硬盘空闲停转 | 官方；面向机械盘需求 |
| 系统历史统计 | `collectd` + `luci-app-statistics` | CPU/内存/网络等历史图表 | 官方；根据需要选择采集插件 |
| 实时性能监控 | `netdata`；第三方 UI `luci-app-netdata` | 实时资源、网络和运行指标 | 混合；官方后端存在，本轮看到的 recipe 较旧，选用前核对维护状态 |
| 按设备流量统计 | `nlbwmon` + `luci-app-nlbwmon` | 观察哪些家庭设备使用多少流量 | 官方；与实时抓包/全部流量留存不同 |
| 按接口历史流量 | `vnstat2` + `luci-app-vnstat2` | WAN/LAN 的日、月累计流量 | 官方；与按设备统计互补 |
| 网络唤醒 | `etherwake` + `luci-app-wol`；ImmortalWrt 另有 `luci-app-timewol` | 在外回到家庭网络后唤醒电脑/NAS | 官方基础 WOL；定时 UI 为扩展，目标硬件需支持 |
| UPS 管理 | `nut-server`、`nut-upsc`、对应驱动如 `nut-driver-usbhid-ups`、`luci-app-nut` | 读取 UPS 电量/市电状态，配合关机策略 | 官方；还需按 UPS 型号和受控设备配置，安装后不会自动保护所有主机 |
| USB 打印共享 | `p910nd` + `luci-app-p910nd` | 把 USB 打印机接入家庭网络 | 官方；依赖实际打印机和客户端驱动支持 |
| USB/IP | `usbip-server` / `usbip-client` 及对应内核模块 | 网络传递特定 USB 设备连接 | 官方用户态包；设备兼容性和对应内核模块要实测 |
| MQTT | `mosquitto-ssl`、`mosquitto-client-ssl`、`luci-app-mosquitto` | 家庭传感器/自动化设备的消息服务 | 官方；不是 Home Assistant 的替代品 |
| mDNS/服务发现 | `avahi-dbus-daemon` 或 `avahi-nodbus-daemon`、`avahi-utils` | 局域网服务发现，按拓扑考虑跨网段发现 | 官方；跨 VLAN 转发需要有意配置 |
| Web 终端 | `ttyd` + `luci-app-ttyd` | 浏览器内执行管理命令 | 官方；属于运维入口 |

来源：[官方 APK][O-P]、[官方 LuCI][O-L]、[核心包目录][O-core]、[ImmortalWrt Diskman][I-diskman]、[ImmortalWrt automount][I-automount]、[官方文件系统说明][O-filesystems]。

## 8. iStore 生态中的完整家庭应用候选

为了覆盖“家庭服务器”而不止路由器插件，还核对了 iStore 官方应用元数据和实际运行脚本。以下确实存在相关条目；这不说明 QWRT 默认预装，也不说明已经验证兼容本项目的官方 25.12 固件。

| 应用 | 确认的实际包名 | 用途与实现类型 |
|---|---|---|
| Home Assistant | `luci-app-homeassistant` | 智能家居平台；Docker 管理封装 |
| Jellyfin | `luci-app-jellyfin` | 家庭影音库；Docker 管理封装，转码能力需另测 |
| Emby | `luci-app-emby` | 另一套影音库；Docker 管理封装 |
| OpenList | `openlist`、`luci-app-openlist` | 多种存储的统一文件列表/访问；原生包与 LuCI |
| Nextcloud | `luci-app-nextcloud` | 私有云、文件和协作服务；Docker 管理封装 |
| Vaultwarden | `luci-app-vaultwarden` | 密码管理服务；Docker 管理封装 |
| Immich | `luci-app-immich` | 家庭相册与照片管理；Docker Compose 管理封装 |
| Uptime Kuma | `luci-app-uptimekuma` | 服务在线状态检查与通知；Docker 管理封装 |
| CUPS | `cups`、`luci-app-cupsd` | 打印服务与管理；原生包 |
| NUT | `luci-app-nut`、`nut-server`、`nut-upsmon`、驱动等 | UPS 状态与关机协调；原生包，同前述 UPS 类候选 |

来源：[iStore 应用元数据][store-meta]、[对应应用脚本][store-actions]、[Immich 实际 Compose 脚本][store-immich]。元数据仓库每个 `app-meta-<应用>` 的 Makefile 列出实际依赖；Docker 类另检查了脚本中的 `docker` / `docker-compose` 调用。

`alist` / `luci-app-alist` 条目也仍存在，但 iStore 元数据注明将由 OpenList 接任，因此这里以 OpenList 作为对应候选名称。[旧条目说明][store-alist]。这些应用的运行数据、容器镜像和数据库属于后续部署内容，预装 LuCI 管理包不等于已经部署好整个服务。

## 9. 选型前保留的决定

1. DDNS 选传统 LuCI 方案还是 DDNS-Go；DNS 服务商和需要更新的 A/AAAA 记录是什么。
2. 远程访问只供自己使用，还是需要对外提供服务；家庭是否有可用公网 IPv4/IPv6，是否愿意维护公网中转。
3. N100 是专职路由，还是同时承担共享、下载、容器；磁盘和持久数据路径怎样安排。
4. 哪些软件预装进固件，哪些安装后再配置，哪些采用容器；哪些保持关闭直到配置完成。
5. Nikki 与其他 DNS/VPN/容器的端口和路由如何配合；选择重叠服务时如何明确责任。

这些都留待用户选包时决定。本文不是建议把所有候选同时装入固件。

## 10. 已验证范围与兼容性

- LEDE 依据主仓及实际 feeds；ImmortalWrt 候选依据 master 源码，标准镜像默认情况依据单独核对的 25.12.2 manifest。两种证据不互相替代。
- 官方 OpenWrt 对照依据 25.12 源码和 x86_64 发布目录，不能把包存在当成这套组合已经构建或运行通过。
- LEDE/ImmortalWrt 的 APK、IPK，特别是 kmod，不能因同属 x86_64 就直接装到官方 OpenWrt；实际集成使用匹配官方发行版的包或工具链。
- Caddy 未在本轮 LEDE/ImmortalWrt 完整所查源码树中找到配方，未将其写为它们已提供的默认包；如需选择，可单独按其上游容器/程序方案调查。
- 本轮只新增调研文档，未安装、构建、刷机、改变网络或启用服务。

## 11. 源码快照与链接

| 项目 | 本轮读取的分支 / commit |
|---|---|
| coolsnowwolf/lede | master / `d5ccef5f796981c79811f27722596173482a35e3` |
| coolsnowwolf/packages | master / `7932e2af2573b98932fa3aa7d3f3129fbe7fa5de` |
| coolsnowwolf/luci | openwrt-25.12 / `3523701f340fe395f21ec033df946cb9519e14fa` |
| immortalwrt/immortalwrt | master / `11152dd84230f07dcc524137c81db15b818093c9` |
| immortalwrt/packages | master / `25ad600a90980bed1ee76a212f9a5e42b499bb62` |
| immortalwrt/luci | master / `5fc1fac5684cac6eee2c7fbff78c65b867980dd8` |
| linkease/istore | `a97ace34f2da358a015b094d326bba2697697f2e` |
| linkease/openwrt-app-meta | `6a8627e0e6fa79aaebdfa53fbbb7dc741eec9367` |
| linkease/openwrt-app-actions | `763fc1be2a097809ca7208dd087d7ef70b7182aa` |

[L-feeds]: https://github.com/coolsnowwolf/lede/blob/d5ccef5f796981c79811f27722596173482a35e3/feeds.conf.default
[L-default]: https://github.com/coolsnowwolf/lede/blob/d5ccef5f796981c79811f27722596173482a35e3/include/target.mk
[I-feeds]: https://github.com/immortalwrt/immortalwrt/blob/11152dd84230f07dcc524137c81db15b818093c9/feeds.conf.default
[I-manifest]: https://downloads.immortalwrt.org/releases/25.12.2/targets/x86/64/immortalwrt-25.12.2-x86-64.manifest
[Q-release]: https://github.com/coolsnowwolf/lede/releases/tag/20251001
[store]: https://github.com/linkease/istore/blob/a97ace34f2da358a015b094d326bba2697697f2e/README.md
[O-L]: https://downloads.openwrt.org/releases/packages-25.12/x86_64/luci/
[O-P]: https://downloads.openwrt.org/releases/packages-25.12/x86_64/packages/
[O-core]: https://downloads.openwrt.org/releases/25.12.5/targets/x86/64/packages/
[O-luci-src]: https://github.com/openwrt/luci/tree/openwrt-25.12/applications
[O-packages-src]: https://github.com/openwrt/packages/tree/openwrt-25.12
[O-net-src]: https://github.com/openwrt/packages/tree/openwrt-25.12/net
[O-ddns]: https://github.com/openwrt/packages/blob/openwrt-25.12/net/ddns-scripts/Makefile
[O-ddns-doc]: https://openwrt.org/docs/guide-user/base-system/ddns
[ddns-go]: https://github.com/jeessy2/ddns-go
[L-ddnsgo]: https://github.com/coolsnowwolf/luci/blob/3523701f340fe395f21ec033df946cb9519e14fa/applications/luci-app-ddns-go/Makefile
[I-ddnsgo]: https://github.com/immortalwrt/packages/blob/25ad600a90980bed1ee76a212f9a5e42b499bb62/net/ddns-go/Makefile
[O-wg]: https://github.com/openwrt/luci/blob/openwrt-25.12/protocols/luci-proto-wireguard/Makefile
[tailscale-subnet]: https://tailscale.com/docs/features/subnet-routers/how-to/setup
[O-nas]: https://openwrt.org/docs/guide-user/services/nas/start
[O-ksmbd]: https://openwrt.org/docs/guide-user/services/nas/ksmbd
[O-filebrowser]: https://github.com/openwrt/luci/blob/openwrt-25.12/applications/luci-app-filebrowser/Makefile
[L-webdav]: https://github.com/coolsnowwolf/packages/blob/7932e2af2573b98932fa3aa7d3f3129fbe7fa5de/net/gowebdav/Makefile
[I-filebrowser]: https://github.com/immortalwrt/luci/blob/5fc1fac5684cac6eee2c7fbff78c65b867980dd8/applications/luci-app-filebrowser-go/Makefile
[I-borg]: https://github.com/immortalwrt/packages/blob/25ad600a90980bed1ee76a212f9a5e42b499bb62/utils/borgbackup/Makefile
[I-qbit]: https://github.com/immortalwrt/packages/blob/25ad600a90980bed1ee76a212f9a5e42b499bb62/net/qbittorrent/Makefile
[L-qbit]: https://github.com/coolsnowwolf/packages/blob/7932e2af2573b98932fa3aa7d3f3129fbe7fa5de/net/qBittorrent/Makefile
[O-dockerman]: https://github.com/openwrt/luci/blob/openwrt-25.12/applications/luci-app-dockerman/Makefile
[O-docker-doc]: https://openwrt.org/docs/guide-user/virtualization/docker_host
[I-diskman]: https://github.com/immortalwrt/luci/blob/5fc1fac5684cac6eee2c7fbff78c65b867980dd8/applications/luci-app-diskman/Makefile
[I-automount]: https://github.com/immortalwrt/immortalwrt/blob/11152dd84230f07dcc524137c81db15b818093c9/package/emortal/automount/Makefile
[O-filesystems]: https://openwrt.org/docs/guide-user/storage/filesystems-and-partitions
[store-meta]: https://github.com/linkease/openwrt-app-meta/tree/6a8627e0e6fa79aaebdfa53fbbb7dc741eec9367/applications
[store-actions]: https://github.com/linkease/openwrt-app-actions/tree/763fc1be2a097809ca7208dd087d7ef70b7182aa/applications
[store-immich]: https://github.com/linkease/openwrt-app-actions/blob/763fc1be2a097809ca7208dd087d7ef70b7182aa/applications/luci-app-immich/root/usr/libexec/istorec/immich.sh
[store-alist]: https://github.com/linkease/openwrt-app-meta/blob/6a8627e0e6fa79aaebdfa53fbbb7dc741eec9367/applications/app-meta-alist/Makefile
[store-ddnsto]: https://github.com/linkease/openwrt-app-meta/blob/6a8627e0e6fa79aaebdfa53fbbb7dc741eec9367/applications/app-meta-ddnsto/Makefile
[ddnsto]: https://github.com/linkease/ddnsto
