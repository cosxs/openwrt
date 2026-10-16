# x86-64 OpenWrt 基线

从官方 OpenWrt `x86/64 / generic` 出发的基线，使用官方 ImageBuilder 和默认软件包，通过 `profiles/packages.txt` 与 `files/` 逐项增加定制。

本基线不集成 Docker、DDNS、UPnP 或 NextTrace。

初始登录使用 `root` / `159357`。首次启动脚本仅在 root 密码为空时设置该密码；保留配置升级时沿用已有密码，恢复出厂后重新使用初始密码。串口登录仍沿用上游的 `ttylogin` 默认设置，与网络登录密码独立。

出厂时区为 `Asia/Shanghai`，对应系统时区 `CST-8`（UTC+8）。由官方配置生成流程写入新系统，再补齐 LuCI 的时区名称；已有其他时区保持不变。BIOS 的系统厂商或产品名称为裸 `Default` 时，使用有效的主板厂商和型号补齐显示，并沿用上游规则生成板卡标识；没有有效主板信息时保留上游结果。

防火墙出厂开启软件流量卸载，并关闭 fw4 在 input 链上的 SYN 限速（每秒 25 个、突发 50 个）：路由器把连接重定向到本机服务时，这些连接都经过 input 链，LAN 的突发新连接会超时。WAN 区域本来就拒绝新的入站连接。只在防火墙配置仍是出厂版本时修改，保留配置升级沿用用户设置。

从 WAN 所在的子网可以管理路由器：SSH（22）、LuCI（80）和网页终端 ttyd（7681）只对这个子网开放，仅限 IPv4。`files/etc/hotplug.d/iface/30-wan-admin-subnet` 在 WAN 上线、地址更新或下线时，把 WAN 的子网写入防火墙集合 `wan_admin_subnet`；只有私有 IPv4 地址且前缀在 /24 到 /30 之间才会写入，也就是常见的上游家用路由器网段。公网地址、PPPoE 的 /32 地址、运营商分配的大网段（如 10.183.0.0/16）或 WAN 下线时集合为空，WAN 侧不开放任何端口；WAN 的公网 IPv6 地址始终不开放。集合文件在内存里，每次开机从空集合开始。需要额外放行的网段可以在 LuCI 的“防火墙 → IP 集”里给 `wan_admin_subnet` 添加条目。为了让 LuCI 的终端页面从 WAN 侧可用，ttyd 出厂监听所有地址，访问由这条防火墙规则控制。

LuCI 只提供 HTTP，镜像不带生成自签证书的工具（`luci-ssl` 带来的 `px5g-mbedtls`）。uhttpd 的出厂配置仍监听 443，找不到证书时自动跳过 HTTPS；把证书放到 `/etc/uhttpd.crt` 和 `/etc/uhttpd.key` 后重启 uhttpd 即启用 HTTPS，例如以后用自己域名申请的正式证书。不要在只有 HTTP 时把 LuCI 转发到公网。

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
- `tests/verify-system.sh <解包的rootfs目录>`：使用实际初始化工具验证上海时区、UTC+8、保留用户设置、DMI 占位符回退和正常型号识别，以及首次启动脚本只在 root 密码为空时设置初始密码、sing-box 出厂关闭、防火墙开启流量卸载、关闭 SYN 限速并添加 WAN 子网管理规则、ttyd 监听所有地址，且都不覆盖设备自己的设置；还用镜像里的 `ipcalc.sh` 验证 WAN 子网识别在各种地址下的结果。
- `tests/vm/`：用 QEMU（UEFI、NVMe、两个 e1000e 网口）启动 combined EFI 镜像，`eth0` 接模拟上游，`eth1` 接 LAN 客户端。检查启动、`192.168.72.1` 管理地址、SSH/HTTP 端口、未开启 HTTPS、网口分配、初始密码状态、流量卸载与 SYN 限速、sing-box 默认关闭及磁盘与挂载，并通过 QEMU 端口转发从 WAN 侧访问 SSH、LuCI 和 ttyd，检查 WAN 下线后拒绝、重新上线后恢复。串口仍使用上游的免密控制台。

日常小改动先做针对性验证，阶段验收时再统一构建并跑完整 VM 测试。

## 调度

本分支没有自动调度，也没有发布脚本：更新、构建和验证都由人工调用上面的脚本，不会自动刷机。
