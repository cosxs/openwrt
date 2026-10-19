# x86-64 OpenWrt 基线

从官方 OpenWrt `x86/64 / generic` 出发的基线，使用官方 ImageBuilder 和默认软件包，通过 `profiles/packages.txt` 与 `files/` 逐项增加定制。

本基线不集成 Docker、UPnP 或 NextTrace。

初始登录使用 `root` / `159357`。首次启动脚本仅在 root 密码为空时设置该密码；保留配置升级时沿用已有密码，恢复出厂后重新使用初始密码。串口登录仍沿用上游的 `ttylogin` 默认设置，与网络登录密码独立。

出厂时区为 `Asia/Shanghai`，对应系统时区 `CST-8`（UTC+8）。由官方配置生成流程写入新系统，再补齐 LuCI 的时区名称；已有其他时区保持不变。时间服务器同样只在新系统中设为国内的 `ntp.aliyun.com`、`ntp.tencent.com`、`ntp.tuna.tsinghua.edu.cn` 和 `time.ustc.edu.cn`，分属阿里、腾讯、清华和中科大四家，替换上游默认的 `openwrt.pool.ntp.org`。BIOS 的系统厂商或产品名称为裸 `Default` 时，使用有效的主板厂商和型号补齐显示，并沿用上游规则生成板卡标识；没有有效主板信息时保留上游结果。

防火墙出厂开启软件流量卸载，并关闭 fw4 在 input 链上的 SYN 限速（每秒 25 个、突发 50 个）：路由器把连接重定向到本机服务时，这些连接都经过 input 链，LAN 的突发新连接会超时。WAN 区域本来就拒绝新的入站连接。只在防火墙配置仍是出厂版本时修改，保留配置升级沿用用户设置。

`files/etc/sysctl.d/90-tcp-tuning.conf` 调整路由器本机连接的 TCP 参数，不影响转发的流量：收发缓冲区上限调到 32 MiB 和约 22 MiB，单个连接可通告约 14 MiB 的接收窗口，足够在 290 ms 往返时延下跑满 400 Mbit/s；同时关闭空闲后的慢启动、开启 MTU 探测，并设置 `tcp_notsent_lowat` 和 `netdev_max_backlog`。拥塞控制沿用 BBR。要改某个值，写到 `/etc/sysctl.conf` 即可覆盖。

从 WAN 所在的子网可以管理路由器：SSH（22）、LuCI（80）和网页终端 ttyd（7681）只对这个子网开放，仅限 IPv4。`files/etc/hotplug.d/iface/30-wan-admin-subnet` 在 WAN 上线、地址更新或下线时，把 WAN 的子网写入防火墙集合 `wan_admin_subnet`；只有私有 IPv4 地址且前缀在 /24 到 /30 之间才会写入，也就是常见的上游家用路由器网段。公网地址、PPPoE 的 /32 地址、运营商分配的大网段（如 10.183.0.0/16）或 WAN 下线时集合为空，WAN 侧不开放任何端口；WAN 的公网 IPv6 地址始终不开放。集合文件在内存里，每次开机从空集合开始。需要额外放行的网段可以在 LuCI 的“防火墙 → IP 集”里给 `wan_admin_subnet` 添加条目。为了让 LuCI 的终端页面从 WAN 侧可用，ttyd 出厂监听所有地址，访问由这条防火墙规则控制。

LuCI 只提供 HTTP，镜像不带生成自签证书的工具（`luci-ssl` 带来的 `px5g-mbedtls`）。uhttpd 的出厂配置仍监听 443，找不到证书时自动跳过 HTTPS；把证书放到 `/etc/uhttpd.crt` 和 `/etc/uhttpd.key` 后重启 uhttpd 即启用 HTTPS，例如以后用自己域名申请的正式证书。不要在只有 HTTP 时把 LuCI 转发到公网。

## WireGuard

固件带 WireGuard 及其 LuCI 页面、对端状态和配置二维码（`qrencode`）。首次启动时 `files/etc/uci-defaults/97-wireguard-defaults` 创建接口 `wireguard`：地址 `10.66.66.1/24`，监听 UDP 51820，私钥在设备上生成，每台设备不同，仓库里不保存任何密钥；出厂没有对端。防火墙出厂把 `wireguard` 加入 LAN 区域，并对 WAN 放行 IPv4 UDP 51820。WireGuard 不回应没有已配置对端签名的数据包，没有对端时外部无法连接，也探测不到这个端口。

