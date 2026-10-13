# x86-64 OpenWrt 定制固件

基于官方 OpenWrt 25.12 的 `x86/64 / generic` ImageBuilder 构建的通用 x86-64 固件，适用于 UEFI 启动的小主机和软路由，固化网口分工、出厂设置和数据分区，并预装下表中的软件。网口约定按四网口机器设计（开发时的目标设备是一台 N100 四网口小主机）。

| 项目 | 出厂配置 |
|---|---|
| 启动 | UEFI，使用 `openwrt-<版本>-x86-64-generic-squashfs-combined-efi.img.gz` |
| WAN | Linux `eth0`，DHCP 客户端；IPv6 跟随 WAN |
| LAN | 首次启动时识别到的 `eth0` 以外所有 `ethN`，按编号顺序加入 `br-lan`。只有一个网口时不建 LAN：`eth0` 仍作为 WAN 从上游取得地址，在上游内网里可通过 WAN 侧管理访问，不会在已有网络上多出一个 DHCP 服务器 |
| 管理地址 | `192.168.72.1/24`，DHCP 沿用官方默认值 |
| 网络加速 | BBR（`kmod-tcp-bbr`）；本机 TCP 缓冲区等调优；软件流量分载出厂开启，保留配置升级沿用设备上的设置 |
| WAN 侧管理 | 出厂允许来自 WAN 口当前所在网段的 SSH（22）和网页管理（80），且只在该网段属于内网 IPv4 时生效：在任意品牌的家用路由器后面时只放行上游局域网；WAN 拿到公网地址、PPPoE 点对点地址或断开时不放行任何来源。IPv6 仍全部拒绝。保留配置升级沿用设备上的防火墙设置 |
| 初始密码 | `root` / `159357`，仅在 root 无密码时于首次启动设置；保留配置升级沿用设备上的密码。仓库和固件都是公开的，加上 WAN 侧管理默认对上游内网开放，首次登录后应立即修改 |
| 主机名 / 时区 | `linuxserver` / `Asia/Shanghai`（`CST-8`）；保留配置升级沿用设备上的设置 |
| 引导分区 | 64 MiB（官方默认 16 MiB，内核和 GRUB 约占 6.3 MiB）。保留配置升级时，配置备份暂存在这个分区里，放大后可容纳更大的备份 |
| 系统分区 | 4096 MiB。建好数据分区后，引导分区和系统分区的大小都不要再改：分区布局变化会让 sysupgrade 整盘写入，数据分区随之丢失 |
| 数据分区 | 卷标 `data` 的分区挂载到 `/data`，写盘时用目标盘的剩余空间创建（见“写盘”）；sysupgrade 和恢复出厂都不改动它 |
| 软件 | LuCI（默认主题 Argon，另带官方 Bootstrap）、中文界面、Nikki 及 Mihomo stable 核心、sing-box、Tailscale（官方源）及其 LuCI 页面、Docker/Compose（官方源）及其 LuCI 页面、DDNS（官方 `ddns-scripts`，仅 Cloudflare）及其 LuCI 页面。官方源以外的软件固定版本和 SHA256，见 `profiles/build.env`；每个 Release 附带实际安装的包清单 |
| Docker | 数据目录 `/data/docker/`；随系统启动。出厂即有 `docker` 防火墙区域及 docker→wan（容器上网）、lan→docker（局域网访问容器和映射端口）转发；容器不能主动访问局域网其他设备。`-p` 映射的端口只能从局域网访问；要对外提供服务，容器改用 host 网络（`network_mode: host`），再在 LuCI“网络 → 防火墙 → 通信规则”中放行端口（源区域 `wan`，目标区域“设备（输入）”）。LuCI 容器管理依赖的网页终端 `ttyd` 只监听 LAN 的 7681 端口，需 root 登录 |
| LuCI 主题 | 默认第三方主题 Argon（固定版本和 SHA256），首次启动时由它自己的脚本设为默认。官方 Bootstrap 也已安装，可在“系统 → 系统 → 语言和界面”中切换，保留配置升级沿用设备上的选择；设备上另装的主题被升级移除后，LuCI 退回最先注册的 Argon。没有安装 Argon 的配置插件，登录页使用主题自带的本地背景，不联网获取在线壁纸 |
| Nikki 初始状态 | 保留上游默认关闭，导入配置后再启用 |
| sing-box 初始状态 | 出厂关闭（上游包默认启用并带一个公开密码的示例服务端）；先替换 `/etc/sing-box/config.json`，再把 `sing-box.main.enabled` 设为 `1` |
| DDNS 初始状态 | 未配置。本机在其他路由器后面时 WAN 是内网地址，记录要用“通过网页查询公网 IP”（`ip_source` 设为 `web`），否则会把内网地址写进 DNS。Cloudflare API 令牌只在设备上填写，不进固件和仓库。DDNS 只更新记录，不提供公网 IPv4 |
| Tailscale 初始状态 | 服务随系统启动，未登录；在 LuCI 中登录、设置路由并点击“Auto Configure Firewall”。登录状态 `/etc/tailscale/` 随保留配置升级保留。启用 Nikki 路由器代理时，把 cgroup `services/tailscale` 排除在代理之外 |

