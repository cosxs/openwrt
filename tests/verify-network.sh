#!/usr/bin/env bash
# Test factory network generation with an extracted OpenWrt rootfs and its
# real board_detect, config_generate, UCI and odhcpd defaults. /sys fixtures
# represent physical ports, including unplugged ones, and virtual interfaces
# that must be ignored.
# Usage, as root on x86-64 Linux: tests/verify-network.sh extracted-rootfs
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh" "$@"

# A new root named $1 whose /sys shows the physical ports $2...
with_ports() {
    new_root "$1"
    shift
    mkdir -p "$root/proc/sys/net/ipv6"
    printf 'generic\n' > "$root/tmp/sysinfo/board_name"
    printf 'Network test fixture\n' > "$root/tmp/sysinfo/model"
    for port in "$@"; do physical_port "$port"; done
    # An ethN virtual device, bridge, loopback, VLAN and wireless device
    # must not turn the single-port case into a multi-port router.
    mkdir -p "$root/sys/class/net/eth99" "$root/sys/class/net/br-test" "$root/sys/class/net/lo"
    printf '1\n' > "$root/sys/class/net/eth99/type"
    physical_port eth0.10
    physical_port wlan0
}

generate() {
    chroot "$root" /bin/board_detect
    chroot "$root" /bin/config_generate > /dev/null
    # uci-defaults are sourced inside a function during boot.
    chroot "$root" /bin/sh -c 'apply_default() { . /etc/uci-defaults/15_odhcpd; }; apply_default' > /dev/null
}

with_ports single eth0
generate
expect network.lan.proto dhcp
expect network.lan.device br-lan
expect 'network.@device[0].ports' eth0
expect network.lan.ipaddr ''
expect network.lan.gateway ''
expect network.lan.dns ''
expect network.wan ''
expect network.wan6 ''
expect network.lan6.proto dhcpv6
expect dhcp.lan.dhcpv4 disabled
expect dhcp.lan.dhcpv6 disabled
expect dhcp.lan.ra disabled
echo 'PASS: single physical port uses upstream DHCP without a static address, WAN or DHCP/RA servers'

for ports in 'eth0 eth1' 'eth0 eth1 eth2 eth3' 'eth10 eth0 eth2'; do
    read -ra names <<< "$ports"
    with_ports "multi-${names[*]// /-}" "${names[@]}"
    generate
    expected=$(printf '%s\n' "${names[@]}" | grep -vx eth0 | sort -V | xargs)
    expect network.wan.device eth0
    expect network.wan.proto dhcp
    expect network.wan6.proto dhcpv6
    expect network.lan.proto static
    expect network.lan.device br-lan
    expect 'network.@device[0].name' br-lan
    expect 'network.@device[0].ports' "$expected"
    expect network.lan.ipaddr 192.168.72.1/24
    expect dhcp.lan.dhcpv4 server
    expect dhcp.lan.dhcpv6 server
    expect dhcp.lan.ra server
    echo "PASS: physical ports [$ports], including unplugged ports, produce WAN eth0 and LAN [$expected]"
done

# Re-running initialization must keep changes to both network and DHCP,
# including a user's non-default WAN port, address and server settings.
chroot "$root" /sbin/uci set network.wan.device=eth2
chroot "$root" /sbin/uci set network.lan.ipaddr=10.77.0.1/24
chroot "$root" /sbin/uci set dhcp.lan.dhcpv4=disabled
chroot "$root" /sbin/uci set dhcp.lan.ra=disabled
chroot "$root" /sbin/uci commit
cp "$root/etc/config/network" "$work/network.kept"
cp "$root/etc/config/dhcp" "$work/dhcp.kept"
physical_port eth3
rm "$root/etc/board.json"
generate
cmp "$work/network.kept" "$root/etc/config/network"
cmp "$work/dhcp.kept" "$root/etc/config/dhcp"
echo 'PASS: restored settings are unchanged even when board detection runs again with another port'

# Kept: a board upstream 02_network already describes, and one without eth0.
for ports in 'eth0 eth1' '' eth1; do
    read -ra names <<< "$ports"
    with_ports "upstream-${#names[@]}-${names[0]:-none}" "${names[@]}"
    printf '%s\n' '{"network":{"lan":{"device":"special0","protocol":"static"}},"model":{"name":"Keep me"}}' > "$root/etc/board.json"
    cp "$root/etc/board.json" "$work/board.kept"
    chroot "$root" /bin/sh -c 'CFG=/etc/board.json /bin/sh /etc/board.d/03-network-defaults'
    cmp "$work/board.kept" "$root/etc/board.json"
    echo "PASS: an existing upstream board description is retained (ports [$ports])"
done

echo 'Network configuration tests passed'
