#!/bin/sh
# Verify a DISPOSABLE extracted OpenWrt rootfs. All mutations run inside chroot.
# Usage inside the Linux/amd64 builder: sh /tmp/verify-root.sh /absolute/rootfs
set -eu

[ "$#" -eq 1 ] || { echo "usage: $0 /absolute/extracted-rootfs" >&2; exit 2; }
case "$1" in
    /*) ;;
    *) echo 'rootfs path must be absolute' >&2; exit 2 ;;
esac
verify_root=$(CDPATH='' cd "$1" && pwd -P) || exit 2
[ "$verify_root" != / ] || { echo 'refusing the host root directory' >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo 'run as root inside the isolated Linux container' >&2; exit 2; }
for verify_file in \
    bin/board_detect bin/config_generate etc/board.d/03-defaults \
    etc/uci-defaults/90-initial-root-password etc/uci-defaults/91-zonename \
    etc/uci-defaults/92-firewall-defaults etc/sysctl.d/90-tcp-tuning.conf etc/shadow \
    etc/uci-defaults/10-fstab etc/uci-defaults/93-data-mount \
    etc/uci-defaults/94-dockerd-defaults etc/config/dockerd \
    etc/uci-defaults/95-docker-firewall \
    etc/hotplug.d/iface/30-wan-admin-subnet etc/wan-admin-subnet \
    lib/functions/network.sh bin/ipcalc.sh \
    etc/uci-defaults/30_luci-theme-argon etc/uci-defaults/30_luci-theme-bootstrap \
    etc/config/luci \
    usr/share/libubox/jshn.sh etc/config/dhcp etc/config/firewall; do
    [ -f "$verify_root/$verify_file" ] || {
        echo "missing rootfs file: $verify_file" >&2
        exit 2
    }
done

chroot "$verify_root" /bin/ash -se <<'INNER'
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
cd /
umask 077

# No host /proc, /sys, /dev or network namespace is mounted into this root.
# config_generate only tests whether this directory exists to add IPv6 defaults.
mkdir -p /tmp/.uci /tmp/sysinfo /proc/sys/net/ipv6 /dev
# Real preinit populates sysinfo before board detection; model that input.
[ -s /tmp/sysinfo/board_name ] || printf "generic\n" > /tmp/sysinfo/board_name
[ -s /tmp/sysinfo/model ] || printf "x86-64 verification fixture\n" > /tmp/sysinfo/model
# board.d reads the network interfaces from sysfs; model a four-port machine.
set_interfaces() {
    rm -rf /sys/class/net
    mkdir -p /sys/class/net
    for name in "$@"; do
        mkdir "/sys/class/net/$name"
    done
}
set_interfaces eth0 eth1 eth2 eth3
# A regular sink suffices for these userspace-only tests if the rootfs has no node.
[ -e /dev/null ] || : > /dev/null
verify_tmp=$(mktemp -d /tmp/rootfs-verify.XXXXXX)
trap 'rm -rf "$verify_tmp"' EXIT

fail() {
    echo "FAIL: $*" >&2
    exit 1
}
assert_equal() {
    [ "$1" = "$2" ] || fail "$3: expected [$1], got [$2]"
}
assert_unchanged_services() {
    cmp -s "$verify_tmp/dhcp" /etc/config/dhcp || fail 'DHCP configuration changed'
    cmp -s "$verify_tmp/firewall" /etc/config/firewall || fail 'firewall configuration changed'
}
lan_ports() {
    for section in $(uci -q show network | sed -n 's/^network\.\([^=]*\)=device$/\1/p'); do
        [ "$(uci -q get "network.$section.name" || :)" != br-lan ] || uci -q get "network.$section.ports"
    done
}
assert_factory_network() {
    assert_equal br-lan "$(uci -q get network.lan.device)" 'LAN device'
    assert_equal static "$(uci -q get network.lan.proto)" 'LAN protocol'
    assert_equal 192.168.72.1/24 "$(uci -q get network.lan.ipaddr)" 'LAN address'
    assert_equal eth0 "$(uci -q get network.wan.device)" 'WAN device'
    assert_equal dhcp "$(uci -q get network.wan.proto)" 'WAN protocol'
    assert_equal eth0 "$(uci -q get network.wan6.device)" 'WAN6 device'
    assert_equal dhcpv6 "$(uci -q get network.wan6.proto)" 'WAN6 protocol'

    bridge_count=0
    bridge_section=
    for section in $(uci -q show network | sed -n 's/^network\.\([^=]*\)=device$/\1/p'); do
        if [ "$(uci -q get "network.$section.name" || :)" = br-lan ]; then
            bridge_count=$((bridge_count + 1))
            bridge_section=$section
        fi
    done
    assert_equal 1 "$bridge_count" 'number of br-lan devices'
    assert_equal bridge "$(uci -q get "network.$bridge_section.type")" 'LAN device type'
    assert_equal 'eth1 eth2 eth3' "$(uci -q get "network.$bridge_section.ports")" 'LAN ports, including absence of WAN and duplicates'
    assert_unchanged_services
}

cp /etc/config/dhcp "$verify_tmp/dhcp"
cp /etc/config/firewall "$verify_tmp/firewall"

# 1. Initial/factory boot, using the shipped board.d files and real generators.
rm -f /etc/board.json /etc/config/network /etc/config/system
/bin/board_detect
/bin/config_generate
assert_factory_network
cp /etc/config/network "$verify_tmp/factory.network"
cp /etc/board.json "$verify_tmp/factory.board"
echo 'PASS: factory LAN eth1/eth2/eth3; WAN and WAN6 eth0; default IP and service configs'

# 2. Repeat the custom hook against populated board data, then regenerate network.
# Merely rerunning config_generate would skip an existing network and hide duplicates.
(
    # Match board_detect: its sourced board hooks do not inherit errexit.
    set +e
    CFG=/etc/board.json
    export CFG
    . /etc/board.d/03-defaults
)
ucode -l fs -e '
let before = json(fs.readfile(ARGV[0]));
let after = json(fs.readfile(ARGV[1]));
if (sprintf("%J", before) != sprintf("%J", after))
    die("reapplying board hook changed board defaults\n");
' "$verify_tmp/factory.board" /etc/board.json || fail 'board defaults differ semantically' 
rm -f /etc/config/network
/bin/config_generate
assert_factory_network
cmp -s "$verify_tmp/factory.network" /etc/config/network || fail 'regeneration changed factory network'
/bin/config_generate
cmp -s "$verify_tmp/factory.network" /etc/config/network || fail 'repeated generator changed saved network'
echo 'PASS: repeated board hook/generator is idempotent with no duplicate LAN ports'

# 3. Model restored user settings before the new firmware generates its board file.
uci set network.lan.ipaddr='192.168.77.1/24'
uci delete "network.$bridge_section.ports"
uci add_list "network.$bridge_section.ports=eth2"
uci add_list "network.$bridge_section.ports=eth3"
uci set network.wan.proto=static
uci set network.wan.ipaddr='198.51.100.2/24'
uci commit network
cp /etc/config/network "$verify_tmp/user.network"
rm -f /etc/board.json
/bin/board_detect
/bin/config_generate
cmp -s "$verify_tmp/user.network" /etc/config/network || fail 'saved user network was overwritten'
assert_unchanged_services
echo 'PASS: restored user IP, LAN membership and WAN settings are preserved byte-for-byte'

# 4. Remove generated network settings; the retained firmware defaults rebuild it.
rm -f /etc/config/network
/bin/config_generate
assert_factory_network
cmp -s "$verify_tmp/factory.network" /etc/config/network || fail 'factory reset simulation did not restore default network'
echo 'PASS: removing network settings restores the factory layout; DHCP/firewall unchanged'

# 4b. Other port counts: eth0 is the WAN and every other ethN, in numeric
# order, a LAN port; a lone eth0 leaves no LAN.
generate_for_interfaces() {
    set_interfaces "$@"
    rm -f /etc/board.json /etc/config/network
    /bin/board_detect
    /bin/config_generate
}
generate_for_interfaces eth0 eth1
assert_equal eth1 "$(lan_ports)" 'LAN ports of a two-port machine'
assert_equal eth0 "$(uci -q get network.wan.device)" 'WAN device of a two-port machine'
generate_for_interfaces eth0 eth1 eth2 eth10 eth3 lo docker0
assert_equal 'eth1 eth2 eth3 eth10' "$(lan_ports)" 'LAN ports of a machine with eth10'
generate_for_interfaces eth0
assert_equal eth0 "$(uci -q get network.wan.device)" 'WAN device of a single-port machine'
assert_equal '' "$(uci -q get network.lan || :)" 'LAN of a single-port machine'
assert_equal '' "$(lan_ports)" 'LAN ports of a single-port machine'
generate_for_interfaces eth0 eth1 eth2 eth3
cmp -s "$verify_tmp/factory.network" /etc/config/network || fail 'four-port layout differs from the factory network'
assert_unchanged_services
echo 'PASS: eth0 is the WAN and every other ethN a LAN port, in numeric order; a single eth0 leaves no LAN'

# 5. Initial root password, applied the way /etc/init.d/boot runs uci-defaults.
root_password_field() {
    sed -n 's/^root:\([^:]*\):.*/\1/p' /etc/shadow
}
apply_root_password_default() {
    (cd /etc/uci-defaults && . ./90-initial-root-password) || fail 'root password default failed'
}
assert_equal '' "$(root_password_field)" 'shipped root password'
cp /etc/shadow "$verify_tmp/factory.shadow"
shadow_mode=$(ls -ln /etc/shadow | cut -d ' ' -f 1)
apply_root_password_default
initial_hash=$(root_password_field)
case "$initial_hash" in
    '$6$'?*) ;;
    *) fail "initial root password is not SHA-512 crypt: [$initial_hash]" ;;
