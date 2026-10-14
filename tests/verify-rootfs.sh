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
    etc/uci-defaults/96-data-partition lib/upgrade/common.sh \
    lib/preinit/01_sysinfo lib/preinit/01_sysinfo_dmi_default \
    etc/uci-defaults/94-dockerd-defaults etc/config/dockerd etc/init.d/dockerd-root-shared \
    etc/uci-defaults/95-docker-firewall \
    etc/uci-defaults/97-dnsmasq-upstream etc/uci-defaults/98-swap-mount \
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
assert_equal OpenWrt "$(uci -q get system.@system[0].hostname)" 'hostname'
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
echo 'PASS: factory hostname OpenWrt and Asia/Shanghai; kept system settings are unchanged'

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
assert_equal 'rule|wan|ipv4|tcp|22 80 7681|wan_admin_subnet|ACCEPT|' \
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
uci set firewall.package_include=include
uci set firewall.package_include.type=script
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
        [ "$(uci -q get "fstab.$section.target")" = /data ] && echo "$section"
    done
}
rm -f /etc/config/fstab
(cd /etc/uci-defaults && . ./10-fstab)
[ -f /etc/config/fstab ] || fail 'block-mount did not generate fstab'
apply_data_mount_default
data_section=$(data_mount_sections)
assert_equal 1 "$(echo "$data_section" | grep -c .)" 'number of /data mounts'
assert_equal data "$(uci -q get "fstab.$data_section.label")" 'data mount label'
assert_equal 1 "$(uci -q get "fstab.$data_section.enabled")" 'data mount enabled'
cp /etc/config/fstab "$verify_tmp/data.fstab"
apply_data_mount_default
cmp -s "$verify_tmp/data.fstab" /etc/config/fstab || fail 'repeated data mount default changed fstab'
# Kept settings: /data mounted from another partition by UUID.
uci delete "fstab.$data_section.label"
uci set "fstab.$data_section.uuid=00000000-0000-4000-8000-000000000000"
uci commit fstab
cp /etc/config/fstab "$verify_tmp/user.fstab"
apply_data_mount_default
cmp -s "$verify_tmp/user.fstab" /etc/config/fstab || fail 'kept data mount was changed'
# Kept settings: the data label moved to another mount point in LuCI; no
# second mount of the same partition is added.
uci set "fstab.$data_section.target=/srv"
uci delete "fstab.$data_section.uuid"
uci set "fstab.$data_section.label=data"
uci commit fstab
cp /etc/config/fstab "$verify_tmp/user.fstab"
apply_data_mount_default
cmp -s "$verify_tmp/user.fstab" /etc/config/fstab || fail 'kept data label mount was changed'
echo 'PASS: factory fstab mounts the data label at /data; kept mount settings are unchanged'

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
assert_equal /data/docker/ "$(uci -q get dockerd.globals.data_root)" 'factory Docker data root'
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
echo 'PASS: factory dockerd uses /data/docker and blocks only new WAN connections; kept dockerd settings are unchanged'

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
# 13. Data and swap partitions on a freshly written disk. No disk is touched:
# a fake sysfs describes the boot disk, common.sh only names its partitions,
# and parted, partx, mkfs.ext4, mkswap and blkid are stubs that record their
# calls; partx adds the partitions that mkpart asked for to the fake sysfs.
cp /lib/upgrade/common.sh "$verify_tmp/common.sh"
cat > /lib/upgrade/common.sh <<'STUB'
export_bootdevice() { :; }
export_partdevice() {
    if [ "$2" = 0 ]; then
        eval "$1=\$TEST_DISK"
        return 0
    fi
    for dir in /sys/block/"$TEST_DISK"/"$TEST_DISK"*; do
        [ "$(cat "$dir/partition" 2> /dev/null)" = "$2" ] && { eval "$1=\${dir##*/}"; return 0; }
    done
    return 1
}
STUB
cat > "$verify_tmp/stub/parted" <<'STUB'
#!/bin/sh
echo "parted $*" >> "$CALLS"
[ "$3" = mkpart ] || exit 0
# TEST_MKPART_FAIL names the partition whose mkpart fails.
[ "$TEST_MKPART_FAIL" != "$4" ] || exit 1
number=$(( $(ls "$STATE"/mkpart.* 2> /dev/null | wc -l) + 3 ))
echo "$4 ${6%s}" > "$STATE/mkpart.$number"
STUB
cat > "$verify_tmp/stub/partx" <<'STUB'
#!/bin/sh
echo "partx $*" >> "$CALLS"
for file in "$STATE"/mkpart.*; do
    [ -f "$file" ] || continue
    number=${file##*.}
    read -r name start < "$file"
    case "$TEST_DISK" in nvme*) dev=${TEST_DISK}p$number ;; *) dev=$TEST_DISK$number ;; esac
    mkdir -p "/sys/block/$TEST_DISK/$dev"
    echo "$number" > "/sys/block/$TEST_DISK/$dev/partition"
    echo "$start" > "/sys/block/$TEST_DISK/$dev/start"
    printf 'PARTN=%s\nPARTNAME=%s\n' "$number" "$name" > "/sys/block/$TEST_DISK/$dev/uevent"
    ln -s "/sys/block/$TEST_DISK/$dev" "/sys/class/block/$dev"
