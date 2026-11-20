#!/bin/bash
eval "$(detect-iptables.sh)"
# vpn-config.sh 需先于 detect-route.sh：后者要用到 VPN_TUN
eval "$(vpn-config.sh)"
eval "$(detect-route.sh)"

forward_ports() {
	if [ -n "$FORWARD" ]; then
		if iptables -t mangle -A PREROUTING -m addrtype --dst-type LOCAL -j MARK --set-mark 2; then
			iptables -t mangle -D PREROUTING -m addrtype --dst-type LOCAL -j MARK --set-mark 2
			iptables -t nat -A POSTROUTING -p tcp -m mark --mark 2 -j MASQUERADE
			ip rule add fwmark 2 table 2
			format_error() { echo Format error in \""$rule"\": "$@" >&2 ; }
			for rule in $FORWARD; do
				array=(${rule//:/ })
				case ${#array[@]} in
					3) src_args="" ;;
					4) src_args="-s ${array[0]}" ;;
					*) format_error; continue ;;
				esac
				dst=${array[-2]}:${array[-1]}
				dport=${array[-3]}
				match_args="$src_args --dport $dport -m addrtype --dst-type LOCAL -i $VPN_TUN"
				iptables -t mangle -A PREROUTING -p tcp $match_args -j MARK --set-mark 2
				iptables -t mangle -A PREROUTING -p udp $match_args -j MARK --set-mark 2
				iptables -t nat -A PREROUTING -p tcp $match_args -j DNAT --to-destination $dst
				iptables -t nat -A PREROUTING -p udp $match_args -j DNAT --to-destination $dst

			done
		else
			echo "Can't append iptables used to forward ports from EasyConnect to host network!" >&2
		fi
	fi
}

start_danted() {
	cp /etc/danted.conf.sample /run/danted.conf

	if [[ -n "$SOCKS_PASSWD" && -n "$SOCKS_USER" ]];then
		id $SOCKS_USER &> /dev/null
		if [ $? -ne 0 ]; then
			useradd $SOCKS_USER
		fi

		echo $SOCKS_USER:$SOCKS_PASSWD | chpasswd
		sed -i 's/socksmethod: none/socksmethod: username/g' /run/danted.conf

		echo "use socks5 auth: $SOCKS_USER:$SOCKS_PASSWD"
	fi

	internals=""
	externals=""
        ipv6=$(ip -6 a)
        if [[ $ipv6 ]]; then
                internals="internal: 0.0.0.0 port = 1080\\ninternal: :: port = 1080"
        else

                internals="internal: 0.0.0.0 port = 1080"
        fi
	for iface in $(ip -o addr | sed -E 's/^[0-9]+: ([^ ]+) .*/\1/' | sort | uniq | grep -v "sit\|vir"); do
		externals="${externals}external: $iface\\n"
	done
	externals="${externals}external: $VPN_TUN\\n"
	sed /^internal:/c"$internals" -i /run/danted.conf
	sed /^external:/c"$externals" -i /run/danted.conf
	open_port 1080
	if ip tuntap add mode tun $VPN_TUN; then
		# eth0 need >1s to be ready
		# refer to https://stackoverflow.com/questions/25226531/dante-sever-fail-to-bind-ip-by-interface-name-in-docker-container
		ip addr add 10.0.0.1/32 dev $VPN_TUN
		sleep 2
		/usr/sbin/danted -D -f /run/danted.conf
		ip tuntap del mode tun $VPN_TUN
	else
		echo 'Failed to create tun interface! Please check whether /dev/net/tun is available.' >&2
		echo 'Also refer to https://github.com/Hagb/docker-easyconnect/blob/master/doc/faq.md.' >&2
		exit 1
	fi
}

start_tinyproxy() {
	open_port 8888
	tinyproxy -c /etc/tinyproxy.conf
}

config_vpn_iptables() {
	iptables -t nat -A POSTROUTING -o $VPN_TUN -j MASQUERADE
	open_port 4440
	iptables -t nat -N SANGFOR_OUTPUT
	iptables -t nat -A PREROUTING -j SANGFOR_OUTPUT

	# 拒绝 tun 侧主动请求的连接.
	iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
	iptables -A INPUT -i $VPN_TUN -p tcp -j DROP
}

force_open_ports() {
	# 暴露 54530 等用于和浏览器通讯的端口
	tmp_port=20000
	for port in $FORCE_OPEN_PORTS; do
		open_port $port
		open_port $tmp_port
		iptables -t nat -A PREROUTING -p tcp --dport $port -m addrtype --dst-type LOCAL -j REDIRECT --to-port $tmp_port
		socat tcp-listen:$tmp_port,reuseaddr,fork tcp4:127.0.0.1:$port &
		((tmp_port++))
	done
}

init_vpn_config() {
	if [ "EC_CLI" = "$_VPN_TYPE" ]; then
		ln -fs /usr/share/sangfor/EasyConnect/resources/{conf_${EC_VER},conf}
	fi

	if [ "EC_GUI" = "$_VPN_TYPE" ]; then
		# 登录信息持久化处理
		## 持久化配置文件夹 感谢 @hexid26 https://github.com/Hagb/docker-easyconnect/issues/21
		cp -r /usr/share/sangfor/EasyConnect/resources/conf_backup/. ~/conf/
		rm -f ~/conf/ECDomainFile
		[ -e ~/easy_connect.json ] && mv ~/easy_connect.json ~/conf/easy_connect.json # 向下兼容
		mkdir -p /usr/share/sangfor/EasyConnect/resources/conf/
		cd ~/conf/

		## 不再假定 /root 的文件系统（可能从宿主机挂载）支持 unix sock（用于 ECDomainFile），因此不直接使用
		for file in *; do
			## 通过软链接减小拷贝量
			ln -s ~/conf/"$file" /usr/share/sangfor/EasyConnect/resources/conf/"$file"
		done
		cd -
		[ -n "$DISABLE_PKG_VERSION_XML" ] && ln -fs /dev/null /usr/share/sangfor/EasyConnect/resources/conf/pkg_version.xml

		sync_ec2volume() {
			cd /usr/share/sangfor/EasyConnect/resources/conf/
			[ -n "$DISABLE_PKG_VERSION_XML" ] && rm pkg_version.xml
			for file in *; do
				[ -r "$file" -a ! -L "$file" -a "ECDomainFile" != "$file" ] && cp -r "$file" ~/conf/
			done
			cd ~/conf/
			for file in *; do
				[ ! -e /usr/share/sangfor/EasyConnect/resources/conf/"$file" ] && {
					rm -r "$file"
				}
			done
		}
		## 容器退出时将配置文件同步回 /root/conf。感谢 @Einskai 的点子
		trap "sync_ec2volume; exit;" SIGINT SIGQUIT SIGSTOP SIGTSTP SIGTERM
	else
		trap "exit;" SIGINT SIGQUIT SIGSTOP SIGTSTP SIGTERM
	fi
}

start_tigervncserver() {
	# 容器重启后 /tmp/.X11-unix 中可能残留上次的 X socket（清理 /tmp 时特意跳过了该目录），
	# 会导致 tigervncserver 误认为 display 已被占用而启动失败，进而使 VPN 前端反复崩溃。
	# 此处仅在没有 Xtigervnc 运行时清除本 display 的残留 socket。
	pidof Xtigervnc > /dev/null || rm -f "/tmp/.X11-unix/X${DISPLAY#:}" "/tmp/.X${DISPLAY#:}-lock"

	# $PASSWORD 不为空时，更新 vnc 密码
	[ -e ~/.vnc/passwd ] || (mkdir -p ~/.vnc && (echo password | tigervncpasswd -f > ~/.vnc/passwd))
	[ -n "$PASSWORD" ] && printf %s "$PASSWORD" | tigervncpasswd -f > ~/.vnc/passwd

	VNC_SIZE="${VNC_SIZE:-1110x620}"

	open_port 5901
	tigervncserver "$DISPLAY" -geometry "$VNC_SIZE" -localhost no -passwd ~/.vnc/passwd -xstartup flwm
	stalonetray -f 0 2> /dev/null &

	if [ -n "$ECPASSWORD" ]; then
		echo "ECPASSWORD has been deprecated, because of the confusion of its name." >&2
		echo "Use CLIP_TEXT instead." >&2
	fi

	[ -z "$CLIP_TEXT" ] && CLIP_TEXT="$ECPASSWORD"

	# 将 easyconnect 的密码放入粘贴板中，应对密码复杂且无法保存的情况 (eg: 需要短信验证登录)
	# 感谢 @yakumioto https://github.com/Hagb/docker-easyconnect/pull/8
	echo "$CLIP_TEXT" | DISPLAY=:1 xclip -selection c

	# 环境变量USE_NOVNC不为空时，启动 easy-novnc
	if [ -n "$USE_NOVNC" ]; then
		open_port 8080
		novnc
	fi

}

keep_pinging() {
	[ -n "$PING_ADDR" ] && while sleep $PING_INTERVAL; do
		busybox ping -c1 -W1 -w1 "$PING_ADDR" >/dev/null 2>/dev/null
	done &
}

# 部分服务器禁ping，用wget一个网页的url代替
keep_pinging_url() {
	[ -n "$PING_ADDR_URL" ] && while sleep $PING_INTERVAL; do
		timeout 10 busybox wget -q --spider "$PING_ADDR_URL" 2>/dev/null
	done &
}

# aTrust DNS 自动发现与切换（仅 ATRUST 类型）。
#
# 背景：aTrust 的 DNS 代理会同时使用 inner(公司内网 DNS) 和 outer(容器系统 DNS)
# 两条解析路径。容器系统 DNS 在宿主机上可能被 TUN 类代理（如 mihomo 的 fake-IP）
# 劫持，于是 tinyproxy(8888)/danted(1080) 会间歇性解析到 fake-IP（如 198.19.x），
# 连接漏进 TUN 后因内网域名无法用公网 DNS 解析而立即断开。
#
# 做法：从 aTrust 的 DNS 访问日志中提取 inner DNS 地址（日志里形如
# "inner@10.64.84.4:53"），等 VPN tun 设备就绪后，把该地址路由进 tun，
# 并把容器 /etc/resolv.conf 指向它，使容器内域名始终由公司 DNS 解析出真实内网 IP。
# VPN 断开时恢复容器启动时的 resolv.conf。可用 VPN_DNS 手动覆盖；
# VPN_DNS_PROBE 指定一个会走内网 DNS 的域名，用于触发一条新鲜的解析日志。
#
# ！！！注意：dnsproxyAccess.log 的格式属于深信服 aTrust 的内部实现。
# ！！！升级 aTrust/深信服版本后必须重新验证日志中是否仍有 "inner@<IP>:53" 字段；
# ！！！若格式变化，本函数会检测失败并保持/恢复 Docker 默认 DNS（127.0.0.11），
# ！！！不会破坏网络，但需要按新格式修正提取逻辑。

# 切换 DNS 后重启代理，清掉登录前/登录窗口内可能缓存的 fake-IP。
# 可在 compose 里设置 VPN_DNS_NO_PROXY_RESTART=1 关闭。
restart_vpn_proxies() {
	[ -n "$VPN_DNS_NO_PROXY_RESTART" ] && return 0
	echo "aTrust DNS: restarting danted/tinyproxy to drop cached fake-IPs" >&2
	killall danted tinyproxy 2>/dev/null
	sleep 1
	killall -9 danted tinyproxy 2>/dev/null
	/usr/sbin/danted -D -f /run/danted.conf 2>/dev/null ||
		echo "aTrust DNS: failed to restart danted" >&2
	tinyproxy -c /etc/tinyproxy.conf 2>/dev/null ||
		echo "aTrust DNS: failed to restart tinyproxy" >&2
	sleep 1
	pidof danted > /dev/null &&
		echo "aTrust DNS: danted restarted" >&2 ||
		echo "aTrust DNS: danted is not running" >&2
	pidof tinyproxy > /dev/null &&
		echo "aTrust DNS: tinyproxy restarted" >&2 ||
		echo "aTrust DNS: tinyproxy is not running" >&2
}

open_vpn_dns() {
	[ "ATRUST" = "$_VPN_TYPE" ] || return 0
	local log=/root/.aTrust/logs/xtunnel/dnsproxyAccess.log
	local applied="" warned="" fails=0 degraded=0

	# 公网回退 DNS：unbound (DoT, 127.0.0.2:53)。宿主机 mihomo TUN 只劫持明文
	# 53 端口，DoT(853) 被当作普通流量放行，因此可绕开 fake-IP 污染获得真实解析。
	ensure_unbound_outer() {
		pidof unbound > /dev/null 2>&1 && return 0
		[ -x /usr/sbin/unbound ] || return 1
		/usr/sbin/unbound -d -c /etc/unbound/unbound-outer.conf >/dev/null 2>&1 &
		sleep 1
		pidof unbound > /dev/null 2>&1
	}

	# up 状态的 resolv.conf：公司 DNS 优先，unbound DoT 回退（公网域名在公司
	# DNS 上 SERVFAIL 时 glibc 会自动尝试下一个 nameserver）。
	write_resolv_up() {
		local f=/run/resolv.conf.new
		printf 'nameserver %s\n' "$1" > "$f"
		ensure_unbound_outer && printf 'nameserver 127.0.0.2\n' >> "$f"
		printf 'options timeout:1 attempts:2\n' >> "$f"
		# 注意：/etc/resolv.conf 是 Docker 的 bind-mount 文件，mv/rename 会报
		# "Device or resource busy"，必须用重定向原地写入。
		cat "$f" > /etc/resolv.conf && rm -f "$f"
	}

	# 周期验活：向公司 DNS 查询探测域名，答案为内网地址才算活着。
	# 用于识别"僵尸隧道"（注销后 utun7 仍持有内网地址，但会话已死）。
	probe_vpn_dns() {
		[ -n "$VPN_DNS_PROBE" ] || return 0
		local ans
		ans=$(timeout 2 busybox nslookup "$VPN_DNS_PROBE" "$1" 2>/dev/null |
			awk '/^Address: /{print $2}' | tail -1)
		case "$ans" in
			10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*) return 0 ;;
			*) return 1 ;;
		esac
	}


	# 保存容器启动时的 resolv.conf，VPN 断开后恢复
	[ -e /run/resolv.conf.orig ] || cp /etc/resolv.conf /run/resolv.conf.orig 2>/dev/null

	while :; do
		# 只有 tun 拿到内网地址才算隧道可用；登录前 utun7 可能是 2.0.0.1 之类的占位地址
		local tun_ip
		tun_ip=$(ip -4 -o addr show dev "$VPN_TUN" 2>/dev/null | awk '{print $4}' | cut -d/ -f1)
		case "$tun_ip" in
			10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*) ;;
			*) tun_ip="" ;;
		esac

		if [ -n "$tun_ip" ]; then
			if [ -n "$applied" ]; then
				# 自愈：VPN 重连或其它程序改动后，补回路由与 resolv.conf
				# （aTrust 可能整体重写路由表，把手动加的 /32 清掉，需持续补回）
				ip route replace "$applied/32" dev "$VPN_TUN" 2>/dev/null
				if probe_vpn_dns "$applied"; then
					fails=0
					[ "$degraded" = 1 ] && {
						degraded=0
						echo "aTrust DNS: $applied reachable again, restoring dual-path" >&2
					}
					if ! { grep -qx "nameserver $applied" /etc/resolv.conf 2>/dev/null &&
						grep -qx "nameserver 127.0.0.2" /etc/resolv.conf 2>/dev/null; }; then
						write_resolv_up "$applied"
					fi
				else
					fails=$((fails + 1))
					# 连续失败视为僵尸隧道：降级为仅 DoT，公网解析不再每次
					# 等公司 DNS 超时；恢复后自动切回双路。
					if [ "$fails" -ge 3 ] && [ "$degraded" = 0 ]; then
						degraded=1
						printf 'nameserver 127.0.0.2\noptions timeout:1 attempts:2\n' > /etc/resolv.conf
						echo "aTrust DNS: $applied probing failed ${fails}x, degraded to DoT-only" >&2
					fi
				fi
			else
				local dns="$VPN_DNS" ok=1 ans
				if [ -z "$dns" ]; then
					# 主动触发一次解析，尽量拿到本次会话的日志；否则取最后一条
					[ -n "$VPN_DNS_PROBE" ] &&
						busybox nslookup "$VPN_DNS_PROBE" 198.18.255.1 > /dev/null 2>&1
					dns=$(grep -aoE 'inner@[0-9.]+:53' "$log" 2>/dev/null |
						tail -1 | sed -E 's/inner@([0-9.]+):53/\1/')
				fi
				# 只接受内网地址，排除 127.0.0.11 和 198.19.x 等 fake-IP
				case "$dns" in
					10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*) ;;
					*) dns="" ;;
				esac
				if [ -n "$dns" ]; then
					# 先加路由，再用该 DNS 解析探测域名，确认隧道真的可用。
					# 登录前/刚重连时 tun 可能已在但还不通，不能急着改 resolv.conf。
					ip route replace "$dns/32" dev "$VPN_TUN"
					if [ -n "$VPN_DNS_PROBE" ]; then
						ans=$(timeout 4 busybox nslookup "$VPN_DNS_PROBE" "$dns" 2>/dev/null |
							awk '/^Address: /{print $2}' | tail -1)
						case "$ans" in
							10.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|192.168.*) ;;
							*) ok=0 ;;
						esac
					fi
					if [ "$ok" = 1 ]; then
						write_resolv_up "$dns"
						applied="$dns"
						warned=""
						echo "aTrust DNS: using $dns via $VPN_TUN" >&2
						restart_vpn_proxies
					else
						ip route del "$dns/32" dev "$VPN_TUN" 2>/dev/null
						[ -z "$warned" ] && {
							warned=1
							echo "aTrust DNS: $dns unreachable via $VPN_TUN, waiting" >&2
						}
						dns=""
					fi
				fi
				[ -z "$dns" ] && [ -z "$warned" ] && {
					warned=1
					echo "aTrust DNS: no usable inner DNS in $log, keeping Docker DNS."\
					     "The log format may have changed after a Sangfor upgrade." >&2
				}
			fi
		elif [ -n "$applied" ]; then
			if [ -e /run/resolv.conf.orig ]; then
				cat /run/resolv.conf.orig > /etc/resolv.conf
			else
				printf 'nameserver 127.0.0.11\noptions ndots:0\n' > /etc/resolv.conf
			fi
			ip route del "$applied/32" dev "$VPN_TUN" 2>/dev/null
			echo "aTrust DNS: VPN down, restored original resolver" >&2
			applied=""
			warned=""
			fails=0
			degraded=0
		fi
		sleep 5
	done
}

