#!/usr/bin/env bash
# Exercise the system defaults with the extracted image's real preinit hooks,
# board_detect, config_generate, UCI and libc timezone handling, and the
# first-boot password and sing-box defaults. No build.
# Usage, as root on x86-64 Linux: tests/verify-system.sh extracted-rootfs
# shellcheck source-path=SCRIPTDIR source=lib.sh
. "$(dirname "$0")/lib.sh" "$@"

new_root root
physical_port eth0

generate() {
    chroot "$root" /bin/board_detect
    chroot "$root" /bin/config_generate >/dev/null
    chroot "$root" /bin/sh /etc/uci-defaults/15_migrate-time-zonename
    chroot "$root" /bin/sh /etc/uci-defaults/92-zonename
}

generate
expect system.@system[0].timezone CST-8
expect system.@system[0].zonename Asia/Shanghai
[[ $(chroot "$root" /bin/sh -c 'TZ="$(uci -q get system.@system[0].timezone)" date -d @0 "+%Y-%m-%d %H:%M"') == '1970-01-01 08:00' ]]
echo 'PASS: new system has Asia/Shanghai and libc reports UTC+8'

cp "$root/etc/config/system" "$work/system.kept"
chroot "$root" /bin/sh -c 'CFG=/etc/board.json /bin/sh /etc/board.d/04-system-defaults'
chroot "$root" /bin/sh /etc/uci-defaults/92-zonename
cmp "$work/system.kept" "$root/etc/config/system"
echo 'PASS: re-running system defaults is idempotent'

for pair in 'CET-1CEST,M3.5.0,M10.5.0/3 Europe/Berlin' 'GMT0 UTC' 'CST-8 Asia/Taipei'; do
    read -r timezone zonename <<< "$pair"
    chroot "$root" /sbin/uci set "system.@system[0].timezone=$timezone"
    chroot "$root" /sbin/uci set "system.@system[0].zonename=$zonename"
    chroot "$root" /sbin/uci set system.@system[0].hostname=kept-host
    chroot "$root" /sbin/uci commit system
    cp "$root/etc/config/system" "$work/system.kept"
    rm "$root/etc/board.json"
    generate
    cmp "$work/system.kept" "$root/etc/config/system"
    echo "PASS: retained system settings, including $zonename, stay unchanged"
done

cp "$root/etc/config/network" "$work/network.kept"
rm "$root/etc/config/system" "$root/etc/board.json"
generate
expect system.@system[0].timezone CST-8
expect system.@system[0].zonename Asia/Shanghai
cmp "$work/network.kept" "$root/etc/config/network"
echo 'PASS: new system defaults apply independently of retained network settings'

dmi="$root/sys/devices/virtual/dmi/id"
mkdir -p "$dmi"
dmi_case() {
    local label=$1 expected=$6 expected_id=$7 actual actual_id
    printf '%s\n' "$2" > "$dmi/sys_vendor"
    printf '%s\n' "$3" > "$dmi/product_name"
    printf '%s\n' "$4" > "$dmi/board_vendor"
    printf '%s\n' "$5" > "$dmi/board_name"
    rm -f "$root/tmp/sysinfo/model" "$root/tmp/sysinfo/board_name"
    # Use actual hook registration and ordering, not mocked DMI functions.
    chroot "$root" /bin/sh -c '
        . /lib/functions/preinit.sh
        boot_hook_init preinit_main
        . /lib/preinit/01_sysinfo
        . /lib/preinit/01_sysinfo_dmi_default
        boot_run_hook preinit_main
    '
    actual=$(cat "$root/tmp/sysinfo/model" 2>/dev/null || true)
    actual_id=$(cat "$root/tmp/sysinfo/board_name" 2>/dev/null || true)
    [[ $actual == "$expected" && $actual_id == "$expected_id" ]] || {
        echo "FAIL: $label: model [$actual], board [$actual_id]" >&2
        exit 1
    }
    echo "PASS: DMI $label"
}

dmi_case normal 'Example Corp' Router-X Ignored Ignored 'Example Corp Router-X' example-corp-router-x
dmi_case vendor-only Default Router-X 'Board Corp' Ignored 'Board Corp Router-X' board-corp-router-x
dmi_case product-only 'Example Corp' Default Ignored Board-X 'Example Corp Board-X' example-corp-board-x
dmi_case invalid-fallback Default Default 'Default string' 'To be filled by O.E.M.' 'Default Default' default-default
dmi_case missing-fields '' '' '' '' '' ''
dmi_case upstream-placeholder 'Default string' 'System Product Name' 'Board Corp' Board-X 'Board Corp Board-X' board-corp-board-x
dmi_case mixed-placeholder 'Default string' Default 'Board Corp' Board-X 'Board Corp Board-X' board-corp-board-x
dmi_case upstream-special-model 'PC Engines' APU Ignored Ignored 'PC Engines apu1' pc-engines-apu1
dmi_case both-fields Default Default 'Board Corp' Board-X 'Board Corp Board-X' board-corp-board-x

