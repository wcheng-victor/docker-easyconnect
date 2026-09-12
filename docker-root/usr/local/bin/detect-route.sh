#!/bin/bash
# 设置策略路由使宿主机外的机器能够访问容器提供的服务
## 将路由表 main 备份到路由表 2
(
ip route flush table 2
IFS="
"
for i in $(ip route show); do IFS=' '; ip route add $i table 2 ; done
)
## 回包路由
# 此处不能直接 `ip rule add iif $VPN_TUN table 2`：tun 设备要等 VPN 连上之后才存在，
# 而设备不存在时该命令仍会成功、只是留下一条带 [detached] 的规则，永远不匹配任何流量。
# 因此这里只输出函数定义，由 start.sh 在后台等待设备就绪后再添加。
echo 'open_tun_route() {'
echo '	[ -n "$VPN_TUN" ] || return'
echo '	while :; do'
echo '		if ip link show "$VPN_TUN" > /dev/null 2>&1; then'
echo '			# 设备不存在期间加上的规则带有 [detached]，先清掉'
echo '			ip rule show | grep "iif $VPN_TUN " | grep -q detached &&'
echo '				ip rule del iif "$VPN_TUN" table 2 2>/dev/null'
echo '			# 有效规则形如 "... iif utun7 lookup 2"，detached 的规则不含 "lookup 2"'
echo '			ip rule show | grep -q "iif $VPN_TUN lookup 2" ||'
echo '				ip rule add iif "$VPN_TUN" table 2'
echo '		fi'
echo '		# VPN 重连会重建 tun 设备，使既有规则失效，故持续检查'
echo '		sleep 10'
echo '	done'
echo '}'
## 确定策略路由方式
ip rule add iif lo table 2 sport 1080
if ip rule show iif lo table 2 | grep sport >/dev/null ; then
	echo 'open_port() { ip rule add iif lo table 2 sport $1; }'
	echo 'close_port() { ip rule del iif lo table 2 sport $1; }'
elif iptables -t mangle -A OUTPUT -j MARK --set-mark 1 -p tcp --sport 1080 2>/dev/null ; then
	iptables -t mangle -D OUTPUT -j MARK --set-mark 1 -p tcp --sport 1080
	ip rule add fwmark 1 table 2
	echo 'open_port() { iptables -t mangle -I OUTPUT -j MARK --set-mark 1 -p tcp --sport $1; }'
	echo 'close_port() { iptables -t mangle -D OUTPUT -j MARK --set-mark 1 -p tcp --sport $1; }'
else
	echo 'open_port() { true; }'
	echo 'close_port() { true; }'
	echo "Can't find available method to automatically set route for opening ports"\
	     "(refer to https://github.com/Hagb/docker-easyconnect/tree/master/doc/route.md)" >&2

fi
ip rule del iif lo sport 1080 table 2

