# x86-64 OpenWrt 定制固件

基于官方 OpenWrt 25.12 的 `x86/64 / generic` ImageBuilder 构建的通用 x86-64 固件，适用于 UEFI 启动的小主机和软路由，固化网口分工、出厂设置和数据分区，并预装下表中的软件。网口约定按四网口机器设计（开发时的目标设备是一台 N100 四网口小主机）。

| 项目 | 出厂配置 |
|---|---|
| 启动 | UEFI，使用 `openwrt-<版本>-x86-64-generic-squashfs-combined-efi.img.gz` |
| WAN | Linux `eth0`，DHCP 客户端；IPv6 跟随 WAN |
| LAN | 首次启动时识别到的 `eth0` 以外所有 `ethN`，按编号顺序加入 `br-lan`。只有一个网口时不建 LAN：`eth0` 仍作为 WAN 从上游取得地址，在上游内网里可通过 WAN 侧管理访问，不会在已有网络上多出一个 DHCP 服务器 |
| 管理地址 | `192.168.72.1/24`，DHCP 沿用官方默认值 |
| 网络加速 | BBR（`kmod-tcp-bbr`）；本机 TCP 缓冲区等调优；软件流量分载出厂开启；fw4 的 SYN 速率限制（`synflood_protect`，每秒 25 个、突发 50）出厂关闭：sing-box 把局域网的 TCP 重定向到本机端口，新连接都落在 input 链上，开着限速时一次打开很多连接会有一部分 SYN 被丢弃、靠重传才能建立。保留配置升级沿用设备上的设置 |
| WAN 侧管理 | 出厂允许来自 WAN 口当前所在网段的 SSH（22）、网页管理（80）和网页终端（7681），且只在该网段属于内网 IPv4 时生效：在任意品牌的家用路由器后面时只放行上游局域网；WAN 拿到公网地址、PPPoE 点对点地址或断开时不放行任何来源。IPv6 仍全部拒绝。保留配置升级沿用设备上的防火墙设置 |
| 初始密码 | `root` / `159357`，仅在 root 无密码时于首次启动设置；保留配置升级沿用设备上的密码。仓库和固件都是公开的，加上 WAN 侧管理默认对上游内网开放，首次登录后应立即修改 |
| 主机名 / 时区 | `OpenWrt`（上游默认）/ `Asia/Shanghai`（`CST-8`）；保留配置升级沿用设备上的设置 |
| DNS 上游 | dnsmasq 出厂只向 `223.5.5.5` 和 `119.29.29.29` 转发（`noresolv`），不使用 WAN 下发的 DNS。WAN 下发的 DNS 里可能有上游路由器的 IPv6 链路本地地址，路由器上的防火墙或隧道把 DNS 查询重定向到本机解析器时，这种地址的查询可能拦截不到。DHCP 仍把本机作为 LAN 的 DNS。保留配置升级沿用设备上的设置；在 LuCI“网络 → DHCP/DNS”中可改回 WAN 下发的 DNS（取消“忽略解析文件”并删去 DNS 转发） |
| 引导分区 | 64 MiB（官方默认 16 MiB，内核和 GRUB 约占 6.3 MiB）。保留配置升级时，配置备份暂存在这个分区里，放大后可容纳更大的备份 |
| 系统分区 | 4096 MiB。建好数据分区后，引导分区和系统分区的大小都不要再改：分区布局变化会让 sysupgrade 整盘写入，数据分区随之丢失 |
| 数据分区 | 全新写盘后首次启动时，自动用系统盘的剩余空间建分区（分区名和卷标都是 `data`，ext4），挂载到 `/data`（见“写盘”）；剩余空间不少于 2 GiB 时，数据分区让出盘尾的 1 GiB 给下面的 swap 分区；sysupgrade 和恢复出厂都不改动它 |
| Swap 分区 | 盘尾 1 GiB 的分区（分区名和卷标都是 `swap`），全新写盘后首次启动时与数据分区一起建好；`fstab` 里有一条按卷标 `swap` 启用的 swap 段，开机由系统自带的 `block mount` 启用。剩余空间不足 2 GiB 时不建，只有数据分区。已经建好数据分区的盘（保留配置升级、或旧版固件装的盘）不会补建 swap 分区，需要时见“写盘”手动创建。不需要 swap 时，在 LuCI“系统 → 挂载点”里停用它，或删去 fstab 的 swap 段；sysupgrade 和恢复出厂不改动这个分区 |
| 软件 | LuCI（默认主题 Footstrap，另带官方 Bootstrap）、中文界面、sing-box、Docker/Compose（官方源）及其 LuCI 页面、网页终端 ttyd 及其 LuCI 页面、DDNS（官方 `ddns-scripts`，仅 Cloudflare）及其 LuCI 页面、UPnP IGD 和 NAT-PMP 端口映射（官方 `miniupnpd-nftables`）及其 LuCI 页面。官方源以外的软件固定版本和 SHA256，见 `profiles/build.env`；每个 Release 附带实际安装的包清单 |
| Docker | 数据目录 `/data/docker/`；随系统启动。开机时先把数据目录所在的挂载点（`/data`）设为 shared 传播，dockerd 就不再把数据目录原地重复挂载，LuCI“存储”里不会多出一行 `/data/docker`。出厂即有 `docker` 防火墙区域及 docker→wan（容器上网）、lan→docker（局域网访问容器和映射端口）转发；容器不能主动访问局域网其他设备。`-p` 映射的端口只能从局域网访问；要对外提供服务，容器改用 host 网络（`network_mode: host`），再在 LuCI“网络 → 防火墙 → 通信规则”中放行端口（源区域 `wan`，目标区域“设备（输入）”）。LuCI 容器管理依赖的网页终端 `ttyd`（LuCI“服务 → 终端”）监听所有地址的 7681 端口，需 root 登录；WAN 侧只对上游内网放行（见“WAN 侧管理”） |
| LuCI 主题 | 默认主题 [Footstrap](https://github.com/VizzleTF/luci-theme-footstrap)，用官方 luci 软件源里的 `luci-theme-footstrap`（只依赖 `luci-base`，版本随官方源，不单独固定）。出厂时由 `29-luci-default-theme` 设为默认：luci 的出厂配置本来就写着 Bootstrap，两个主题包自带的首次启动脚本都不会改动已有的选择。官方 Bootstrap 也已安装，可在“系统 → 系统 → 语言和界面”中切换，保留配置升级沿用设备上的选择；设备上另装的主题被升级移除后，LuCI 退回最先注册的主题。Footstrap 不联网获取壁纸或字体；它自带的设置项没有中文翻译（上游只提供 es、ru），固件不安装这两个语言包 |
| sing-box 初始状态 | 出厂关闭（上游包默认启用并带一个公开密码的示例服务端）；先替换 `/etc/sing-box/config.json`，再把 `sing-box.main.enabled` 设为 `1`。审核过的配置模板、部署步骤和各字段说明见 [`docs/sing-box/`](docs/sing-box/README.md) |
| DDNS 初始状态 | 未配置，也没有上游包自带的两条示例服务。本机在其他路由器后面时 WAN 是内网地址，记录要用“通过网页查询公网 IP”（`ip_source` 设为 `web`），否则会把内网地址写进 DNS。Cloudflare API 令牌只在设备上填写，不进固件和仓库。DDNS 只更新记录，不提供公网 IPv4 |
| UPnP 初始状态 | 出厂关闭（上游默认），在 LuCI“服务”菜单的 UPnP 页面开启。上游默认只允许设备为自己的地址映射 1024–65535 端口。端口映射规则由 fw4 自动加载，不改动防火墙配置。WAN 是内网地址（本机在其他路由器后面）时 miniupnpd 不做端口映射，要用 UPnP 需要本机拨号直接拿到公网 IPv4，或在 UPnP 设置里开启 STUN 探测外层的公网地址；外层 NAT 是限制型时，开启 STUN 也无法映射 |

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

检查会在隔离容器中提取实际文件系统，验证首次生成、重复执行、保留配置、恢复默认的端口布局与管理地址，初始 root 密码只在无密码时写入，主机名和时区只用于新生成的系统配置，流量分载、SYN 速率限制关闭和 WAN 侧管理规则只用于出厂防火墙配置、管理网段只跟随内网 WAN 网段，数据分区挂载和 Docker 数据目录只用于新配置、开机时把 Docker 数据目录所在的挂载点设为 shared（根文件系统除外），Footstrap 为固定版本的默认 LuCI 主题且设备上的选择会保留，DMI 系统字段为 `Default` 时型号取主板字段，以及 BBR 为默认拥塞控制、sing-box 为固定版本且默认关闭、UPnP 默认关闭、Docker 可执行。它不启动设备网络，也不替代实机启动验证。

`tests/vm/` 在 QEMU 虚拟机里测试完整磁盘镜像（需要 root、`qemu-system-x86`、`ovmf`、`sshpass`、`busybox`、`miniupnpc`，有 KVM 时自动使用）：

```sh
sudo tests/vm/run.sh artifacts/<版本>/<时间>/*-squashfs-combined-efi.img.gz
```

它把镜像写入一块 16 GiB 的虚拟 NVMe 盘（数据分区由固件首次启动时自行创建），用 UEFI 和 4 个网口启动，从网络命名空间里的 LAN 客户端检查首次启动后的网络、调优、软件默认状态、初始密码登录、默认主题、WAN 侧管理、数据分区、UPnP 端口映射（WAN 为内网地址时拒绝映射，声明公网地址后从 WAN 侧经映射连到 LAN 客户端）、Docker 和容器联网，再用同一镜像做一次保留配置的 sysupgrade，检查设置、数据分区和 Docker 数据都保留。任一检查失败时以非零状态退出。

## 自动构建与发布

GitHub Actions 工作流 `Build firmware`（`.github/workflows/build.yml`）：

- 触发：每天北京时间 03:37 定时运行，以及在 Actions 页面手动运行（可选“强制构建”）。推送代码不会触发构建，配方的改动在下一次定时或手动运行时构建发布。
- 每次运行先执行 `scripts/update-pins.sh`，把固定的上游版本更新到最新：同一 OpenWrt 系列（25.12.x）的最新小版本及其 ImageBuilder digest 和 sing-box。新资产都会下载并计算 SHA256，与 GitHub 公布的摘要核对。出现更新的 OpenWrt 大版本系列，或上游在版本号不变的情况下替换了文件时，不自动更改，而是开一个 issue 提醒。
- 然后只解析软件包（`build.sh --manifest-only`），由 `scripts/build-state.sh` 计算配方文件和包清单的状态，与最近一次 Release 附带的 `build-state.txt` 比较；没有变化就结束，不构建。官方软件源里的包更新也会体现在包清单里。
- 有变化时构建，依次运行镜像检查和虚拟机测试（GitHub 的 Linux runner 支持 KVM）。全部通过后由 `scripts/release.sh` 发布：先把更新后的固定版本提交并推送到 `main`，再创建 Release，附带磁盘镜像、包清单、构建信息、`build-state.txt`、检查日志和 `SHA256SUMS`，说明里列出配方更新和相对上一个 Release 的软件包版本变化。任何一步失败都不提交、不发布，GitHub 会发邮件通知。
- 不会自动刷机：刷机仍按“写盘”或保留配置的 sysupgrade 手动进行。
- 仓库和 Release 都是公开的。

## 配方

- `profiles/build.env`：官方版本、容器 digest、分区大小，以及 sing-box APK 的来源/摘要。
- `profiles/packages.txt`：在官方 generic 默认包基础上增加的软件。
- `files/lib/preinit/01_sysinfo_dmi_default`：开机早期在上游 x86 的 `01_sysinfo` 之后运行。有些主板 BIOS 把 DMI 的系统厂商或产品型号填成单独的 `Default`，上游脚本不把它当占位词，LuCI 就会显示型号 `Default Default`；这时改用主板厂商和主板型号（与上游对 `Default string` 等占位词的处理相同），主板字段也是占位词时保留上游结果。
- `files/etc/board.d/03-defaults`：LAN/WAN 出厂默认布局、管理地址和时区。
- `files/etc/uci-defaults/90-initial-root-password`：初始 root 密码，只保存 SHA-512 crypt 哈希。
- `files/etc/uci-defaults/91-zonename`：为新生成的时区补上 LuCI 使用的时区名。
- `files/etc/uci-defaults/92-firewall-defaults`：防火墙仍是出厂配置时，开启软件流量分载、关闭 SYN 速率限制，并加入地址集合 `wan_admin_subnet`（从 `/etc/wan-admin-subnet` 加载）和引用它的 `wan_private_admin` 规则（仅 IPv4：WAN 口可能同时有公网 IPv6 地址，不能对 IPv6 开放）。
- `files/etc/uci-defaults/29-luci-default-theme`：luci 配置仍是出厂版本时，把默认主题设为 Footstrap。名字排在两个主题包的 `30_luci-theme-*` 之前：它们只注册主题，遇到已有的 `mediaurlbase` 不改动，出厂配置里这一项是 Bootstrap。保留配置升级时 luci 配置已和出厂版本不同，沿用设备上的选择。
- `files/etc/hotplug.d/iface/30-wan-admin-subnet`：WAN 连上或地址变化时计算当前网段，只有内网 IPv4 且前缀在 /8–/30 之间才写入 `/etc/wan-admin-subnet`，否则写空；内容变化时执行 `fw4 reload-sets`。直接按“WAN 当前网段”放行并不安全：光猫桥接后用 DHCP/IPoE 拿到公网地址时，当前网段就是运营商的公网网段。
- `files/etc/wan-admin-subnet`：上述地址文件的出厂版本（空）。放在 `/etc` 而不是 `/var/run`，是为了防火墙在网络启动前加载时文件一定存在。
- `files/etc/config/ddns`：上游包的配置文件，只保留 `global` 段，去掉 `myddns_ipv4`、`myddns_ipv6` 两条示例服务（服务商 dyndns.org 未安装，账号和域名都是占位文字）。DDNS 服务仍随系统启用，只运行在 LuCI 中启用的条目；它是包声明的 conffile，保留配置升级沿用设备上的版本。
- `files/etc/config/sing-box`：上游包的配置文件，仅把 `enabled` 改为 `0`；它是包声明的 conffile，保留配置升级沿用设备上的版本。服务启用状态不用 `DISABLED_SERVICES` 控制，因为 sysupgrade 只保留“已禁用”的服务，设备上启用后会在升级时被关回去。
- `files/etc/config/ttyd`：上游包的配置文件，仅去掉 `interface '@lan'`，让 ttyd 监听所有地址（上游默认只绑定 LAN 网桥，从 WAN 侧打开 LuCI 时终端页面的 7681 端口会被拒绝）；WAN 侧是否可达由防火墙决定，见“WAN 侧管理”。它是包声明的 conffile，保留配置升级沿用设备上的版本。
- `files/etc/sysctl.d/90-tcp-tuning.conf`：路由器本机终结的 TCP 连接的调优，在 BBR 配置之后加载；设备上可用 `/etc/sysctl.conf` 覆盖。
- `files/etc/uci-defaults/96-data-partition`：全新写盘后首次启动时创建数据分区和盘尾的 swap 分区，条件见“写盘”。分区建好后先把 swap 分区做成交换空间、最后才格式化数据分区：卷标 `data` 一出现，之后每次开机都直接跳过，所以中断的首次启动（已建分区、尚未格式化）下次启动会补做两者的格式化；已有文件系统的数据分区从不重新格式化。
- `files/etc/uci-defaults/93-data-mount`：fstab 里还没有挂载卷标 `data` 的分区、也没有挂到 `/data` 的条目时，添加按卷标 `data` 挂载到 `/data` 的条目。
- `files/etc/uci-defaults/98-swap-mount`：fstab 里还没有卷标为 `swap` 的 swap 段时，添加一条按卷标 `swap` 启用的 swap 段；设备上已有（例如在 LuCI 里停用过）的不改动。
- `files/etc/uci-defaults/94-dockerd-defaults`：dockerd 配置仍是出厂版本时，把数据目录改到 `/data/docker/`，并让 WAN→docker0 的阻断规则只拦截新连接。OpenWrt 的根目录是 overlayfs，不能承载 Docker 的 overlay 存储，系统分区的可写层也会在每次 sysupgrade 时清空；dockerd 默认的阻断规则不区分连接状态，会把容器自己发起的连接的回包一并拒绝，容器因此无法上网。
- `files/etc/init.d/dockerd-root-shared`：开机第 12 位运行（`fstab` 挂载之后、`dockerd` 之前），把 dockerd 数据目录所在的挂载点设为 shared 传播。dockerd 要求这个挂载点是 shared，OpenWrt 上的挂载都是 private，dockerd 就会把数据目录原地再挂一次并设为 shared；先设好就不会多出这个挂载，与其他用 systemd 的系统一致。数据目录还不存在时按最近的上级目录查找；数据目录在根文件系统上时不改动根文件系统。
- `files/etc/uci-defaults/95-docker-firewall`：还没有 `docker` 防火墙区域时，按 dockerd 自身 `uciadd` 的命名预先建好 `docker` 接口、`docker0` 网桥和区域，并加上 docker→wan、lan→docker 转发。fw4 不放行没有 forwarding 的跨区流量，只靠 dockerd 建的区域，容器无法上网。
- `files/etc/uci-defaults/97-dnsmasq-upstream`：dnsmasq 配置里既没有 `server` 列表也没有 `noresolv` 设置时，改为只向 `223.5.5.5`、`119.29.29.29` 转发并忽略 WAN 下发的 DNS，原因见上表。设备上已有任一设置（例如保留配置升级带来的）时不改动。
- `docs/sing-box/`：sing-box 配置模板（节点和面板密钥是占位值）及其说明，不打包进固件；镜像检查用固件里的 sing-box 对它执行 `sing-box check`，sing-box 升级后模板不再兼容时构建失败。
- `scripts/build.sh`、`scripts/imagebuilder.sh`：本地和 CI 共用的构建入口。
- `scripts/verify-image.sh`、`tests/verify-rootfs.sh`：镜像内容检查；`tests/vm/`：虚拟机测试。
- `scripts/update-pins.sh`、`scripts/build-state.sh`、`scripts/release.sh`：自动构建与发布用的固定版本更新、构建状态和发布脚本。

网络布局通过官方 `board.d` 和 `config_generate` 机制生成。首次安装、恢复出厂会采用上述布局；保留配置升级会继续使用已经保存的 `/etc/config/network`。因此从目前的原版官方镜像保留设置升级时，旧的端口配置也会保留，不能期待刷入后自动换口。首次使用新布局可采用全新写盘，或在升级时明确选择不保留旧设置。

sing-box 的 APK 校验固定 SHA256 后导入。官方 ImageBuilder 会为它建立并签署本地索引，安装时保持 `CONFIG_SIGNATURE_CHECK=y`。这个信任过程依据已固定的发布资产摘要，不表示已经验证上游的签名。构建中的本地签名私钥只存在于临时容器，不纳入镜像或 Artifact。

本配方目前使用官方运行时软件源；自有源域名及镜像托管方案确定后，可分别配置 ImageBuilder 下载源和固件里的 APK 源。sing-box 配置、SSH 密钥需要在设备上设置。

## 写盘

全新安装只需把镜像写入目标盘，数据分区由固件首次启动时自动创建：

- 在其他系统里写盘（会覆盖整块盘）：`gzip -dc <镜像>.img.gz | dd of=/dev/nvme0n1 bs=4M conv=fsync`（SATA 盘一般是 `/dev/sda`）；
- 或在已安装的 OpenWrt 上不保留配置升级：`sysupgrade -n -v <镜像文件或网址>`。分区布局与盘上不同（例如从其他固件换装）时会整盘写入，相同时只重写引导和系统分区，数据分区保留。

首次启动时，`files/etc/uci-defaults/96-data-partition` 检查系统盘：只有固件自带的分区（1、2、128）、剩余空间至少 1 GiB、且任何盘上都没有卷标 `data` 的文件系统时，才把分区表的 GPT 备份头移到盘尾，用剩余空间建一个名为 `data` 的分区并格式化为 ext4（卷标 `data`），原先留在这片空间里的内容会被覆盖。剩余空间不少于 2 GiB 时，盘尾的 1 GiB 先划给名为 `swap` 的分区（做成交换空间，卷标 `swap`），数据分区在它前面结束。随后按卷标挂载到 `/data`，Docker 使用其中的 `docker/` 目录，swap 分区由 `fstab` 启用。盘上已有其他分区时它不做任何改动，此时可手动创建，例如在 16 GiB 的盘上：`parted -s -f /dev/nvme0n1 print`、`parted -s /dev/nvme0n1 mkpart data ext4 4161MiB -1GiB`、`parted -s /dev/nvme0n1 mkpart swap linux-swap -1GiB 100%`、`partx -a /dev/nvme0n1`、`mkswap -L swap /dev/nvme0n1p4`、`mkfs.ext4 -L data /dev/nvme0n1p3`（分区号以实际为准），然后重启；只补建 swap 分区时，只需后三步里属于它的部分，并保证盘尾有未分配的 1 GiB。创建结果记录在内核日志中（`dmesg | grep data-partition`）。

首次从目标盘启动或升级前，拔掉其他装有同版本 OpenWrt 的盘（例如测试用的 U 盘）：同一 ImageBuilder 版本构建的镜像磁盘 GUID 和分区 UUID 相同，内核按 `root=PARTUUID=` 查找系统分区，升级脚本也按磁盘 GUID 查找启动盘，可能用错盘。

之后的保留配置升级只重写引导和系统分区，数据分区和 swap 分区保持不变。

## 设备验收

写盘前检查目标镜像的 SHA256。写入会覆盖目标盘内容；首次启动用电脑连接任一 LAN 口（`eth0` 以外的网口），上游连接 WAN `eth0`，再访问 `http://192.168.72.1`。

设备上检查 `br-lan` 端口、WAN 租约和默认路由，确认各 LAN 口都能获取地址和进入 LuCI，再验证 sing-box 的配置、DNS 和代理连接。宿主机上生成镜像不等于这些实机检查已经完成。

## 参考

- [官方 ImageBuilder](https://openwrt.org/docs/guide-user/additional-software/imagebuilder)
- [官方网络默认生成器](https://github.com/openwrt/openwrt/blob/v25.12.5/package/base-files/files/bin/config_generate)
- [sing-box](https://github.com/SagerNet/sing-box/releases)
- [luci-theme-footstrap](https://github.com/VizzleTF/luci-theme-footstrap)
