#!/bin/sh
# busybox udhcpc script for the LAN client inside network namespace "lanc".
case "$1" in
    deconfig)
        ip addr flush dev "$interface"
        ;;
    bound|renew)
        ip addr flush dev "$interface"
        ip addr add "$ip/${mask:-24}" dev "$interface"
        [ -n "$router" ] && ip route replace default via "${router%% *}" dev "$interface"
        echo "lease: $ip/${mask:-24} router=$router dns=$dns"
        ;;
esac
