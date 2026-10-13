#!/usr/bin/env bash
# Keep-settings sysupgrade with the same image: changed settings, the data
# partition and Docker data must all survive. Failed checks are recorded in
# $VM_WORK/failures.
set -uo pipefail
. "$(dirname "$0")/lib.sh"
image=$1
serial=$VM_WORK/serial.log
wait_for_router 300 || exit 1

echo "== 升级前：修改设置并写入标记"
vm 'uci set system.@system[0].hostname=kept-host && uci commit system'
vm 'uci set firewall.@defaults[0].flow_offloading=0 && uci commit firewall'
vm 'echo kept > /data/marker'
images_before=$(vm 'docker images --format "{{.Repository}}:{{.Tag}}" | sort | xargs')
echo "docker images before: $images_before"
vm 'cat /proc/partitions | grep nvme'

echo "== 上传固件并执行保留配置的 sysupgrade"
vm_copy "$image" /tmp/fw.img.gz
vm 'sysupgrade -T /tmp/fw.img.gz && echo "sysupgrade -T: image check ok"'
lines_before=$(wc -l < "$serial")
boots_before=$(grep -ac 'Linux version' "$serial")
# Run in the foreground: procd takes over the upgrade and the session drops.
timeout 300 bash -c '. "$1"; vm "sysupgrade -v /tmp/fw.img.gz"' _ "$VM_DIR/lib.sh" || true
# Poll SSH only once the upgraded system's kernel starts; until then the old
# system may still answer.
for _ in $(seq 120); do
    [ "$(grep -ac 'Linux version' "$serial")" -gt "$boots_before" ] && break
    sleep 5
done
wait_for_router 1800 || { tail -n +"$lines_before" "$serial" | tail -40; exit 1; }
echo "== 串口中的升级记录"
tail -n +"$lines_before" "$serial" | grep -aiE "partition|writing|upgrade|saving|restor|sysupgrade|Linux version" | head -20

echo "== 升级后"
check 'rebooted once' "$((boots_before + 1))" "$(grep -ac 'Linux version' "$serial")"
check 'uploaded image gone from /tmp' gone "$(vm '[ -e /tmp/fw.img.gz ] && echo present || echo gone')"
check 'hostname kept' kept-host "$(vm 'uci -q get system.@system[0].hostname')"
check 'zonename kept' Asia/Shanghai "$(vm 'uci -q get system.@system[0].zonename')"
check 'flow offloading kept off' 0 "$(vm 'uci -q get firewall.@defaults[0].flow_offloading')"
check 'WAN admin rule kept' rule "$(vm 'uci -q get firewall.wan_private_admin')"
check 'SSH from WAN side' ok "$(sshpass -e ssh -n -q -p 2222 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 root@127.0.0.1 'echo ok' 2> /dev/null)"
check 'LAN address kept' 192.168.72.1/24 "$(vm 'ip -4 -o addr show br-lan' | awk '{print $4}')"
check 'data marker' kept "$(vm 'cat /data/marker')"
check 'docker images kept' "$images_before" "$(vm 'docker images --format "{{.Repository}}:{{.Tag}}" | sort | xargs')"
check 'docker root/driver' '/data/docker overlayfs' "$(vm 'docker info --format "{{.DockerRootDir}} {{.Driver}}"' | sed 's|/ | |')"
check 'separate mount for the Docker data root' 0 "$(vm 'grep -c " /data/docker " /proc/mounts')"
check 'pending uci-defaults' '' "$(vm 'ls /etc/uci-defaults' | xargs)"
check 'sing-box enabled' 0 "$(vm 'uci -q get sing-box.main.enabled')"
vm 'cat /proc/partitions | grep nvme'
check 'LAN client HTTPS' 200 "$(lan curl -sS -o /dev/null -m 30 -w '%{http_code}' https://www.cloudflare.com/cdn-cgi/trace)"
exit 0