done
# Like partx, report an error for the partitions in use.
exit 1
STUB
printf '#!/bin/sh\necho "mkfs.ext4 $*" >> "$CALLS"\n' > "$verify_tmp/stub/mkfs.ext4"
printf '#!/bin/sh\necho "mkswap $*" >> "$CALLS"\n' > "$verify_tmp/stub/mkswap"
cat > "$verify_tmp/stub/blkid" <<'STUB'
#!/bin/sh
# blkid -L LABEL, or blkid -p -o value -s TAG DEVICE.
case "$1 $5" in
    '-L '*) [ -n "$TEST_DATA_LABEL" ] ;;
    '-p PART_ENTRY_NAME') sed -n 's/^PARTNAME=//p' "/sys/class/block/${6#/dev/}/uevent" ;;
    '-p TYPE')
        case "$6" in
            *3) [ -z "$TEST_FS_TYPE" ] || echo "$TEST_FS_TYPE" ;;
            *4) [ -z "$TEST_SWAP_TYPE" ] || echo "$TEST_SWAP_TYPE" ;;
        esac
        ;;
esac
STUB
chmod 755 "$verify_tmp/stub/parted" "$verify_tmp/stub/partx" "$verify_tmp/stub/mkfs.ext4" \
    "$verify_tmp/stub/mkswap" "$verify_tmp/stub/blkid"