esac
assert_equal "$shadow_mode" "$(ls -ln /etc/shadow | cut -d ' ' -f 1)" 'shadow file mode'
grep -v '^root:' "$verify_tmp/factory.shadow" > "$verify_tmp/factory.others"
grep -v '^root:' /etc/shadow | cmp -s "$verify_tmp/factory.others" - || fail 'other shadow entries changed'
cp /etc/shadow "$verify_tmp/initial.shadow"
apply_root_password_default
cmp -s "$verify_tmp/initial.shadow" /etc/shadow || fail 'repeated root password default changed shadow'
sed -i 's|^root:[^:]*:|root:$6$kept$keptpasswordhash:|' /etc/shadow
cp /etc/shadow "$verify_tmp/user.shadow"
apply_root_password_default
cmp -s "$verify_tmp/user.shadow" /etc/shadow || fail 'kept root password was overwritten'
echo 'PASS: initial root password is set once; kept passwords and other accounts are unchanged'

# 6. Hostname and timezone are generated only with a new system config; the
# uci-defaults step then completes the zone name LuCI shows and writes back.
apply_zonename_default() {
    (cd /etc/uci-defaults && . ./91-zonename) || fail 'zone name default failed'
}
rm -f /etc/board.json /etc/config/system
/bin/board_detect
/bin/config_generate
assert_equal linuxserver "$(uci -q get system.@system[0].hostname)" 'hostname'
assert_equal CST-8 "$(uci -q get system.@system[0].timezone)" 'timezone'
assert_equal UTC "$(uci -q get system.@system[0].zonename)" 'generated zone name'
apply_zonename_default
assert_equal Asia/Shanghai "$(uci -q get system.@system[0].zonename)" 'zone name'
cp /etc/config/system "$verify_tmp/factory.system"
apply_zonename_default
cmp -s "$verify_tmp/factory.system" /etc/config/system || fail 'repeated zone name default changed system'
# Kept settings, including UTC selected in LuCI, which removes the POSIX timezone.
uci set system.@system[0].hostname='kept-host'
uci set system.@system[0].zonename='UTC'
uci delete system.@system[0].timezone
uci commit system
cp /etc/config/system "$verify_tmp/user.system"
rm -f /etc/board.json
/bin/board_detect
/bin/config_generate
apply_zonename_default
cmp -s "$verify_tmp/user.system" /etc/config/system || fail 'kept system settings were changed'
echo 'PASS: factory hostname linuxserver and Asia/Shanghai; kept system settings are unchanged'

