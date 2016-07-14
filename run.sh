#!/bin/bash
#
# Docker script for starting an IPsec/L2TP VPN server
#
# DO NOT RUN THIS SCRIPT ON YOUR PC OR MAC! THIS IS ONLY MEANT TO BE RUN
# IN A DOCKER CONTAINER!
#
# Copyright (C) 2016 Lin Song
# Based on the work of Thomas Sarlandie (Copyright 2012)
#
# This work is licensed under the Creative Commons Attribution-ShareAlike 3.0
# Unported License: http://creativecommons.org/licenses/by-sa/3.0/
#
# Attribution required: please include my name in any derivative and let me
# know how you have improved it!

# IPsec Pre-Shared Key, VPN User List
VPN_IPSEC_PSK=$VPN_IPSEC_PSK
VPN_USERS=$VPN_USERS
VPN_USERS=$VPN_USERS
VPN_DNS=${VPN_DNS:-"8.8.8.8,8.8.4.4"}
VPN_L2TP_SUBNET=${VPN_L2TP_SUBNET:-"192.168.42"}
VPN_XAUTH_SUBNET=${VPN_XAUTH_SUBNET:-"192.168.43"}

function rand {
    cat /dev/urandom | env LC_CTYPE=C tr -dc a-zA-Z0-9 | head -c 24
}

function trim {
    echo "$1" | xargs
}

export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

if [ ! -f /.dockerenv ]; then
  echo 'This script should ONLY be run in a Docker container! Aborting.'
  exit 1
fi

if [ ! -f /sys/class/net/eth0/operstate ]; then
  echo "Network interface 'eth0' is not available. Aborting."
  exit 1
fi

echo
echo 'Trying to auto discover IPs of this server...'
echo

# In case auto IP discovery fails, you may manually enter the public IP
# of this server in your 'env' file, using variable 'VPN_PUBLIC_IP'.
PUBLIC_IP=$VPN_PUBLIC_IP

