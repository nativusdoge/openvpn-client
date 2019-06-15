# Credit

This work is heavily based on the work of [David Personette](https://github.com/dperson/openvpn-client).

# OpenVPN

This is an OpenVPN client docker container. It makes routing containers'
traffic through OpenVPN easy.

# What is OpenVPN?

OpenVPN is an open-source software application that implements virtual private
network (VPN) techniques for creating secure point-to-point or site-to-site
connections in routed or bridged configurations and remote access facilities.
It uses a custom security protocol that utilizes SSL/TLS for key exchange. It is
capable of traversing network address translators (NATs) and firewalls.

# How to use this image

This OpenVPN container was designed to be started first to provide a connection
to other containers (using `--net=container:vpn`, see below *Starting an OpenVPN
client instance*).

**NOTE**: More than the basic privileges are needed for OpenVPN. With docker 1.2
or newer you can use the `--cap-add=NET_ADMIN` and `--device /dev/net/tun`
options. Earlier versions, or with fig, and you'll have to run it in privileged
mode.

**NOTE 4**: If you have a VPN service that allows making local services
available, you'll need to reuse the VPN container's network stack with the
`--net=container:vpn` (replacing 'vpn' with what you named your instance of this
container) when you launch the service in it's container.

**NOTE 5**: If you need a template for using this container with
`docker-compose`, see the example
[file](https://github.com/nativusdoge/openvpn-client/raw/master/docker-compose.yml).

## Starting an OpenVPN client instance

    sudo cp /path/to/vpn.ovpn /some/path/vpn.ovpn
    sudo docker run -it --cap-add=NET_ADMIN --device /dev/net/tun --name vpn \
                -v /some/path:/vpn -d nativusdoge/openvpn-client

Once it's up other containers can be started using it's network connection:

    sudo docker run -it --net=container:vpn -d some/docker-container

## Local Network access to services connecting to the internet through the VPN.

However to access them from your normal network (off the 'local' docker bridge),
you'll also need to run a web proxy, like so:

    sudo docker run -it --name web -p 80:80 -p 443:443 \
                --link vpn:<service_name> -d dperson/nginx \
                -w "http://<service_name>:<PORT>/<URI>;/<PATH>"

Which will start a Nginx web server on local ports 80 and 443, and proxy any
requests under `/<PATH>` to the to `http://<service_name>:<PORT>/<URI>`. To use
a concrete example:

    sudo docker run -it --name bit --net=container:vpn -d dperson/transmission
    sudo docker run -it --name web -p 80:80 -p 443:443 --link vpn:bit \
                -d dperson/nginx -w "http://bit:9091/transmission;/transmission"

For multiple services (non-existant 'foo' used as an example):

    sudo docker run -it --name bit --net=container:vpn -d dperson/transmission
    sudo docker run -it --name foo --net=container:vpn -d dperson/foo
    sudo docker run -it --name web -p 80:80 -p 443:443 --link vpn:bit \
                --link vpn:foo -d dperson/nginx \
                -w "http://bit:9091/transmission;/transmission" \
                -w "http://foo:8000/foo;/foo"

## Configuration

ENVIRONMENT VARIABLES

 * `MSS` - As above, set Maximum Segment Size
 * `OPENPORTS` - Comma separated list of ports and protocols you want opened
 on the VPN tunnel. ie. `6881:tcp,6882:udp`

## Examples

Any of the commands can be run at creation with `docker run` or later with
`docker exec -it openvpn openvpn.sh` (as of version 1.3 of docker).

### VPN configuration

In order to work you must provide VPN configuration and the certificate
together in an `ovpn` file. You can use external storage for `/vpn`:

    sudo cp /path/to/vpn.ovpn /some/path/vpn.ovpn
    sudo docker run -it --cap-add=NET_ADMIN --device /dev/net/tun --name vpn \
                -v /some/path:/vpn -d nativusdoge/openvpn-client

### Firewall

Firewall is enabled by default. Loopback and Docker Network traffic is
permitted. DNS is restricted to the VPN interface. Internet traffic is
restricted to the remote address defined in the `ovpn` file.

VPN interface ports may be opened using the `OPENPORTS` environment variable.

### DNS

By default this container will use the DNS settings provided by your VPN
endpoint as using local DNS will cause leakage.