# 7. Factory firewall defaults: flow offloading and WAN admin access from the
# WAN's own private subnet (a set filled by hotplug, see step 11). The
# extracted root has no squashfs lower layer, so model /rom with the shipped
# firewall config.
apply_firewall_defaults() {
    (cd /etc/uci-defaults && . ./92-firewall-defaults) || fail 'firewall defaults failed'
}
firewall_without_defaults() {
    uci -q show firewall | grep -v -e '\.flow_offloading=' \
        -e '^firewall\.wan_private_admin[.=]' -e '^firewall\.wan_admin_subnet[.=]'
}
uci_values() {
    for option in "$@"; do printf '%s|' "$(uci -q get "$option")"; done
}
mkdir -p /rom/etc/config
cp "$verify_tmp/firewall" /rom/etc/config/firewall
cp "$verify_tmp/firewall" /etc/config/firewall
assert_equal '' "$(uci -q get firewall.@defaults[0].flow_offloading || :)" 'shipped flow offloading'
assert_equal '' "$(uci -q get firewall.wan_private_admin || :)" 'shipped WAN admin rule'
firewall_without_defaults > "$verify_tmp/firewall.show"
apply_firewall_defaults
assert_equal 1 "$(uci -q get firewall.@defaults[0].flow_offloading)" 'factory flow offloading'
assert_equal 'ipset|wan_admin_subnet|ipv4|src_net|/etc/wan-admin-subnet|' \
    "$(uci_values firewall.wan_admin_subnet firewall.wan_admin_subnet.name \
        firewall.wan_admin_subnet.family firewall.wan_admin_subnet.match \
        firewall.wan_admin_subnet.loadfile)" 'factory WAN admin set'