rm "$root/etc/board.json"
generate
model=$(chroot "$root" /usr/bin/jsonfilter -i /etc/board.json -e @.model.id -e @.model.name | xargs)
[[ $model == 'board-corp-board-x Board Corp Board-X' ]] || {
    echo "FAIL: board.json model [$model]" >&2
    exit 1
}
echo 'PASS: corrected DMI model and board id reach generated board metadata'

script=/etc/uci-defaults/90-initial-root-password
shadow="$root/etc/shadow"
grep -q '^root::' "$shadow"
cp "$shadow" "$work/shadow.original"
shadow_mode=$(stat -c '%a:%u:%g' "$shadow")
chroot "$root" /bin/sh "$script"
grep -Eq '^root:[$]6[$]' "$shadow"
# Only the root password field may change; permissions, the other accounts
# and the password-aging fields stay.
sed 's/^root:[^:]*:/root::/' "$shadow" | cmp - "$work/shadow.original"
[[ $(stat -c '%a:%u:%g' "$shadow") == "$shadow_mode" ]]
echo 'PASS: the password default initializes only the empty root password'
cp "$shadow" "$work/shadow.initial"
chroot "$root" /bin/sh "$script"
cmp "$shadow" "$work/shadow.initial"
echo 'PASS: the password default is idempotent'
for password in retained-password-hash '!' '*'; do
    sed "s/^root:[^:]*:/root:$password:/" "$work/shadow.initial" > "$shadow"
    cp "$shadow" "$work/shadow.retained"
    chroot "$root" /bin/sh "$script"
    cmp "$shadow" "$work/shadow.retained"
done
echo 'PASS: the password default preserves existing passwords and account locks'

script=/etc/uci-defaults/91-sing-box-default
expect sing-box.main.enabled 1
# /rom, the shipped state the default compares with, is not mounted here.
mkdir -p "$root/rom/etc/sing-box" "$root/rom/etc/config"
cp "$root/etc/config/sing-box" "$root/rom/etc/config/sing-box"
cp "$root/etc/sing-box/config.json" "$root/rom/etc/sing-box/config.json"
chroot "$root" /bin/sh "$script"
expect sing-box.main.enabled 0
echo 'PASS: sing-box ships enabled and the first-boot default turns it off'
chroot "$root" /sbin/uci set sing-box.main.enabled=1
chroot "$root" /sbin/uci commit sing-box
echo '{}' > "$root/etc/sing-box/config.json"
chroot "$root" /bin/sh "$script"
expect sing-box.main.enabled 1
echo 'PASS: the default leaves a device that has its own sing-box setup alone'

script=/etc/uci-defaults/95-firewall-defaults
firewall="$root/etc/config/firewall"
expect 'firewall.@defaults[0].flow_offloading' ''
expect 'firewall.@defaults[0].syn_flood' 1
expect 'firewall.@defaults[0].synflood_protect' ''
cp "$firewall" "$root/rom/etc/config/firewall"
chroot "$root" /sbin/uci -q show firewall > "$work/firewall.shipped"
chroot "$root" /bin/sh "$script"
expect 'firewall.@defaults[0].flow_offloading' 1
expect 'firewall.@defaults[0].syn_flood' ''
expect 'firewall.@defaults[0].synflood_protect' 0
expect firewall.wan_admin_subnet ipset
expect firewall.wan_admin_subnet.family ipv4
expect firewall.wan_admin_subnet.match src_net
expect firewall.wan_admin_subnet.loadfile /var/run/wan-admin-subnet
expect firewall.wan_admin rule
expect firewall.wan_admin.src wan
expect firewall.wan_admin.family ipv4
expect firewall.wan_admin.proto tcp
expect firewall.wan_admin.dest_port '22 80 7681'
expect firewall.wan_admin.ipset wan_admin_subnet
expect firewall.wan_admin.target ACCEPT
# Nothing else in the firewall configuration changes.
chroot "$root" /sbin/uci -q show firewall |
    grep -v -e '^firewall\.@defaults\[0\]\.flow_offloading=' \
        -e '^firewall\.@defaults\[0\]\.synflood_protect=' \
        -e '^firewall\.wan_admin_subnet[.=]' -e '^firewall\.wan_admin[.=]' |
    cmp - <(grep -v '^firewall\.@defaults\[0\]\.syn_flood=' "$work/firewall.shipped")
