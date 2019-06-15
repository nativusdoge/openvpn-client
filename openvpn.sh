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

### cert_auth: setup auth passwd for accessing certificate
# Arguments:
#   passwd) Password to access the cert
# Return: conf file that supports certificate authentication
cert_auth() { local passwd="$1"
    grep -q "^${passwd}\$" $cert_auth || {
        echo "$passwd" >$cert_auth
    }
    chmod 0600 $cert_auth
    grep -q "^askpass ${cert_auth}\$" $conf || {
        sed -i '/askpass/d' $conf
        echo "askpass $cert_auth" >>$conf
    }
}

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

    iptables -A INPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

    iptables -A OUTPUT -o lo -j ACCEPT
    iptables -A OUTPUT -d ${docker_network} -j ACCEPT
    iptables -A OUTPUT -d ${docker_network} -p udp --dport 53 -j DROP

    iptables -A OUTPUT -d ${vpn_endpoint} -p tcp --dport ${port} -j ACCEPT
    iptables -A OUTPUT -o tun0 -j ACCEPT
    # [[ -s $route ]] && for net in $(cat $route); do return_route $net; done
}

### return_route: add a route back to your network, so that return traffic works
# Arguments:
#   network) a CIDR specified network range
# Return: configured return route
return_route() { local network="$1" gw="$(ip route |awk '/default/ {print $3}')"
    ip route | grep -q "$network" ||
        ip route add to $network via $gw dev eth0
    iptables -A OUTPUT --destination $network -j ACCEPT
    [[ -e $route ]] && grep -q "^$network\$" $route || echo "$network" >>$route
}

### vpn: setup openvpn client
# Arguments:
#   server) VPN GW server
#   user) user name on VPN
#   pass) password on VPN
#   port) port to connect to VPN (optional)
# Return: configured .ovpn file
vpn() { local server="$1" user="$2" pass="$3" port="${4:-1194}" i \
            pem="$(\ls $dir/*.pem 2>&-)"

    echo "client" >$conf
    echo "dev tun" >>$conf
    echo "proto udp" >>$conf
    for i in $(sed 's/:/ /g' <<< $server); do
        echo "remote $i $port" >>$conf
    done
    [[ $server =~ : ]] && echo "remote-random" >>$conf
    echo "resolv-retry infinite" >>$conf
    echo "keepalive 10 60" >>$conf
    echo "nobind" >>$conf
    echo "persist-key" >>$conf
    echo "persist-tun" >>$conf
    [[ "${CIPHER:-""}" ]] && echo "cipher $CIPHER" >>$conf
    [[ "${AUTH:-""}" ]] && echo "auth $AUTH" >>$conf
    echo "tls-client" >>$conf
    echo "remote-cert-tls server" >>$conf
    echo "auth-user-pass $auth" >>$conf
    echo "comp-lzo" >>$conf
    echo "verb 1" >>$conf
    echo "reneg-sec 0" >>$conf
    echo "redirect-gateway def1" >>$conf
    echo "disable-occ" >>$conf
    echo "fast-io" >>$conf
    echo "ca $cert" >>$conf
    [[ $(wc -w <<< $pem) -eq 1 ]] && echo "crl-verify $pem" >>$conf

    echo "$user" >$auth
    echo "$pass" >>$auth
    chmod 0600 $auth

    [[ "${FIREWALL:-""}" || -e $route ]] && [[ "${4:-""}" ]] && firewall $port
}

### vpnportforward: setup vpn port forwarding
# Arguments:
#   port) forwarded port
# Return: configured NAT rule
vpnportforward() { local port="$1" protocol="${2:-tcp}"
    iptables -t nat -A OUTPUT -p $protocol --dport $port -j DNAT \
                --to-destination 127.0.0.11:$port
    echo "Setup forwarded port: $port $protocol"
}