assert_equal 'rule|wan|ipv4|tcp|22 80|wan_admin_subnet|ACCEPT|' \
    "$(uci_values firewall.wan_private_admin firewall.wan_private_admin.src \
        firewall.wan_private_admin.family firewall.wan_private_admin.proto \
        firewall.wan_private_admin.dest_port firewall.wan_private_admin.ipset \
        firewall.wan_private_admin.target)" 'factory WAN admin rule'
assert_equal '' "$(uci -q get firewall.wan_private_admin.src_ip || :)" 'WAN admin rule fixed sources'
firewall_without_defaults | cmp -s "$verify_tmp/firewall.show" - || fail 'firewall defaults changed other firewall settings'
cp /etc/config/firewall "$verify_tmp/defaults.firewall"
apply_firewall_defaults
cmp -s "$verify_tmp/defaults.firewall" /etc/config/firewall || fail 'repeated firewall defaults changed firewall'
# Kept settings: offloading off and the WAN admin rule removed in LuCI, plus
# a firewall include added by a package.
cp "$verify_tmp/firewall" /etc/config/firewall
uci set firewall.nikki=include
uci set firewall.nikki.type=script
uci commit firewall
cp /etc/config/firewall "$verify_tmp/user.firewall"
apply_firewall_defaults
cmp -s "$verify_tmp/user.firewall" /etc/config/firewall || fail 'kept firewall settings were changed'
echo 'PASS: factory firewall enables flow offloading and WAN admin from the WAN subnet set; kept firewall settings are unchanged'

# 8. Data partition mount point, after the fstab block-mount generates first.
apply_data_mount_default() {
    (cd /etc/uci-defaults && . ./93-data-mount) || fail 'data mount default failed'
}
data_mount_sections() {
    for section in $(uci -q show fstab | sed -n 's/^fstab\.\([^.=]*\)=mount$/\1/p'); do
        [ "$(uci -q get "fstab.$section.target")" = /mnt/data ] && echo "$section"
    done
}
rm -f /etc/config/fstab
(cd /etc/uci-defaults && . ./10-fstab)
[ -f /etc/config/fstab ] || fail 'block-mount did not generate fstab'
apply_data_mount_default
data_section=$(data_mount_sections)
assert_equal 1 "$(echo "$data_section" | grep -c .)" 'number of /mnt/data mounts'
assert_equal data "$(uci -q get "fstab.$data_section.label")" 'data mount label'
assert_equal 1 "$(uci -q get "fstab.$data_section.enabled")" 'data mount enabled'
cp /etc/config/fstab "$verify_tmp/data.fstab"
apply_data_mount_default
cmp -s "$verify_tmp/data.fstab" /etc/config/fstab || fail 'repeated data mount default changed fstab'
# Kept settings: /mnt/data mounted from another partition by UUID.
uci delete "fstab.$data_section.label"
uci set "fstab.$data_section.uuid=00000000-0000-4000-8000-000000000000"
uci commit fstab
cp /etc/config/fstab "$verify_tmp/user.fstab"
apply_data_mount_default
cmp -s "$verify_tmp/user.fstab" /etc/config/fstab || fail 'kept data mount was changed'
echo 'PASS: factory fstab mounts the data label at /mnt/data; kept mount settings are unchanged'

# 9. dockerd data root and WAN blocking rule, with /rom modelled as in step 7.
apply_dockerd_defaults() {
    (cd /etc/uci-defaults && . ./94-dockerd-defaults) || fail 'dockerd defaults failed'
}
mkdir -p /rom/etc/config
cp /etc/config/dockerd "$verify_tmp/dockerd"
cp /etc/config/dockerd /rom/etc/config/dockerd
assert_equal /opt/docker/ "$(uci -q get dockerd.globals.data_root)" 'shipped Docker data root'
assert_equal wan "$(uci -q get dockerd.firewall.blocked_interfaces)" 'shipped blocked interfaces'
apply_dockerd_defaults
assert_equal /mnt/data/docker/ "$(uci -q get dockerd.globals.data_root)" 'factory Docker data root'
assert_equal '--match conntrack ! --ctstate RELATED,ESTABLISHED' \
    "$(uci -q get dockerd.firewall.extra_iptables_args)" 'factory WAN blocking rule arguments'