echo 'PASS: the firewall default sets offloading, the SYN limit and the WAN admin rule'
cp "$firewall" "$work/firewall.initial"
chroot "$root" /bin/sh "$script"
cmp "$firewall" "$work/firewall.initial"
echo 'PASS: the firewall default is idempotent'
chroot "$root" /sbin/uci set 'firewall.@defaults[0].flow_offloading=0'
chroot "$root" /sbin/uci set 'firewall.@defaults[0].synflood_protect=1'
chroot "$root" /sbin/uci commit firewall
cp "$firewall" "$work/firewall.kept"
chroot "$root" /bin/sh "$script"
cmp "$firewall" "$work/firewall.kept"
echo 'PASS: a firewall restored from kept settings keeps its choices'

script=/etc/uci-defaults/96-ttyd-defaults
ttyd="$root/etc/config/ttyd"
expect 'ttyd.@ttyd[0].interface' @lan
mkdir -p "$root/rom/etc/config"
cp "$ttyd" "$root/rom/etc/config/ttyd"
chroot "$root" /sbin/uci -q show ttyd > "$work/ttyd.shipped"
chroot "$root" /bin/sh "$script"
expect 'ttyd.@ttyd[0].interface' ''
chroot "$root" /sbin/uci -q show ttyd |
    cmp - <(grep -v '^ttyd\.@ttyd\[0\]\.interface=' "$work/ttyd.shipped")
echo 'PASS: ttyd listens on all addresses on a new system'
chroot "$root" /sbin/uci set 'ttyd.@ttyd[0].interface=@lan'
chroot "$root" /sbin/uci commit ttyd
cp "$ttyd" "$work/ttyd.kept"
chroot "$root" /bin/sh "$script"
cmp "$ttyd" "$work/ttyd.kept"
echo 'PASS: a ttyd configuration restored from kept settings keeps its choices'

# The WAN subnet hotplug script with the image's ipcalc.sh. netifd's answer
# comes from WAN_CIDR, and fw4 only records that it was asked to reload.
hotplug=/etc/hotplug.d/iface/30-wan-admin-subnet
cat > "$root/lib/functions/network.sh" <<'SH'
network_get_subnet() { [ -n "$WAN_CIDR" ] && eval "$1=\$WAN_CIDR"; }
SH
fw4=$(chroot "$root" /bin/sh -c 'command -v fw4')
printf '#!/bin/sh\necho "$*" >> /tmp/fw4.calls\n' > "$root$fw4"
mkdir -p "$root/tmp/run"
: > "$root/tmp/fw4.calls"
# Run the script for ACTION $2 and WAN address $3 on interface $1, and expect
# the set file to hold $4 and fw4 to have reloaded the sets $5 times in all.
hotplug_case() {
    local actual reloads
    chroot "$root" env INTERFACE="$1" ACTION="$2" WAN_CIDR="$3" /bin/sh "$hotplug"
    actual=$(cat "$root/tmp/run/wan-admin-subnet" 2> /dev/null || true)
    reloads=$(grep -c '^-q reload-sets$' "$root/tmp/fw4.calls" || true)
    [[ $actual == "$4" && $reloads == "$5" ]] || {
        echo "FAIL: $1 $2 [$3]: set [$actual], reloads [$reloads]; expected [$4], [$5]" >&2
        exit 1
    }
    echo "PASS: $1 $2 [$3] allows [$4]"
}
hotplug_case wan ifup '' '' 0
hotplug_case wan ifup 10.10.10.10/24 10.10.10.0/24 1
hotplug_case wan ifupdate 10.10.10.10/24 10.10.10.0/24 1
hotplug_case lan ifup 192.168.72.1/24 10.10.10.0/24 1
hotplug_case wan ifup 192.168.31.5/24 192.168.31.0/24 2
hotplug_case wan ifup 172.31.200.70/26 172.31.200.64/26 3
hotplug_case wan ifup 10.0.0.2/30 10.0.0.0/30 4
hotplug_case wan ifdown 10.0.0.2/30 '' 5
for cidr in 10.10.10.10/24 10.183.70.235/16 10.10.10.10/24 192.168.2.10/23 \
    10.10.10.10/24 10.0.0.2/31 10.10.10.10/24 203.0.113.10/32 \
    10.10.10.10/24 172.32.0.5/24 10.10.10.10/24 100.64.1.2/24; do
    case $cidr in
        10.10.10.10/24) expected=10.10.10.0/24 ;;
        *) expected='' ;;
    esac
    reloads=$(( $(grep -c . "$root/tmp/fw4.calls") + 1 ))
    hotplug_case wan ifup "$cidr" "$expected" "$reloads"
done
echo 'System defaults tests passed'