添加设备：在 LuCI 的“网络 → 接口 → wireguard → 对端”中添加对端，每台设备使用自己的密钥对和不重复的地址（如 `10.66.66.2/32`、`10.66.66.3/32`）；客户端填写路由器的公钥、对外地址和端口 51820。路由器在上游路由器之后时，还需要在上游路由器上把 UDP 51820 转发到路由器的 WAN 地址。

已有 `wireguard` 的配置（例如保留配置升级）保持不变；删除 `wireguard` 后，下次运行首次启动脚本（例如保留配置升级）会重新创建并生成新密钥，不使用时请在 LuCI 中停用接口而不是删除。

路由器上同时运行 sing-box 等使用 TUN 接管本机流量的程序时，WireGuard 回复给对端的 UDP 包可能被接管并改变源地址，导致握手失败；需要在其配置中让 WireGuard 的流量直连（例如排除对端地址或使用防火墙标记）。


## DDNS

固件带 `ddns-scripts`、Cloudflare 插件 `ddns-scripts-cloudflare` 及其 LuCI 页面，出厂没有任何服务条目：`files/etc/uci-defaults/98-ddns-defaults` 在配置仍是出厂版本时删除上游自带的两条示例（`myddns_ipv4`、`myddns_ipv6`，主机和账号都是占位文字），保留配置升级沿用设备上的条目。域名和 Cloudflare API 令牌只在设备上填写，不进固件和仓库。上游的全局设置 `upd_privateip 0` 保持不变，它拒绝把私有地址写进 DNS。

在 LuCI 的“服务 → 动态 DNS”中添加服务，推荐设置：

| 设置 | 推荐值 | 理由 |
|---|---|---|
| 服务商 | `cloudflare.com-v4` | 固件只带 Cloudflare 插件 |
| 记录 | 只更新 A 记录（IPv4） | WireGuard 和 WAN 侧管理只对 IPv4 开放 |
| 获取 IP 的方式 | 网页（`ip_source` 为 `web`） | 路由器在上游路由器之后时，WAN 是内网地址，只能向外部网站查询公网 IP |
| 查询网址（`ip_url`） | 国内的查询服务，例如 `https://ip.3322.net` | 上游没有默认值；路由器上运行代理时，国外的查询网站可能经代理返回节点的地址 |
| 检查间隔 | 5 分钟 | 公网 IP 变化后几分钟内更新 |
| Cloudflare 侧 | TTL 60 秒，关闭代理（灰色云朵） | Cloudflare 代理不转发 WireGuard 的 UDP |
| API 令牌 | 只授权编辑该域名的 DNS | 令牌泄露时影响范围最小 |

DDNS 只更新 DNS 记录，不提供公网 IPv4：路由器在上游路由器之后时，WireGuard 等服务仍需要上游路由器的端口转发。

## 网络出厂配置

| 物理网口 | 分配与地址 | DHCP 服务 |
|---|---|---|
| 只有 `eth0` | `eth0` 加入 `br-lan`，LAN 通过上游 DHCP 获取地址、网关和 DNS；没有 WAN 接口，也没有静态备用地址 | 关闭 DHCPv4、DHCPv6 服务和 IPv6 RA |
| 两个及以上 | `eth0` 为 WAN，默认 DHCP；其余物理 `ethN` 按编号加入 `br-lan`，LAN 地址为 `192.168.72.1/24` | LAN 沿用官方 DHCP 服务默认值 |

单口管理地址从上游路由器的租约列表查询。这里的 DHCP 客户端和 DHCP 服务端是不同角色：单口仍可向上游申请地址，但不向同网段其他设备分配地址。DHCPv6 客户端沿用官方生成逻辑；关闭的是服务端及 RA。

`files/etc/board.d/03-network-defaults` 用上游 `uci-defaults.sh` 的 helper 只描述端口分配和接口协议。官方 `config_generate` 生成 UCI 网络配置，官方 `15_odhcpd` 根据 LAN 协议设置 DHCP/RA 服务模式，不额外覆盖这些服务的脚本或配置文件。

网口统计采用 board detection 阶段已加载驱动的物理有线 `ethN`，与是否插线无关；桥、VLAN、无线和虚拟接口不参与计数。当前不处理 SFP 混合布局或专用端口命名。上游 `02_network` 已描述端口的板卡（如 PC Engines APU）和没有物理 `eth0` 的设备保留上游布局，LAN 地址也是上游的 `192.168.1.1`。后加载、新插入的网卡不自动重排已有配置。Linux 接口编号未必对应机身插孔标签，首次使用需核对。

这些规则仅用于生成出厂配置；保留配置升级沿用用户设置，恢复出厂后重新生成。

## 版本