assert_equal wan "$(uci -q get dockerd.firewall.blocked_interfaces)" 'factory blocked interfaces'
cp /etc/config/dockerd "$verify_tmp/data.dockerd"
apply_dockerd_defaults
cmp -s "$verify_tmp/data.dockerd" /etc/config/dockerd || fail 'repeated dockerd defaults changed dockerd'
cp "$verify_tmp/dockerd" /etc/config/dockerd
uci set dockerd.globals.data_root='/srv/docker/'
uci commit dockerd
cp /etc/config/dockerd "$verify_tmp/user.dockerd"
apply_dockerd_defaults
cmp -s "$verify_tmp/user.dockerd" /etc/config/dockerd || fail 'kept dockerd settings were changed'
echo 'PASS: factory dockerd uses /mnt/data/docker and blocks only new WAN connections; kept dockerd settings are unchanged'

# 10. Docker zone and forwardings, created before dockerd's own uciadd runs.
apply_docker_firewall_default() {
    (cd /etc/uci-defaults && . ./95-docker-firewall) || fail 'Docker firewall default failed'
}
forwardings() {
    for section in $(uci -q show firewall | sed -n 's/^firewall\.\([^.=]*\)=forwarding$/\1/p'); do
        echo "$(uci -q get "firewall.$section.src")>$(uci -q get "firewall.$section.dest")"
    done | sort | xargs
}
cp "$verify_tmp/firewall" /etc/config/firewall
assert_equal '' "$(uci -q get firewall.docker || :)" 'shipped docker zone'
apply_docker_firewall_default
assert_equal docker "$(uci -q get firewall.docker.name)" 'docker zone name'
assert_equal docker "$(uci -q get firewall.docker.network)" 'docker zone network'
assert_equal ACCEPT "$(uci -q get firewall.docker.forward)" 'docker zone forward policy'
assert_equal 'docker>wan lan>docker lan>wan' "$(forwardings)" 'forwardings'
assert_equal docker0 "$(uci -q get network.docker.device)" 'docker interface device'
assert_equal none "$(uci -q get network.docker.proto)" 'docker interface protocol'
docker0_sections=$(uci -q show network | sed -n "s/^network\.\([^.]*\)\.name='docker0'$/\1/p")
assert_equal 1 "$(echo "$docker0_sections" | grep -c .)" 'number of docker0 devices'
assert_equal bridge "$(uci -q get "network.$docker0_sections.type")" 'docker0 device type'
cp /etc/config/firewall "$verify_tmp/docker.firewall"
cp /etc/config/network "$verify_tmp/docker.network"
apply_docker_firewall_default
cmp -s "$verify_tmp/docker.firewall" /etc/config/firewall || fail 'repeated Docker firewall default changed firewall'
cmp -s "$verify_tmp/docker.network" /etc/config/network || fail 'repeated Docker firewall default changed network'
# Kept settings: a docker zone without these forwardings stays as it is.
cp "$verify_tmp/firewall" /etc/config/firewall
uci set firewall.docker=zone
uci set firewall.docker.name='docker'
uci add_list firewall.docker.network='docker'
uci commit firewall
cp /etc/config/firewall "$verify_tmp/user-docker.firewall"
apply_docker_firewall_default
cmp -s "$verify_tmp/user-docker.firewall" /etc/config/firewall || fail 'kept docker zone was changed'
echo 'PASS: factory firewall lets containers reach WAN and LAN reach containers; kept docker zone is unchanged'