# Try to auto discover server IPs
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(dig +short myip.opendns.com @resolver1.opendns.com)
[ -z "$PUBLIC_IP" ] && PUBLIC_IP=$(wget -t 3 -T 15 -qO- http://ipv4.icanhazip.com)
PRIVATE_IP=$(ip -4 route get 1 | awk '{print $NF;exit}')
[ -z "$PRIVATE_IP" ] && PRIVATE_IP=$(ifconfig eth0 | grep -Eo 'inet (addr:)?([0-9]*\.){3}[0-9]*' | grep -Eo '([0-9]*\.){3}[0-9]*')

# Check IPs for correct format
IP_REGEX="^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$"
if ! printf %s "$PUBLIC_IP" | grep -Eq "$IP_REGEX"; then
  echo "Cannot find valid public IP. Please manually enter the public IP"
  echo "of this server in your 'env' file, using variable 'VPN_PUBLIC_IP'."
  exit 1
fi
if ! printf %s "$PRIVATE_IP" | grep -Eq "$IP_REGEX"; then
  echo "Cannot find valid private IP. Aborting."
  exit 1
fi

# Create IPsec (Libreswan) config
cat > /etc/ipsec.conf <<EOF
version 2.0

config setup
  virtual_private=%v4:10.0.0.0/8,%v4:192.168.0.0/16,%v4:172.16.0.0/12,%v4:!$VPN_L2TP_SUBNET.0/23
  protostack=netkey
  nhelpers=0
  interfaces=%defaultroute
  uniqueids=no

conn shared
  left=$PRIVATE_IP
  leftid=$PUBLIC_IP
  right=%any
  forceencaps=yes
  authby=secret
  pfs=no
  rekey=no
  keyingtries=5
  dpddelay=30
  dpdtimeout=120
  dpdaction=clear

conn l2tp-psk
  auto=add
  leftsubnet=$PRIVATE_IP/32
  leftnexthop=%defaultroute
  leftprotoport=17/1701
  rightprotoport=17/%any
  rightsubnetwithin=0.0.0.0/0
  type=transport
  auth=esp
  ike=3des-sha1,aes-sha1
  phase2alg=3des-sha1,aes-sha1
  also=shared

conn xauth-psk
  auto=add
  leftsubnet=0.0.0.0/0
  rightaddresspool=$VPN_XAUTH_SUBNET.10-$VPN_XAUTH_SUBNET.250
  leftxauthserver=yes
  rightxauthclient=yes
  leftmodecfgserver=yes
  rightmodecfgclient=yes
  modecfgpull=yes
  xauthby=file
  ike-frag=yes
  ikev2=never
  cisco-unity=yes
  also=shared
EOF

# Create xl2tpd config
cat > /etc/xl2tpd/xl2tpd.conf <<EOF
[global]
port = 1701

[lns default]
ip range = $VPN_L2TP_SUBNET.10-$VPN_L2TP_SUBNET.250
local ip = $VPN_L2TP_SUBNET.1
require chap = yes
refuse pap = yes
require authentication = yes
name = l2tpd
pppoptfile = /etc/ppp/options.xl2tpd
length bit = yes
EOF

# Set xl2tpd options
cat > /etc/ppp/options.xl2tpd <<EOF
ipcp-accept-local
ipcp-accept-remote
noccp
auth
crtscts
idle 1800
mtu 1280
mru 1280
lock
lcp-echo-failure 10
lcp-echo-interval 60
connect-delay 5000
EOF

# Show message
cat <<EOF

================================================

IPsec VPN server is now ready for use!

Connect to your new VPN with these details:

Server IP: $PUBLIC_IP
EOF

# Insert VPN DNS entries
IFS=","; DNS_ARR=($(trim "$VPN_DNS"))
# Loop through each
for i in "${!DNS_ARR[@]}"; do
    DNS="${DNS_ARR[$i]}"
    echo "ms-dns $DNS" >> /etc/ppp/options.xl2tpd
    echo "  modecfgdns$(($i+1))=$DNS" >> /etc/ipsec.conf
    echo "DNS #$(($i+1)): $DNS"
done

# Generate default shared secret
if [ -z "$VPN_IPSEC_PSK" ]; then
    VPN_IPSEC_PSK=$(rand)
fi

# Show shared secret
echo "IPsec PSK: $VPN_IPSEC_PSK"

# Specify IPsec PSK
cat > /etc/ipsec.secrets <<EOF
$PUBLIC_IP  %any  : PSK "$VPN_IPSEC_PSK"
EOF

# Prepare VPN user files
cat > /etc/ppp/chap-secrets <<EOF
# Secrets for authentication using CHAP
# client  server  secret  IP addresses
EOF
echo -n "" > /etc/ipsec.d/passwd
# Insert VPN users
IFS=","; USER_ARR=($(trim "$VPN_USERS"))
# List is empty, insert default user
if [[ "${#USER_ARR[@]}" = "0" ]]; then
    # Use VPN_USER/VPN_PASSWORD
    # Fallback to 'vpnuser'/generated
    USER_ARR[0]="${VPN_USER:-vpnuser}:${VPN_PASSWORD}"
fi
# Loop through each
for i in "${!USER_ARR[@]}"; do
    PAIR=${USER_ARR[$i]}
    IFS=":"; USERPASS=($PAIR)
    USER=$(trim ${USERPASS[0]})
    PASS=$(trim ${USERPASS[1]})
    #If not provided, generate random password
    if [[ "$PASS" = "" ]]; then
        PASS=$(rand)
    fi
    #Add to chap-secrets
    SRC_IP="*"
    echo "\"$USER\" l2tpd \"$PASS\" $SRC_IP" >> /etc/ppp/chap-secrets
    #Add to xauth-secrets
    PASS_ENC=$(openssl passwd -1 "$PASS")
    echo "${USER}:${PASS_ENC}:xauth-psk" >> /etc/ipsec.d/passwd
    #Show credentials
    echo "[User $(($i+1))]"
    echo "  Username: $USER"
    echo "  Password: $PASS"
done

cat <<EOF

Write these down. You'll need them to connect!

Setup VPN Clients: https://git.io/vpnclients

================================================

EOF

# Update sysctl settings
if ! grep -qs "hwdsl2 VPN script" /etc/sysctl.conf; then
cat >> /etc/sysctl.conf <<EOF

# Added by hwdsl2 VPN script
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.shmmax = 68719476736
kernel.shmall = 4294967296

net.ipv4.ip_forward = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.lo.send_redirects = 0
net.ipv4.conf.eth0.send_redirects = 0
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.lo.rp_filter = 0
net.ipv4.conf.eth0.rp_filter = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

net.core.wmem_max = 12582912
net.core.rmem_max = 12582912
net.ipv4.tcp_rmem = 10240 87380 12582912
net.ipv4.tcp_wmem = 10240 87380 12582912
EOF
fi

# Create IPTables rules
iptables -I INPUT 1 -p udp -m multiport --dports 500,4500 -j ACCEPT
iptables -I INPUT 2 -p udp --dport 1701 -m policy --dir in --pol ipsec -j ACCEPT
iptables -I INPUT 3 -p udp --dport 1701 -j DROP
iptables -I FORWARD 1 -m conntrack --ctstate INVALID -j DROP
iptables -I FORWARD 2 -i eth+ -o ppp+ -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -I FORWARD 3 -i ppp+ -o eth+ -j ACCEPT
iptables -I FORWARD 4 -i eth+ -d $VPN_XAUTH_SUBNET.0/24 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
iptables -I FORWARD 5 -s $VPN_XAUTH_SUBNET.0/24 -o eth+ -j ACCEPT
# To allow traffic between VPN clients themselves, uncomment these lines:
iptables -I FORWARD 6 -i ppp+ -o ppp+ -s $VPN_L2TP_SUBNET.0/24 -d $VPN_L2TP_SUBNET.0/24 -j ACCEPT
iptables -I FORWARD 7 -s $VPN_XAUTH_SUBNET.0/24 -d $VPN_XAUTH_SUBNET.0/24 -j ACCEPT
iptables -A FORWARD -j DROP
iptables -t nat -I POSTROUTING -s $VPN_XAUTH_SUBNET.0/24 -o eth+ -m policy --dir out --pol none -j SNAT --to-source "$PRIVATE_IP"
iptables -t nat -I POSTROUTING -s $VPN_L2TP_SUBNET.0/24 -o eth+ -j SNAT --to-source "$PRIVATE_IP"

# Reload sysctl.conf
sysctl -q -p 2>/dev/null

# Update file attributes
chmod 600 /etc/ipsec.secrets /etc/ppp/chap-secrets /etc/ipsec.d/passwd

# Load IPsec NETKEY kernel module
modprobe af_key

# Start services
mkdir -p /var/run/pluto /var/run/xl2tpd
rm -f /var/run/pluto/pluto.pid /var/run/xl2tpd.pid

/usr/local/sbin/ipsec start --config /etc/ipsec.conf
exec /usr/sbin/xl2tpd -D -c /etc/xl2tpd/xl2tpd.conf