`profiles/build.env` 固定 OpenWrt 版本和官方 ImageBuilder 容器的 digest。`scripts/update-pins.sh` 把它们更新到同一系列（现为 25.12.x）的最新补丁版本；出现新的发布系列时只输出 `notice:`，不自动切换，需要人工评估。

## 构建

在 x86_64 主机上安装并启动 Docker，然后执行：

```sh
./scripts/build.sh
```

输出保存在 `artifacts/<版本>/<UTC时间>/`，包含镜像、包清单、构建输入和日志。`./scripts/build.sh --manifest-only <文件>` 只解析软件包，不生成镜像。容器以 `--ulimit nofile=1024:524288` 启动，避免 fakeroot 在无限制 nofile 的主机上挂起。Mac 上的 amd64 仿真会让 `ucode`、`uci` 等偶发段错误，构建应在 x86_64 主机或 CI 上进行。

## 检查与测试

- `scripts/verify-image.sh`：在 ImageBuilder 容器里运行 `scripts/verify-rootfs.sh`，解开 rootfs 镜像，检查版本和目标与 `build.env` 一致、有 init、procd 和 dropbear、`lib/apk/db/installed` 里的包与本次解析出的 manifest 完全一致，并且 sing-box 是固定的版本。
- `tests/verify-network.sh <解包的rootfs目录>`：在 x86-64 Linux 上以 root 运行，复制 rootfs 后使用真实的 OpenWrt 初始化工具验证单口、双口、多口、虚拟接口过滤和保留配置。只模拟硬件枚举，不修改输入 rootfs，也不构建镜像。
- `tests/verify-system.sh <解包的rootfs目录>`：使用实际初始化工具验证上海时区、UTC+8、国内时间服务器、保留用户设置、DMI 占位符回退和正常型号识别，以及首次启动脚本只在 root 密码为空时设置初始密码、sing-box 出厂关闭、防火墙开启流量卸载、关闭 SYN 限速并添加 WAN 子网管理和 WireGuard 规则、ttyd 监听所有地址、WireGuard 接口在设备上生成密钥、删除 DDNS 示例条目，且都不覆盖设备自己的设置；还用镜像里的 `ipcalc.sh` 验证 WAN 子网识别在各种地址下的结果。
- `tests/vm/`：用 QEMU（UEFI、NVMe、两个 e1000e 网口）启动 combined EFI 镜像，`eth0` 接模拟上游，`eth1` 接 LAN 客户端。检查启动、时区与时间服务器、`192.168.72.1` 管理地址、SSH/HTTP 端口、未开启 HTTPS、网口分配、初始密码状态、流量卸载与 SYN 限速、TCP 调优参数生效、DDNS 服务启用且没有示例条目、sing-box 默认关闭及磁盘与挂载，并通过 QEMU 端口转发从 WAN 侧访问 SSH、LuCI 和 ttyd，检查 WAN 下线后拒绝、重新上线后恢复。还从宿主机经 QEMU 转发的 UDP 端口用 WireGuard 连入，检查握手并经隧道访问路由器的 SSH 和 LuCI。随后用同一镜像做一次保留配置的 `sysupgrade`：升级前添加 DDNS 条目，修改主机名、防火墙选择、IP 集条目、ttyd 监听范围、root 密码并在 /data 写入标记，升级后检查这些以及 DDNS 条目、WireGuard 的密钥、对端和隧道都被保留、首次启动脚本没有覆盖它们也没有重复添加 fstab 条目。串口仍使用上游的免密控制台。

日常小改动先做针对性验证，阶段验收时再统一构建并跑完整 VM 测试。

## GitHub Actions

工作流 `Build firmware`（`.github/workflows/build.yml`）每天北京时间 03:37 定时运行，也可以手动运行；推送代码不会触发。每次运行先执行 `scripts/update-pins.sh`，把 `profiles/build.env` 中的 OpenWrt（同一发布系列内）、ImageBuilder 和 sing-box 更新到上游最新版本：

- 定时运行且版本没有变化时到此结束，不构建。
- 版本有变化或手动运行时，构建镜像，依次运行 `scripts/verify-image.sh`、`tests/verify-network.sh`、`tests/verify-system.sh` 和含保留配置升级的 `tests/vm/`，把镜像、包清单、构建记录和测试日志保存为工作流产物，保留 30 天。
- 版本有变化且全部测试通过时，以 `github-actions[bot]` 的身份把新的 `profiles/build.env` 提交到运行所在的分支；任何一步失败都不提交，版本保持原样。
- 出现更新的 OpenWrt 发布系列，或上游未改版本号就替换了已固定的文件时，运行页面显示警告，不自动切换。

工作流不发布 Release，也不会自动刷机。