以上 `ethN` 是 Linux 按网卡识别顺序分配的接口名称，与机身上的插口标签不一定对应；使用前应确认各口与系统接口的对应关系。Console 口为串口管理口，不属于 LAN/WAN 网口。

网口分配在开机早期生成，只包括那时已加载驱动的网卡：官方镜像在这一阶段加载 Intel `e1000e`/`igb`/`igc`、Realtek `r8169` 和 Broadcom `tg3`，覆盖常见的千兆和 2.5G 网卡。其他网卡（例如 Intel 万兆的 `ixgbe`）稍后才出现，需要在 LuCI 中手动加入 `br-lan`。

## 构建

安装并启动 Docker，然后在本仓库执行：

```sh
./scripts/build.sh
```

脚本使用按 digest 固定的官方 Linux amd64 ImageBuilder 容器，应在 x86_64 主机或 CI 上运行。Mac Apple Silicon 上的 amd64 仿真会让 `ucode`、`uci` 等程序偶发段错误，构建和验证结果不可靠。容器以 `--ulimit nofile=1024:524288` 启动，避免 fakeroot 在无限制 nofile 的主机上长时间挂起。输出保存在 `artifacts/<版本>/<UTC时间>/`，包含完整磁盘镜像、安装包 manifest、SHA256、构建输入和日志。

官方 25.12 系列的软件源会更新，产物 manifest 记录每次实际安装的版本。要得到完全相同的包集合，后续还需保存完整依赖快照或使用固定的自有软件源。

写盘和升级用 `openwrt-<版本>-x86-64-generic-squashfs-combined-efi.img.gz`。文件名与官方镜像相同，注意区分来源。构建只生成这个 squashfs EFI 磁盘镜像和它的 rootfs 镜像（供检查用）：ext4、BIOS 和 tar 包变体用不到，而每个磁盘变体都要写出并压缩一份完整分区大小的镜像。这里的时间目录用于保留每次构建结果。

`./scripts/build.sh --manifest-only <文件>` 只解析软件包、不生成镜像，几分钟内得到实际会安装的包和版本。

可对生成的 Squashfs rootfs 组件执行：

```sh
./scripts/verify-image.sh artifacts/<版本>/<时间>/*-squashfs-rootfs.img.gz
```

检查会在隔离容器中提取实际文件系统，验证首次生成、重复执行、保留配置、恢复默认的端口布局与管理地址，初始 root 密码只在无密码时写入，主机名和时区只用于新生成的系统配置，流量分载和 WAN 侧管理规则只用于出厂防火墙配置、管理网段只跟随内网 WAN 网段，数据分区挂载和 Docker 数据目录只用于新配置，Argon 为固定版本的默认 LuCI 主题且设备上的选择会保留，以及 Nikki 默认关闭、Mihomo 核心存在、BBR 为默认拥塞控制、sing-box 为固定版本且默认关闭、Tailscale 和 Docker 可执行。它不启动设备网络，也不替代实机启动验证。

`tests/vm/` 在 QEMU 虚拟机里测试完整磁盘镜像（需要 root、`qemu-system-x86`、`ovmf`、`sshpass`、`busybox`，有 KVM 时自动使用）：

```sh
sudo tests/vm/run.sh artifacts/<版本>/<时间>/*-squashfs-combined-efi.img.gz
```

它按“写盘”一节的方式建好 16 GiB 的 NVMe 磁盘（含数据分区），用 UEFI 和 4 个网口启动，从网络命名空间里的 LAN 客户端检查首次启动后的网络、调优、软件默认状态、初始密码登录、默认主题、WAN 侧管理、数据分区、Docker 和容器联网，再用同一镜像做一次保留配置的 sysupgrade，检查设置、数据分区和 Docker 数据都保留。任一检查失败时以非零状态退出。