### usage: Help
# Arguments:
#   none)
# Return: Help text
usage() { local RC="${1:-0}"
    echo "Usage: ${0##*/} [-opt] [command]
Options (fields in '[]' are optional, '<>' are required):
    -h          This help
    -c '<passwd>' Configure an authentication password to open the cert
                required arg: '<passwd>'
                <passwd> password to access the certificate file
    -d          Use the VPN provider's DNS resolvers
    -f '[port]' Firewall rules so that only the VPN and DNS are allowed to
                send internet traffic (IE if VPN is down it's offline)
                optional arg: [port] to use, instead of default
    -m '<mss>'  Maximum Segment Size <mss>
                required arg: '<mss>'
    -p '<port>[;protocol]' Forward port <port>
                required arg: '<port>'
                optional arg: [protocol] to use instead of default (tcp)
    -r '<network>' CIDR network (IE 192.168.1.0/24)
                required arg: '<network>'
                <network> add a route to (allows replies once the VPN is up)
    -v '<server;user;password[;port]>' Configure OpenVPN
                required arg: '<server>;<user>;<password>'
                <server> to connect to (multiple servers are separated by :)
                <user> to authenticate as
                <password> to authenticate with
                optional arg: [port] to use, instead of default

The 'command' (if provided and valid) will be run instead of openvpn
" >&2
    exit $RC
}

dir="/vpn"
auth="$dir/vpn.auth"
cert_auth="$dir/vpn.cert_auth"
conf="$dir/vpn.conf"
cert="$dir/vpn-ca.crt"
route="$dir/.firewall"
[[ -f $conf ]] || { [[ $(ls -d $dir/*|egrep '\.(conf|ovpn)$' 2>&-|wc -w) -eq 1 \
            ]] && conf="$(ls -d $dir/* | egrep '\.(conf|ovpn)$' 2>&-)"; }
[[ -f $cert ]] || { [[ $(ls -d $dir/* | egrep '\.ce?rt$' 2>&- | wc -w) -eq 1 \
            ]] && cert="$(ls -d $dir/* | egrep '\.ce?rt$' 2>&-)"; }

#[[ "${CERT_AUTH:-""}" ]] && cert_auth "$CERT_AUTH"
[[ "${DNS:-""}" ]] && dns
[[ "${GROUPID:-""}" =~ ^[0-9]+$ ]] && groupmod -g $GROUPID -o vpn
[[ "${FIREWALL:-""}" || -e $route ]] && firewall "${FIREWALL:-""}"
#[[ "${ROUTE:-""}" ]] && return_route "$ROUTE"
[[ "${VPN:-""}" ]] && eval vpn $(sed 's/^/"/; s/$/"/; s/;/" "/g' <<< $VPN)
#[[ "${VPNPORT:-""}" ]] && eval vpnportforward $(sed 's/^/"/; s/$/"/; s/;/" "/g'\
#            <<< $VPNPORT)

# while getopts ":hc:df:m:p:R:r:v:" opt; do
#     case "$opt" in
#         h) usage ;;
#         c) cert_auth "$OPTARG" ;;
#         d) dns ;;
#         f) firewall "$OPTARG"; touch $route ;;
#         m) MSS="$OPTARG" ;;
#         p) eval vpnportforward $(sed 's/^/"/; s/$/"/; s/;/" "/g' <<< $OPTARG) ;;
#         r) return_route "$OPTARG" ;;
#         v) eval vpn $(sed 's/^/"/; s/$/"/; s/;/" "/g' <<< $OPTARG) ;;
#         "?") echo "Unknown option: -$OPTARG"; usage 1 ;;
#         ":") echo "No argument value for option: -$OPTARG"; usage 2 ;;
#     esac
# done
# shift $(( OPTIND - 1 ))
dns;
firewall;

if ps -ef | egrep -v 'grep|openvpn.sh' | grep -q openvpn; then
    echo "Service already running, please restart container to apply changes"
else
    mkdir -p /dev/net
    [[ -c /dev/net/tun ]] || mknod -m 0666 /dev/net/tun c 10 200
    [[ -e $conf ]] || { echo "ERROR: VPN not configured!"; sleep 120; }
    exec sg vpn -c "openvpn --cd $dir --config $conf \
                ${MSS:+--fragment $MSS --mssfix}"
fi
