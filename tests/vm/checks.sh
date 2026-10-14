#!/usr/bin/env bash
# First-boot checks of the running firmware, driven from the LAN client.
# Failed checks are recorded in $VM_WORK/failures.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
wait_for_router "${1:-1200}" || exit 1

echo "== LAN 客户端"
lan ip -4 -o addr show veth-c | awk '{print "client address:", $4}'
lan ip route show default | sed 's/^/client route: /'

echo "== 系统"
vm 'grep DISTRIB_DESCRIPTION /etc/openwrt_release; uname -r; [ -d /sys/firmware/efi ] && echo boot=UEFI; cut -d" " -f1 /proc/uptime'
check hostname linuxserver "$(vm 'uci -q get system.@system[0].hostname')"
check zonename Asia/Shanghai "$(vm 'uci -q get system.@system[0].zonename')"
check timezone CST-8 "$(vm 'uci -q get system.@system[0].timezone')"
check 'date +%Z' CST "$(vm 'date +%Z')"
check 'pending uci-defaults' '' "$(vm 'ls /etc/uci-defaults' | xargs)"
check 'model from the DMI board fields' 'Example Boards EB-4L|example-boards-eb-4l' \
    "$(vm 'ubus call system board | jsonfilter -e @.model -e @.board_name' | paste -sd '|')"
check 'boot/system partition KiB' '65536 4194304' "$(vm "awk '\$4 == \"nvme0n1p1\" || \$4 == \"nvme0n1p2\" {print \$3}' /proc/partitions" | xargs)"
check 'boot partition free KiB > 50000' yes "$(vm "df -k /boot | awk 'NR == 2 {print (\$4 > 50000 ? \"yes\" : \"no\")}'")"

echo "== 网口"
check 'eth0..eth3 MAC' '52:54:00:00:00:10 52:54:00:00:00:11 52:54:00:00:00:12 52:54:00:00:00:13' \
    "$(vm 'for i in 0 1 2 3; do cat /sys/class/net/eth$i/address; done' | xargs)"
check 'br-lan ports' 'eth1 eth2 eth3' "$(vm 'ls /sys/class/net/br-lan/brif' | xargs)"
check 'LAN address' 192.168.72.1/24 "$(vm 'ip -4 -o addr show br-lan' | awk '{print $4}')"
vm 'ip -4 -o addr show eth0 | cut -d" " -f2,7; ip route show default'

echo "== 加速与调优"
check congestion bbr "$(vm 'sysctl -n net.ipv4.tcp_congestion_control')"
check rmem_max 23298048 "$(vm 'sysctl -n net.core.rmem_max')"
check tcp_rmem '4096 131072 23298048' "$(vm 'sysctl -n net.ipv4.tcp_rmem' | xargs)"
check tcp_wmem '4096 16384 23298048' "$(vm 'sysctl -n net.ipv4.tcp_wmem' | xargs)"
check tcp_slow_start_after_idle 0 "$(vm 'sysctl -n net.ipv4.tcp_slow_start_after_idle')"
check tcp_mtu_probing 1 "$(vm 'sysctl -n net.ipv4.tcp_mtu_probing')"
check tcp_notsent_lowat 4096 "$(vm 'sysctl -n net.ipv4.tcp_notsent_lowat')"
check netdev_max_backlog 4000 "$(vm 'sysctl -n net.core.netdev_max_backlog')"
check flow_offloading 1 "$(vm 'uci -q get firewall.@defaults[0].flow_offloading')"
vm 'nft list flowtables 2>&1 | grep -E "flowtable|devices" | sed "s/^[[:space:]]*//"'
vm 'sysctl net.bridge.bridge-nf-call-iptables 2>&1'

echo "== 应用默认状态"
check 'nikki enabled' 0 "$(vm 'uci -q get nikki.config.enabled')"
check 'sing-box enabled' 0 "$(vm 'uci -q get sing-box.main.enabled')"
check 'sing-box running' no "$(vm 'pidof sing-box > /dev/null && echo yes || echo no')"
check 'DDNS sections' 'global=ddns' "$(vm "uci show ddns | sed -n 's/^ddns\.\([^.]*=[^.]*\)$/\1/p'" | xargs)"
check 'port 8080 listening' no "$(vm 'netstat -ltn 2> /dev/null | grep -q ":8080 " && echo yes || echo no')"
vm 'ls /usr/share/luci/menu.d/ | grep -E "nikki|dockerman|ddns" | xargs'

echo "== 网页管理与初始密码"
check 'LuCI login page (unauthenticated)' 403 "$(lan curl -s -o /dev/null -m 30 -w '%{http_code}' http://192.168.72.1/cgi-bin/luci/)"
check 'LuCI login with initial password' 302 "$(lan curl -s -o /dev/null -m 60 -w '%{http_code}' \
    --data-urlencode luci_username=root --data-urlencode "luci_password=$SSHPASS" http://192.168.72.1/cgi-bin/luci/)"