## 自动构建与发布

GitHub Actions 工作流 `Build firmware`（`.github/workflows/build.yml`）：

- 触发：推送到 `main`（配方、脚本、测试或工作流有改动时）、每天北京时间 03:37 定时运行，以及手动运行（可选“强制构建”）。
- 定时和手动运行先执行 `scripts/update-pins.sh`，把固定的上游版本更新到最新：同一 OpenWrt 系列（25.12.x）的最新小版本及其 ImageBuilder digest、Nikki、sing-box 和 Argon。新资产都会下载并计算 SHA256，与 GitHub 公布的摘要核对。出现更新的 OpenWrt 大版本系列，或上游在版本号不变的情况下替换了文件时，不自动更改，而是开一个 issue 提醒。
- 然后只解析软件包（`build.sh --manifest-only`），由 `scripts/build-state.sh` 计算配方文件和包清单的状态，与最近一次 Release 附带的 `build-state.txt` 比较；没有变化就结束，不构建。官方软件源里的包更新也会体现在包清单里。
- 有变化时构建，依次运行镜像检查和虚拟机测试（GitHub 的 Linux runner 支持 KVM）。全部通过后由 `scripts/release.sh` 发布：先把更新后的固定版本提交并推送到 `main`，再创建 Release，附带磁盘镜像、包清单、构建信息、`build-state.txt`、检查日志和 `SHA256SUMS`，说明里列出配方更新和相对上一个 Release 的软件包版本变化。任何一步失败都不提交、不发布，GitHub 会发邮件通知。
- 不会自动刷机：刷机仍按“写盘”或保留配置的 sysupgrade 手动进行。
- 仓库和 Release 都是公开的。

## 配方

- `profiles/build.env`：官方版本、容器 digest、分区大小，以及 Nikki 归档、sing-box APK 和 Argon 主题 APK 的来源/摘要。
- `profiles/packages.txt`：在官方 generic 默认包基础上增加的软件。
- `profiles/nikki-apks.txt`：从固定 Nikki Release 中选入的 APK。
- `files/etc/board.d/03-defaults`：LAN/WAN 出厂默认布局、管理地址、主机名和时区。
- `files/etc/uci-defaults/90-initial-root-password`：初始 root 密码，只保存 SHA-512 crypt 哈希。
- `files/etc/uci-defaults/91-zonename`：为新生成的时区补上 LuCI 使用的时区名。
- `files/etc/uci-defaults/92-firewall-defaults`：防火墙仍是出厂配置时，开启软件流量分载，并加入地址集合 `wan_admin_subnet`（从 `/etc/wan-admin-subnet` 加载）和引用它的 `wan_private_admin` 规则（仅 IPv4：WAN 口可能同时有公网 IPv6 地址，不能对 IPv6 开放）。
- `files/etc/hotplug.d/iface/30-wan-admin-subnet`：WAN 连上或地址变化时计算当前网段，只有内网 IPv4 且前缀在 /8–/30 之间才写入 `/etc/wan-admin-subnet`，否则写空；内容变化时执行 `fw4 reload-sets`。直接按“WAN 当前网段”放行并不安全：光猫桥接后用 DHCP/IPoE 拿到公网地址时，当前网段就是运营商的公网网段。
- `files/etc/wan-admin-subnet`：上述地址文件的出厂版本（空）。放在 `/etc` 而不是 `/var/run`，是为了防火墙在网络启动前加载时文件一定存在。
- `files/etc/config/sing-box`：上游包的配置文件，仅把 `enabled` 改为 `0`；它是包声明的 conffile，保留配置升级沿用设备上的版本。服务启用状态不用 `DISABLED_SERVICES` 控制，因为 sysupgrade 只保留“已禁用”的服务，设备上启用后会在升级时被关回去。
- `files/etc/sysctl.d/90-tcp-tuning.conf`：路由器本机终结的 TCP 连接的调优，在 BBR 配置之后加载；设备上可用 `/etc/sysctl.conf` 覆盖。
- `files/etc/uci-defaults/93-data-mount`：fstab 里还没有挂载卷标 `data` 的分区、也没有挂到 `/data` 的条目时，添加按卷标 `data` 挂载到 `/data` 的条目。
- `files/etc/uci-defaults/94-dockerd-defaults`：dockerd 配置仍是出厂版本时，把数据目录改到 `/data/docker/`，并让 WAN→docker0 的阻断规则只拦截新连接。OpenWrt 的根目录是 overlayfs，不能承载 Docker 的 overlay 存储，系统分区的可写层也会在每次 sysupgrade 时清空；dockerd 默认的阻断规则不区分连接状态，会把容器自己发起的连接的回包一并拒绝，容器因此无法上网。
- `files/etc/uci-defaults/95-docker-firewall`：还没有 `docker` 防火墙区域时，按 dockerd 自身 `uciadd` 的命名预先建好 `docker` 接口、`docker0` 网桥和区域，并加上 docker→wan、lan→docker 转发。fw4 不放行没有 forwarding 的跨区流量，只靠 dockerd 建的区域，容器无法上网。
- `scripts/build.sh`、`scripts/imagebuilder.sh`：本地和 CI 共用的构建入口。
- `scripts/verify-image.sh`、`tests/verify-rootfs.sh`：镜像内容检查；`tests/vm/`：虚拟机测试。
- `scripts/update-pins.sh`、`scripts/build-state.sh`、`scripts/release.sh`：自动构建与发布用的固定版本更新、构建状态和发布脚本。

