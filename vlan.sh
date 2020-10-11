# create
ip link add link eth0 name eth0.5 type vlan id 5
ip -d link show eth0.5
ip addr add 192.168.1.200/24 brd 192.168.1.255 dev eth0.5
ip link set dev eth0.5 up
#delete
ip link set dev eth0.5 down
ip link delete eth0.5