check 'LuCI themes' 'Argon Bootstrap BootstrapDark BootstrapLight' \
    "$(vm "uci show luci.themes | sed -n 's/^luci\.themes\.\([^=]*\)=.*/\1/p'" | xargs)"
check 'LuCI theme' /luci-static/argon "$(vm 'uci -q get luci.main.mediaurlbase')"
check 'overview page uses Argon' yes "$(lan sh -c 'c=$(mktemp); curl -s -m 60 -c "$c" -o /dev/null \
    --data-urlencode luci_username=root --data-urlencode "luci_password=$SSHPASS" http://192.168.72.1/cgi-bin/luci/
    curl -s -m 120 -b "$c" http://192.168.72.1/cgi-bin/luci/admin/status/overview | grep -q /luci-static/argon/ && echo yes || echo no
    rm -f "$c"')"

echo "== WAN 侧管理（WAN 网段 10.0.2.0/24，来源 10.0.2.2，经 QEMU 端口转发）"
wan_luci() { curl -s -o /dev/null -m 20 -w '%{http_code}' http://127.0.0.1:8081/cgi-bin/luci/; }
wan_set() { vm 'nft list set inet fw4 wan_admin_subnet | grep -oE "[0-9.]+/[0-9]+" | xargs'; }
vm 'nft list chain inet fw4 input_wan | grep Allow-Admin | sed "s/^[[:space:]]*//"'
check 'WAN admin rule nft lines' 1 "$(vm 'nft list chain inet fw4 input_wan | grep -c Allow-Admin')"
check 'WAN admin rule has no IPv6 part' 0 "$(vm 'nft list chain inet fw4 input_wan | grep Allow-Admin | grep -c ip6')"
check 'WAN admin set after boot' 10.0.2.0/24 "$(wan_set)"
check 'SSH from WAN side' ok "$(sshpass -e ssh -n -q -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 root@127.0.0.1 'echo ok' 2> /dev/null)"
check 'LuCI from WAN side' 403 "$(wan_luci)"
# Empty the set as a public WAN address would, then let the real hotplug
# script restore it through the system hotplug path.
vm 'printf "#\n" > /etc/wan-admin-subnet && fw4 -q reload-sets'
check 'WAN admin set emptied' '' "$(wan_set)"
check 'LuCI from WAN side with empty set' 000 "$(wan_luci)"
vm 'ACTION=ifupdate INTERFACE=wan /sbin/hotplug-call iface'
check 'WAN admin set restored by hotplug' 10.0.2.0/24 "$(wan_set)"
check 'LuCI from WAN side after hotplug' 403 "$(wan_luci)"

echo "== 数据分区与 Docker"
vm 'grep " /data " /proc/mounts; df -h /data | tail -1'
check 'data mount fstype' ext4 "$(vm "awk '\$2 == \"/data\" {print \$3}' /proc/mounts")"
# The disk was only written with the image; the firmware made the partition.
check 'data partition made on first boot' 'data data ext4' "$(vm 'lsblk -no PARTLABEL,LABEL,FSTYPE /dev/nvme0n1p3' | xargs)"
check 'data partition name in the partition table' data "$(vm 'blkid -p -o value -s PART_ENTRY_NAME /dev/nvme0n1p3')"
check 'data partition ends where the swap partition starts' yes "$(vm 'd=/sys/class/block/nvme0n1p3; s=/sys/class/block/nvme0n1p4; [ $(($(cat $s/start) - $(cat $d/start) - $(cat $d/size))) -ge 0 ] && [ $(($(cat $s/start) - $(cat $d/start) - $(cat $d/size))) -lt 4096 ] && echo yes || echo no')"
check 'swap partition made on first boot' 'swap swap swap' "$(vm 'lsblk -no PARTLABEL,LABEL,FSTYPE /dev/nvme0n1p4' | xargs)"
check 'swap partition name in the partition table' swap "$(vm 'blkid -p -o value -s PART_ENTRY_NAME /dev/nvme0n1p4')"
check 'swap partition reaches the end of the disk' yes "$(vm 'p=/sys/class/block/nvme0n1p4; [ $(($(cat $p/start) + $(cat $p/size))) -gt $(($(cat /sys/class/block/nvme0n1/size) - 4096)) ] && echo yes || echo no')"
check 'swap partition is 1 GiB' yes "$(vm 'sz=$(cat /sys/class/block/nvme0n1p4/size); [ $sz -ge 2097152 ] && [ $sz -lt 2101248 ] && echo yes || echo no')"
check 'fstab swap section' 'swap 1' "$(vm 'echo $(uci -q get fstab.@swap[0].label) $(uci -q get fstab.@swap[0].enabled)')"
check 'swap in use' '/dev/nvme0n1p4 partition' "$(vm "awk 'NR == 2 {print \$1, \$2}' /proc/swaps")"
check 'swap size over 1000000 KiB' yes "$(vm "awk 'NR == 2 {print (\$3 > 1000000 ? \"yes\" : \"no\")}' /proc/swaps")"
check 'only one swap area' 1 "$(vm 'tail -n +2 /proc/swaps | wc -l')"
vm 'free -m | sed -n 1,3p'
vm 'dmesg | grep data-partition'
check 'docker root/driver' '/data/docker overlayfs' "$(vm 'docker info --format "{{.DockerRootDir}} {{.Driver}}"' | sed 's|/ | |')"
check 'data mount shared' yes "$(vm 'grep " /data " /proc/self/mountinfo | grep -q " shared:" && echo yes || echo no')"
check 'separate mount for the Docker data root' 0 "$(vm 'grep -c " /data/docker " /proc/mounts')"
vm 'docker version --format "docker server {{.Server.Version}}"; docker compose version'
vm 'uci show firewall | grep -E "docker" | head -8; uci show network.docker 2>/dev/null | head -4'

echo "== DNS 上游"
check 'dnsmasq noresolv' 1 "$(vm 'uci -q get dhcp.@dnsmasq[0].noresolv')"
check 'dnsmasq upstream servers' '223.5.5.5 119.29.29.29' "$(vm 'uci -q get dhcp.@dnsmasq[0].server')"
check 'dnsmasq running config ignores the WAN servers' 1 "$(vm 'grep -c "^no-resolv$" /var/etc/dnsmasq.conf.*')"
check 'dnsmasq running config servers' '119.29.29.29 223.5.5.5' "$(vm "sed -n 's/^server=//p' /var/etc/dnsmasq.conf.* | sort | xargs")"

echo "== 局域网转发（Docker 已在运行）"
# Ask the router directly: the host's resolver may answer getaddrinfo itself.
check 'router DNS for the LAN' ok "$(lan sh -c 'busybox nslookup www.cloudflare.com 192.168.72.1 > /dev/null 2>&1 && echo ok || echo fail')"
check 'LAN client HTTPS' 200 "$(lan curl -sS -o /dev/null -m 30 -w '%{http_code}' https://www.cloudflare.com/cdn-cgi/trace)"
lan curl -sS -o /dev/null -m 120 -w 'LAN client download: %{size_download} bytes, %{speed_download} B/s\n' \
    https://speed.cloudflare.com/__down?bytes=20000000
vm 'echo "offloaded conntrack entries: $(grep -c OFFLOAD /proc/net/nf_conntrack 2>/dev/null)"'
vm 'iptables -S FORWARD 2>&1 | head -3; nft list tables | xargs'

echo "== 容器联网与 Compose"
vm 'docker pull -q alpine:3 2>&1 | tail -1'
check 'container HTTPS' ok "$(vm 'docker run --rm alpine:3 sh -c "wget -q -T 20 -O /dev/null https://www.cloudflare.com/cdn-cgi/trace && echo ok || echo fail"' 2>&1 | tail -1)"
check 'compose up' compose-ok "$(vm 'mkdir -p /tmp/ct && cd /tmp/ct && printf "services:\n  t:\n    image: alpine:3\n    command: [\"echo\", \"compose-ok\"]\n" > compose.yaml && docker compose up 2>&1 | grep -o compose-ok | head -1; docker compose down > /dev/null 2>&1')"
check 'forwardings' 'docker>wan lan>docker lan>wan' "$(vm 'for s in $(uci show firewall | sed -n "s/^firewall\.\([^.=]*\)=forwarding$/\1/p"); do echo "$(uci get firewall.$s.src)>$(uci get firewall.$s.dest)"; done | sort | xargs')"
check 'docker zones' 1 "$(vm "uci show firewall | grep -c \"\.name='docker'\$\"")"
check 'DOCKER-USER rejects only new WAN connections' 1 "$(vm 'iptables -S DOCKER-USER 2> /dev/null | grep -c -- "-i eth0 -o docker0 -m conntrack ! --ctstate RELATED,ESTABLISHED -j REJECT"')"
check 'docker0 device sections' 1 "$(vm "uci show network | grep -c \"\.name='docker0'\$\"")"
vm 'docker rm -f web > /dev/null 2>&1; docker run -d --name web -p 8088:8080 busybox:stable httpd -f -p 8080 -h /etc > /dev/null 2>&1 && sleep 5'
check 'LAN to published container port' ok "$(lan sh -c 'curl -sf -m 15 http://192.168.72.1:8088/hostname > /dev/null && echo ok || echo fail')"
vm 'docker rm -f web > /dev/null 2>&1'
check 'dockerd conntrack cleanup warnings' 0 "$(vm 'logread | grep -c "Failed to delete conntrack state"')"
check 'LAN client HTTPS after containers' 200 "$(lan curl -sS -o /dev/null -m 30 -w '%{http_code}' https://www.cloudflare.com/cdn-cgi/trace)"

echo "== 日志中的错误"
vm 'logread | grep -iE "error|fail|segfault|oops" | tail -25'
vm 'dmesg | grep -iE "error|fail|oops|call trace" | tail -10'
exit 0
