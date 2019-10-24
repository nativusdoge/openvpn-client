#!/usr/bin/env bash
#===============================================================================
#          FILE: openvpn.sh
#
#         USAGE: ./openvpn.sh
#
#   DESCRIPTION: Entrypoint for openvpn docker container
#
#       OPTIONS: ---
#  REQUIREMENTS: ---
#          BUGS: ---
#         NOTES: ---
#        AUTHOR: nativusdoge, David Personette (dperson@gmail.com),
#  ORGANIZATION:
#       CREATED: 09/28/2014 12:11
#      REVISION: 1.0
#===============================================================================

set -o nounset                              # Treat unset variables as an error

### dns: setup openvpn client DNS
# Arguments:
#   none)
# Return: conf file that uses VPN provider's DNS resolvers
dns() {
    sed -i '/down\|up/d; /resolv-*conf/d; /script-security/d' $conf
    echo "# This updates the resolvconf with dns settings" >>$conf
    echo "script-security 2" >>$conf
    echo "up /etc/openvpn/up.sh" >>$conf
    echo "down /etc/openvpn/down.sh" >>$conf
}

### firewall: firewall all output not DNS/VPN that's not over the VPN connection
# Arguments:
#   none)
# Return: configured firewall
firewall() { local docker_network="$(ip -o addr show dev eth0 | awk '$3 == "inet" {print $4}')" \
             vpn_endpoint="$(awk '/^remote / {print $2}' $conf)" \
             port="$(awk '/^remote / {print $3}' $conf)"

    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT DROP

    iptables -A INPUT -i lo -j ACCEPT
    iptables -A INPUT -d ${docker_network} -j ACCEPT

    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -d ${docker_network} -j ACCEPT
    iptables -A OUTPUT -d ${docker_network} -p udp --dport 53 -j DROP

    iptables -A OUTPUT -d ${vpn_endpoint} -p tcp --dport ${port} -j ACCEPT
    iptables -A OUTPUT -d ${vpn_endpoint} -p udp --dport ${port} -j ACCEPT

    iptables -A INPUT -i tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A OUTPUT -o tun0 -j ACCEPT
}

### open_port: open inbound ports on the VPN connection
# Arguments:
#   ports) comma separated list of ports and protocols
# Return: configured firewall
open_port() { local ports="$1"

    while IFS=',' read -ra array; do
        for i in "${array[@]}"; do
            IFS=":" read var1 var2 <<< "$i"
            iptables -A INPUT -i tun0 -p $var2 --dport $var1 -m conntrack --ctstate NEW,ESTABLISHED -j ACCEPT
        done
    done <<< "$ports"
}

dir="/vpn"
conf="$dir/vpn.conf"
[[ -f $conf ]] || { [[ $(ls -d $dir/*|egrep '\.(conf|ovpn)$' 2>&-|wc -w) -eq 1 \
            ]] && conf="$(ls -d $dir/* | egrep '\.(conf|ovpn)$' 2>&-)"; }

firewall;

[[ "${OPENPORTS:-""}" ]] && open_port "$OPENPORTS"
[[ "${DNS:-""}" ]] && dns

if ps -ef | egrep -v 'grep|openvpn.sh' | grep -q openvpn; then
    echo "Service already running, please restart container to apply changes"
else
    mkdir -p /dev/net
    [[ -c /dev/net/tun ]] || mknod -m 0666 /dev/net/tun c 10 200
    [[ -e $conf ]] || { echo "ERROR: VPN not configured!"; sleep 120; }
    exec sg vpn -c "openvpn --cd $dir --config $conf \
                ${MSS:+--fragment $MSS --mssfix}"
fi