# 11. WAN admin subnet hotplug. No netifd or nftables runs in the extracted
# root, so network_get_subnet returns a test address and fw4 records its calls;
# ipcalc.sh and the file handling are the real ones.
cp /lib/functions/network.sh "$verify_tmp/network.sh"
cat > /lib/functions/network.sh <<'STUB'
network_get_subnet() {
    [ -n "$TEST_WAN_CIDR" ] || return 1
    eval "$1=\$TEST_WAN_CIDR"
}
STUB
mkdir -p "$verify_tmp/stub"
printf '#!/bin/sh\necho "$*" >> %s/fw4.calls\n' "$verify_tmp" > "$verify_tmp/stub/fw4"
chmod 755 "$verify_tmp/stub/fw4"
run_wan_hotplug() {
    : > "$verify_tmp/fw4.calls"
    (
        export ACTION="$1" TEST_WAN_CIDR="$2" INTERFACE="${3:-wan}" PATH="$verify_tmp/stub:$PATH"
        cd / && . /etc/hotplug.d/iface/30-wan-admin-subnet
    ) || fail "WAN admin subnet hotplug failed for $*"
}
wan_admin_subnet() {
    grep -v '^#' /etc/wan-admin-subnet | grep . || :
}
assert_equal '' "$(wan_admin_subnet)" 'shipped WAN admin subnet'
run_wan_hotplug ifup 10.10.10.10/24
assert_equal 10.10.10.0/24 "$(wan_admin_subnet)" 'subnet behind a home router'
assert_equal '-q reload-sets' "$(cat "$verify_tmp/fw4.calls")" 'set reload after a change'
run_wan_hotplug ifupdate 10.10.10.10/24
assert_equal '' "$(cat "$verify_tmp/fw4.calls")" 'set reload without a change'
for case in 192.168.31.5/24=192.168.31.0/24 172.20.3.4/16=172.20.0.0/16 \
        10.1.2.3/8=10.0.0.0/8 192.168.1.66/30=192.168.1.64/30 \
        1.2.3.4/22= 100.64.10.2/10= 172.32.0.5/24= 10.0.0.5/32= 192.168.0.2/15=; do
    run_wan_hotplug ifup "${case%%=*}"
    assert_equal "${case#*=}" "$(wan_admin_subnet)" "WAN admin subnet for ${case%%=*}"
done
run_wan_hotplug ifup 10.10.10.10/24
run_wan_hotplug ifup ''
assert_equal '' "$(wan_admin_subnet)" 'WAN without an IPv4 address'
run_wan_hotplug ifup 10.10.10.10/24
run_wan_hotplug ifdown 10.10.10.10/24
assert_equal '' "$(wan_admin_subnet)" 'WAN down'
run_wan_hotplug ifup 10.10.10.10/24
run_wan_hotplug ifup 192.168.72.1/24 lan
assert_equal 10.10.10.0/24 "$(wan_admin_subnet)" 'event of another interface'
assert_equal '' "$(cat "$verify_tmp/fw4.calls")" 'set reload for another interface'
cp "$verify_tmp/network.sh" /lib/functions/network.sh
echo 'PASS: WAN admin set follows a private WAN subnet and stays empty for public, CGNAT, point-to-point or missing addresses'

# 12. LuCI theme. The theme packages' first-boot scripts run in glob order, as
# /etc/init.d/boot runs them: Argon registers first and selects itself, and
# Bootstrap keeps an existing selection. LuCI falls back to the first
# registered theme when the configured one is missing.
apply_theme_scripts() {
    for theme_script in /etc/uci-defaults/30_luci-theme-*; do
        (cd /etc/uci-defaults && . "$theme_script") || fail "$theme_script failed"
    done
}
registered_themes() {
    uci show luci.themes | sed -n "s/^luci\.themes\.\([^=]*\)=.*/\1/p" | xargs
}
[ -d /www/luci-static/argon ] || fail 'Argon theme files missing'
[ -d /www/luci-static/bootstrap ] || fail 'Bootstrap theme files missing'
apply_theme_scripts
assert_equal /luci-static/argon "$(uci -q get luci.main.mediaurlbase)" 'factory LuCI theme'
assert_equal 'Argon Bootstrap BootstrapDark BootstrapLight' "$(registered_themes)" 'registered LuCI themes'
cp /etc/config/luci "$verify_tmp/argon.luci"
apply_theme_scripts
cmp -s "$verify_tmp/argon.luci" /etc/config/luci || fail 'repeated theme scripts changed luci'
# Kept settings: Bootstrap chosen in LuCI stays selected when the theme
# scripts run again after an upgrade.
uci set luci.main.mediaurlbase='/luci-static/bootstrap'
uci commit luci
apply_theme_scripts
assert_equal /luci-static/bootstrap "$(uci -q get luci.main.mediaurlbase)" 'kept Bootstrap theme'
echo 'PASS: Argon is the factory LuCI theme and first fallback with Bootstrap installed; a theme chosen in LuCI is kept'
echo 'PASS: rootfs userspace verification complete (no network activation or hardware boot test)'
INNER