网络布局通过官方 `board.d` 和 `config_generate` 机制生成。首次安装、恢复出厂会采用上述布局；保留配置升级会继续使用已经保存的 `/etc/config/network`。因此从目前的原版官方镜像保留设置升级时，旧的端口配置也会保留，不能期待刷入后自动换口。首次使用新布局可采用全新写盘，或在升级时明确选择不保留旧设置。

Nikki 归档校验固定 SHA256，只导入需要的 APK，不导入其原始签名索引。官方 ImageBuilder 会建立并签署本地索引，安装时保持 `CONFIG_SIGNATURE_CHECK=y`。这个信任过程依据已固定的发布资产摘要，不表示已经验证 Nikki 上游索引的签名。构建中的本地签名私钥只存在于临时容器，不纳入镜像或 Artifact。

本配方目前使用官方运行时软件源；自有源域名及镜像托管方案确定后，可分别配置 ImageBuilder 下载源和固件里的 APK 源。Nikki 配置/订阅、SSH 密钥需要在设备上设置。

## 写盘

全新写盘时，在首次从目标盘启动前创建数据分区。以下以 NVMe 盘 `/dev/nvme0n1` 为例，SATA 盘一般是 `/dev/sda`，分区名为 `/dev/sda3`：

1. 写入镜像（会覆盖整块盘）：`gzip -dc <镜像>.img.gz | dd of=/dev/nvme0n1 bs=4M conv=fsync`
2. 把 GPT 备份头移到盘尾，用剩余空间追加一个分区。
3. 格式化：`mkfs.ext4 -L data /dev/nvme0n1p3`（分区号以实际为准）。

首次从目标盘启动前，拔掉其他装有同版本 OpenWrt 的启动盘（例如测试用的 U 盘）：同一 ImageBuilder 版本构建的镜像磁盘 GUID 和分区 UUID 相同，内核按 `root=PARTUUID=` 查找系统分区，可能挂载到错误的盘。

首次启动时会自动按卷标挂载到 `/data`，Docker 随后使用其中的 `docker/` 目录。之后的保留配置升级只重写引导和系统分区，数据分区保持不变。

## 设备验收

写盘前检查目标镜像的 SHA256。写入会覆盖目标盘内容；首次启动用电脑连接任一 LAN 口（`eth0` 以外的网口），上游连接 WAN `eth0`，再访问 `http://192.168.72.1`。

设备上检查 `br-lan` 端口、WAN 租约和默认路由，确认各 LAN 口都能获取地址和进入 LuCI，再验证 Nikki 的配置导入、DNS 和代理连接。宿主机上生成镜像不等于这些实机检查已经完成。

## 参考

- [官方 ImageBuilder](https://openwrt.org/docs/guide-user/additional-software/imagebuilder)
- [官方网络默认生成器](https://github.com/openwrt/openwrt/blob/v25.12.5/package/base-files/files/bin/config_generate)
- [Nikki](https://github.com/nikkinikki-org/OpenWrt-nikki/releases)
- [sing-box](https://github.com/SagerNet/sing-box/releases)
- [luci-theme-argon](https://github.com/jerrykuku/luci-theme-argon/releases)