# fake_disk DISK SECTORS [NUMBER:START:SIZE:PARTNAME]...
fake_disk() {
    fake_name=$1
    rm -rf /sys/block /sys/class/block
    mkdir -p "/sys/block/$fake_name" /sys/class/block
    echo "$2" > "/sys/block/$fake_name/size"
    shift 2
    for spec in "$@"; do
        IFS=: read -r number start size name <<EOF
$spec
EOF
        case "$fake_name" in nvme*) dev=${fake_name}p$number ;; *) dev=$fake_name$number ;; esac
        mkdir -p "/sys/block/$fake_name/$dev"
        echo "$number" > "/sys/block/$fake_name/$dev/partition"
        echo "$start" > "/sys/block/$fake_name/$dev/start"
        echo "$size" > "/sys/block/$fake_name/$dev/size"
        printf 'PARTN=%s\nPARTNAME=%s\n' "$number" "$name" > "/sys/block/$fake_name/$dev/uevent"
        ln -s "/sys/block/$fake_name/$dev" "/sys/class/block/$dev"
    done
}
# data_partition DISK [DATA_LABEL_ELSEWHERE] [FS_TYPE_OF_PARTITION_3] [MKPART_FAILS_FOR_NAME] [TYPE_OF_PARTITION_4]
data_partition() {
    : > "$verify_tmp/disk.calls"
    rm -f "$verify_tmp"/mkpart.*
    (
        export PATH="$verify_tmp/stub:$PATH" CALLS="$verify_tmp/disk.calls" STATE="$verify_tmp" \
            TEST_DISK="$1" TEST_DATA_LABEL="${2:-}" TEST_FS_TYPE="${3:-}" TEST_MKPART_FAIL="${4:-}" \
            TEST_SWAP_TYPE="${5:-}"
        cd /etc/uci-defaults && . ./96-data-partition
    )
}
disk_calls() {
    cat "$verify_tmp/disk.calls"
}
image_partitions='128:34:478: 1:512:131072: 2:131584:8388608:'
disk_16g=33554432
# shellcheck disable=SC2086 # the partition list is split on purpose
{
    fake_disk nvme0n1 $disk_16g $image_partitions
    data_partition nvme0n1 || fail 'partitions on a fresh NVMe disk failed'
    assert_equal "parted -s -f /dev/nvme0n1 print
parted -s /dev/nvme0n1 mkpart data ext4 8521728s 31455231s
parted -s /dev/nvme0n1 mkpart swap linux-swap 31455232s 100%
partx -a /dev/nvme0n1
mkswap -L swap /dev/nvme0n1p4
mkfs.ext4 -q -F -L data /dev/nvme0n1p3" "$(disk_calls)" 'commands on a fresh NVMe disk'
    fake_disk sda $disk_16g $image_partitions
    data_partition sda || fail 'partitions on a fresh SATA disk failed'
    assert_equal 'mkswap -L swap /dev/sda4
mkfs.ext4 -q -F -L data /dev/sda3' "$(disk_calls | tail -2)" 'formatted partitions on a SATA disk'
    # Exactly 2 GiB free: 1 GiB of data, then the swap partition.
    fake_disk nvme0n1 $((8521728 + 34 + 4194304)) $image_partitions
    data_partition nvme0n1 || fail 'partitions on a disk with 2 GiB free failed'
    assert_equal "parted -s /dev/nvme0n1 mkpart data ext4 8521728s 10618879s
parted -s /dev/nvme0n1 mkpart swap linux-swap 10618880s 100%" "$(disk_calls | sed -n 2,3p)" 'commands with 2 GiB free'
    # Between 1 and 2 GiB free: only the data partition, over all of it.
    fake_disk nvme0n1 $((8521728 + 34 + 3145728)) $image_partitions
    data_partition nvme0n1 || fail 'data partition on a disk with 1.5 GiB free failed'
    assert_equal "parted -s -f /dev/nvme0n1 print
parted -s /dev/nvme0n1 mkpart data ext4 8521728s 100%
partx -a /dev/nvme0n1
mkfs.ext4 -q -F -L data /dev/nvme0n1p3" "$(disk_calls)" 'commands with 1.5 GiB free'
    fake_disk nvme0n1 $disk_16g $image_partitions
    data_partition nvme0n1 yes
    assert_equal '' "$(disk_calls)" 'commands with a data filesystem on any disk'
    fake_disk nvme0n1 $disk_16g $image_partitions 3:8521728:1000000:mine
    data_partition nvme0n1
    assert_equal '' "$(disk_calls)" 'commands with another partition on the boot disk'
    # Interrupted first boots.
    fake_disk nvme0n1 $disk_16g $image_partitions 3:8521728:22933504:data
    data_partition nvme0n1
    assert_equal 'mkfs.ext4 -q -F -L data /dev/nvme0n1p3' "$(disk_calls)" 'commands after an interrupted first boot with data only'
    fake_disk nvme0n1 $disk_16g $image_partitions 3:8521728:22933504:data 4:31455232:2099167:swap
    data_partition nvme0n1
    assert_equal 'mkswap -L swap /dev/nvme0n1p4
mkfs.ext4 -q -F -L data /dev/nvme0n1p3' "$(disk_calls)" 'commands after an interrupted first boot with both'
    data_partition nvme0n1 '' '' '' swap
    assert_equal 'mkfs.ext4 -q -F -L data /dev/nvme0n1p3' "$(disk_calls)" 'commands with swap made and data not formatted'
    fake_disk nvme0n1 $disk_16g $image_partitions 3:8521728:22933504:data 4:31455232:2099167:mine
    data_partition nvme0n1
    assert_equal 'mkfs.ext4 -q -F -L data /dev/nvme0n1p3' "$(disk_calls)" 'commands with another partition 4'
    data_partition nvme0n1 '' ext4
    assert_equal '' "$(disk_calls)" 'commands with a filesystem on the data partition'
    fake_disk nvme0n1 $((8521728 + 34 + 2097151)) $image_partitions
    data_partition nvme0n1
    assert_equal '' "$(disk_calls)" 'commands with less than 1 GiB free'
    fake_disk nvme0n1 $disk_16g $image_partitions
    if data_partition nvme0n1 '' '' data; then
        fail 'partitions succeeded although the data mkpart failed'
    fi
    assert_equal "parted -s -f /dev/nvme0n1 print
parted -s /dev/nvme0n1 mkpart data ext4 8521728s 31455231s" "$(disk_calls)" 'commands after a failed data mkpart'
    # A failed swap mkpart stops before anything is formatted; the next boot
    # finds the unformatted data partition and formats it.
    fake_disk nvme0n1 $disk_16g $image_partitions
    if data_partition nvme0n1 '' '' swap; then
        fail 'partitions succeeded although the swap mkpart failed'
    fi
    assert_equal '' "$(disk_calls | grep -E 'mkfs|mkswap' || :)" 'formatting after a failed swap mkpart'
}
rm -rf /sys/block /sys/class/block
cp "$verify_tmp/common.sh" /lib/upgrade/common.sh
echo 'PASS: a freshly written boot disk gets an ext4 data partition and, with room, a 1 GiB swap partition at the end; existing data and other partitions are never touched'
# 14. Model name from DMI. The sysinfo preinit files are sourced in glob order
# and their hooks run in that order, as /etc/preinit does, without set -e and
# against a fake DMI directory.
cp -a /tmp/sysinfo "$verify_tmp/sysinfo"
# sysinfo_model SYS_VENDOR PRODUCT_NAME BOARD_VENDOR BOARD_NAME
sysinfo_model() {
    rm -rf /sys/devices/virtual/dmi/id /tmp/sysinfo
    mkdir -p /sys/devices/virtual/dmi/id
    printf '%s\n' "$1" > /sys/devices/virtual/dmi/id/sys_vendor
    printf '%s\n' "$2" > /sys/devices/virtual/dmi/id/product_name
    printf '%s\n' "$3" > /sys/devices/virtual/dmi/id/board_vendor
    printf '%s\n' "$4" > /sys/devices/virtual/dmi/id/board_name
    (
        set +e
        hooks=''
        boot_hook_add() { hooks="$hooks $2"; }
        for file in /lib/preinit/*sysinfo*; do
            . "$file"
        done
        for hook in $hooks; do
            "$hook"
        done
    )
    echo "$(cat /tmp/sysinfo/model)|$(cat /tmp/sysinfo/board_name)"
}
assert_equal 'Example Boards Co.,Ltd. EB-4L|example-boards-co-ltd-eb-4l' \
    "$(sysinfo_model Default Default 'Example Boards Co.,Ltd.' EB-4L)" 'model with Default system fields'
assert_equal 'Example PCs EB-4L|example-pcs-eb-4l' \
    "$(sysinfo_model 'Example PCs' Default 'Example Boards' EB-4L)" 'model with a Default product name'
assert_equal 'Example PCs Mini 4L|example-pcs-mini-4l' \
    "$(sysinfo_model 'Example PCs' 'Mini 4L' 'Example Boards' EB-4L)" 'model with real system fields'
assert_equal 'Example Boards EB-4L|example-boards-eb-4l' \
    "$(sysinfo_model 'Default string' 'Default string' 'Example Boards' EB-4L)" 'model with placeholders known to 01_sysinfo'
assert_equal 'Default Default|default-default' \
    "$(sysinfo_model Default Default 'Default string' 'Default string')" 'model with placeholder board fields'
rm -rf /sys/devices /tmp/sysinfo
cp -a "$verify_tmp/sysinfo" /tmp/sysinfo
echo 'PASS: a bare Default in the DMI system fields falls back to the board vendor and name; other names are kept'
# 15. Shared mount for the Docker data root before dockerd starts. df and mount
# are stubs that record their calls; df reports TEST_MOUNT as the mount point.
cat > "$verify_tmp/stub/df" <<'STUB'
#!/bin/sh
echo "df $*" >> "$CALLS"
printf 'Filesystem 1024-blocks Used Available Capacity Mounted on\n'
printf '/dev/test 1000 0 1000 0%% %s\n' "$TEST_MOUNT"
STUB
printf '#!/bin/sh\necho "mount $*" >> "$CALLS"\n' > "$verify_tmp/stub/mount"
chmod 755 "$verify_tmp/stub/df" "$verify_tmp/stub/mount"
cp /etc/config/dockerd "$verify_tmp/shared.dockerd"
# root_shared DATA_ROOT MOUNT_POINT; an empty DATA_ROOT removes the option.
root_shared() {
    if [ -n "$1" ]; then
        uci set dockerd.globals.data_root="$1"
    else
        uci -q delete dockerd.globals.data_root || :
    fi
    uci commit dockerd
    : > "$verify_tmp/mount.calls"
    (
        export PATH="$verify_tmp/stub:$PATH" CALLS="$verify_tmp/mount.calls" TEST_MOUNT="$2"
        /etc/rc.common /etc/init.d/dockerd-root-shared start
    ) || fail 'dockerd root propagation failed'
    cat "$verify_tmp/mount.calls"
}
mkdir -p /mnt/verify-data /mnt/verify-root
assert_equal 'df -P /mnt/verify-data
mount --make-shared /mnt/verify-data' "$(root_shared /mnt/verify-data/docker/ /mnt/verify-data)" \
    'commands before dockerd created its data root'
mkdir -p /mnt/verify-data/docker
assert_equal 'df -P /mnt/verify-data/docker/
mount --make-shared /mnt/verify-data' "$(root_shared /mnt/verify-data/docker/ /mnt/verify-data)" \
    'commands with an existing data root'
assert_equal 'df -P /mnt/verify-root' "$(root_shared /mnt/verify-root/docker/ /)" \
    'commands with the data root on the root file system'
assert_equal '' "$(root_shared '' /mnt/verify-data)" 'commands without a data root'
assert_equal '' "$(root_shared docker /mnt/verify-data)" 'commands with a relative data root'
rm -rf /mnt/verify-data /mnt/verify-root
cp "$verify_tmp/shared.dockerd" /etc/config/dockerd
echo 'PASS: the mount holding the Docker data root is made shared before dockerd starts; the root file system is left alone'
# 16. Factory dnsmasq upstream. The shipped dhcp config is put back first, as
# config_generate changed the working one in the steps before.
apply_dnsmasq_upstream() {
    (cd /etc/uci-defaults && . ./97-dnsmasq-upstream) || fail 'dnsmasq upstream default failed'
}
cp "$verify_tmp/dhcp" /etc/config/dhcp
assert_equal '' "$(uci -q get dhcp.@dnsmasq[0].server)" 'shipped dnsmasq servers'
assert_equal '' "$(uci -q get dhcp.@dnsmasq[0].noresolv)" 'shipped noresolv'
apply_dnsmasq_upstream
assert_equal 1 "$(uci -q get dhcp.@dnsmasq[0].noresolv)" 'factory noresolv'
assert_equal '223.5.5.5 119.29.29.29' "$(uci -q get dhcp.@dnsmasq[0].server)" 'factory dnsmasq servers'
cp /etc/config/dhcp "$verify_tmp/data.dhcp"
apply_dnsmasq_upstream
cmp -s "$verify_tmp/data.dhcp" /etc/config/dhcp || fail 'repeated dnsmasq upstream default changed dhcp'
# Kept settings: a server list of its own.
cp "$verify_tmp/dhcp" /etc/config/dhcp
uci add_list dhcp.@dnsmasq[0].server='192.0.2.53'
uci commit dhcp
cp /etc/config/dhcp "$verify_tmp/user.dhcp"
apply_dnsmasq_upstream
cmp -s "$verify_tmp/user.dhcp" /etc/config/dhcp || fail 'kept dnsmasq server list was changed'
# Kept settings: the WAN's servers chosen on purpose with noresolv 0.
cp "$verify_tmp/dhcp" /etc/config/dhcp
uci set dhcp.@dnsmasq[0].noresolv='0'
uci commit dhcp
cp /etc/config/dhcp "$verify_tmp/user.dhcp"
apply_dnsmasq_upstream
cmp -s "$verify_tmp/user.dhcp" /etc/config/dhcp || fail 'kept noresolv setting was changed'
cp "$verify_tmp/dhcp" /etc/config/dhcp
echo 'PASS: factory dnsmasq forwards to 223.5.5.5 and 119.29.29.29 and ignores the WAN servers; kept dnsmasq settings are unchanged'

# 17. Swap partition in fstab, after the fstab block-mount generates first.
apply_swap_mount() {
    (cd /etc/uci-defaults && . ./98-swap-mount) || fail 'swap mount default failed'
}
swap_sections() {
    for section in $(uci -q show fstab | sed -n 's/^fstab\.\([^.=]*\)=swap$/\1/p'); do
        echo "$section"
    done
}
rm -f /etc/config/fstab
(cd /etc/uci-defaults && . ./10-fstab)
[ -f /etc/config/fstab ] || fail 'block-mount did not generate fstab'
apply_swap_mount
swap_section=$(swap_sections)
assert_equal 1 "$(echo "$swap_section" | grep -c .)" 'number of swap sections'
assert_equal swap "$(uci -q get "fstab.$swap_section.label")" 'swap label'
assert_equal 1 "$(uci -q get "fstab.$swap_section.enabled")" 'swap enabled'
cp /etc/config/fstab "$verify_tmp/swap.fstab"
apply_swap_mount
cmp -s "$verify_tmp/swap.fstab" /etc/config/fstab || fail 'repeated swap mount default changed fstab'
# Kept settings: the swap section switched off in LuCI stays off.
uci set "fstab.$swap_section.enabled=0"
uci commit fstab
cp /etc/config/fstab "$verify_tmp/user.fstab"
apply_swap_mount
cmp -s "$verify_tmp/user.fstab" /etc/config/fstab || fail 'kept swap section was changed'
echo 'PASS: factory fstab switches on the partition labelled swap; kept swap settings are unchanged'
echo 'PASS: rootfs userspace verification complete (no network activation or hardware boot test)'
INNER