# 定期清理 aTrust 的轮转日志。/root 是持久化 volume，aTrust 自身的轮转
# （每个文件 ~21MB、保留多份 + 按日期命名）会在宿主机上无限累积。
# 只删两类文件：*.N.log（轮转）与 *.back（备份），当前活跃的 *.log 不动。
# VPN_LOG_KEEP_HOURS：旧文件保留时长（小时，按 mtime），默认 72；设 0 关闭。
prune_vpn_logs() {
	[ "ATRUST" = "$_VPN_TYPE" ] || return 0
	local keep="${VPN_LOG_KEEP_HOURS:-72}"
	[ "$keep" = "0" ] && return 0
	while :; do
		find /root/.aTrust/logs /root/.aTrust/aTrust/logs -type f \
			\( -name "*.[0-9]*.log" -o -name "*.back" -o -name "*.log.20*" \) \
			-mmin +$((keep * 60)) -delete 2>/dev/null
		sleep 21600
	done
}

# container 再次运行时清除 /tmp 中的锁，使 container 能够反复使用。
# 感谢 @skychan https://github.com/Hagb/docker-easyconnect/issues/4#issuecomment-660842149
for f in /tmp/* /tmp/.*; do
	[ "/tmp/.X11-unix" != "$f" ] && rm -rf -- "$f"
done

ulimit -n 1048576 # https://github.com/Hagb/docker-easyconnect/issues/245 @rikaunite
forward_ports &
start_danted &
start_tinyproxy &
config_vpn_iptables &
# open_tun_route 是常驻循环（等 tun 设备就绪，并在 VPN 重连后补回规则），必须 disown：
# 否则下面那个 wait 会一直等它，start-sangfor.sh 永远不会执行，VPN 客户端起不来。
open_tun_route &
disown
# open_vpn_dns 同样是常驻循环，必须 disown，否则会阻塞后面的 wait。
open_vpn_dns &
disown
force_open_ports &
keep_pinging &
keep_pinging_url &
prune_vpn_logs &
disown
if [ -z "$DISPLAY" ]
then
	export DISPLAY=:1
	start_tigervncserver &
fi

# 环境变量 CHROMIUM 不为空时，删除可能存在的锁，并启动 chromium
if [ -n "$CHROMIUM" ]; then
    rm -rf /root/.config/chromium/
    bash -c "chromium --no-sandbox" &
    disown
fi

init_vpn_config
wait

[ -n "$EXIT" ] && export MAX_RETRY=0
start-sangfor.sh &
wait $!

if [ "EC_GUI" = "$_VPN_TYPE" ]; then
	sync_ec2volume
fi
