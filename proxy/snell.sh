#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH


sh_ver="1.2.1 build261112"
# 各协议版本对应的官方 snell-server 版本
SNELL_V5_VERSION="v5.0.1"
SNELL_V6_VERSION="v6.0.0"
SNELL_VERSION="${SNELL_V5_VERSION}"
filepath=$(cd "$(dirname "$0")"; pwd)
file_1=$(echo -e "${filepath}"|awk -F "$0" '{print $1}')
FOLDER="/etc/snell/"
BIN_DIR="/usr/local/bin"
SERVICE_DIR="/etc/systemd/system"
Local="/etc/sysctl.d/local.conf"

# v5 和 v6 各自一套 程序/配置/服务，可以同时安装、同时运行。
# v5 沿用原有路径，旧版本脚本安装的实例可直接接管。
use_slot(){
	SLOT=$1
	if [[ "${SLOT}" == "6" ]]; then
		FILE="${BIN_DIR}/snell-server-v6"
		CONF="${FOLDER}config-v6.conf"
		Now_ver_File="${FOLDER}ver-v6.txt"
		SERVICE="snell-server-v6"
		SNELL_VERSION="${SNELL_V6_VERSION}"
	else
		SLOT=5
		FILE="${BIN_DIR}/snell-server"
		CONF="${FOLDER}config.conf"
		Now_ver_File="${FOLDER}ver.txt"
		SERVICE="snell-server"
		SNELL_VERSION="${SNELL_V5_VERSION}"
	fi
	ver=${SLOT}
}
use_slot 5

slot_installed(){
	if [[ "$1" == "6" ]]; then
		[[ -e "${BIN_DIR}/snell-server-v6" ]]
	else
		[[ -e "${BIN_DIR}/snell-server" ]]
	fi
}

#另一个已安装实例占用的端口(未安装则为空)
other_slot_port(){
	local other=6 conf="${FOLDER}config-v6.conf"
	[[ "${SLOT}" == "6" ]] && other=5 && conf="${FOLDER}config.conf"
	slot_installed ${other} && [[ -e "${conf}" ]] || return 0
	grep -E '^listen *=' "${conf}" | head -1 | sed 's/.*://' | tr -d '\r '
}

#选择要操作的已安装实例；都装了才询问
Choose_installed(){
	local has5=0 has6=0 pick
	slot_installed 5 && has5=1
	slot_installed 6 && has6=1
	if [[ ${has5} == 0 && ${has6} == 0 ]]; then
		echo -e "${Error} Snell Server 没有安装，请检查 !" && exit 1
	elif [[ ${has5} == 1 && ${has6} == 1 ]]; then
		echo -e "请选择要操作的 Snell 实例
==================================
${Green_font_prefix} 1.${Font_color_suffix} Snell v5
${Green_font_prefix} 2.${Font_color_suffix} Snell v6
=================================="
		read -e -p "(默认：1.v5)：" pick
		[[ "${pick}" == "2" ]] && use_slot 6 || use_slot 5
	elif [[ ${has6} == 1 ]]; then
		use_slot 6
	else
		use_slot 5
	fi
}

Green_font_prefix="\033[32m" && Red_font_prefix="\033[31m" && Green_background_prefix="\033[42;37m" && Red_background_prefix="\033[41;37m" && Font_color_suffix="\033[0m" && Yellow_font_prefix="\033[0;33m"
Info="${Green_font_prefix}[信息]${Font_color_suffix}"
Error="${Red_font_prefix}[错误]${Font_color_suffix}"
Tip="${Yellow_font_prefix}[注意]${Font_color_suffix}"

check_root(){
	[[ $EUID != 0 ]] && echo -e "${Error} 当前非ROOT账号(或没有ROOT权限)，无法继续操作，请更换ROOT账号或使用 ${Green_background_prefix}sudo su${Font_color_suffix} 命令获取临时ROOT权限（执行后可能会提示输入当前账号的密码）。" && exit 1
}
#检查系统
check_sys(){
	if [[ -f /etc/redhat-release ]]; then
		release="centos"
	elif cat /etc/issue | grep -q -E -i "debian"; then
		release="debian"
	elif cat /etc/issue | grep -q -E -i "ubuntu"; then
		release="ubuntu"
	elif cat /etc/issue | grep -q -E -i "centos|red hat|redhat"; then
		release="centos"
	elif cat /proc/version | grep -q -E -i "debian"; then
		release="debian"
	elif cat /proc/version | grep -q -E -i "ubuntu"; then
		release="ubuntu"
	elif cat /proc/version | grep -q -E -i "centos|red hat|redhat"; then
		release="centos"
    fi
}

open_firewall_port() {
    ufw allow $1 > /dev/null 2>&1
    firewall-cmd --permanent --add-port=$1 > /dev/null 2>&1
    sed -i "/COMMIT/i -A INPUT -p tcp --dport $1 -j ACCEPT" /etc/iptables/rules.v4 > /dev/null 2>&1
    sed -i "/COMMIT/i -A INPUT -p udp --dport $1 -j ACCEPT" /etc/iptables/rules.v4 > /dev/null 2>&1
    iptables-restore < /etc/iptables/rules.v4 > /dev/null 2>&1
}

Installation_dependency(){
	if [[ ${release} == "centos" ]]; then
		yum update && yum install gzip wget curl unzip -y
	else
		apt-get update && apt-get install gzip wget curl unzip -y
	fi
	sysctl -w net.core.rmem_max=26214400
	sysctl -w net.core.rmem_default=26214400
	\cp -f /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
}

#检查系统内核版本
sysArch() {
    uname=$(uname -m)
    if [[ "$uname" == "i686" ]] || [[ "$uname" == "i386" ]]; then
        arch="i386"
    elif [[ "$uname" == *"armv7"* ]] || [[ "$uname" == "armv6l" ]]; then
        arch="armv7l"
    elif [[ "$uname" == *"armv8"* ]] || [[ "$uname" == "aarch64" ]]; then
        arch="aarch64"
    else
        arch="amd64"
    fi    
}

#开启系统 TCP Fast Open
enable_systfo() {
	kernel=$(uname -r | awk -F . '{print $1}')
	if [ "$kernel" -ge 3 ]; then
		echo 3 >/proc/sys/net/ipv4/tcp_fastopen
		[[ ! -e $Local ]] && echo "fs.file-max = 51200
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.rmem_default = 65536
net.core.wmem_default = 65536
net.core.netdev_max_backlog = 4096
net.core.somaxconn = 4096
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 0
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.ip_local_port_range = 10000 65000
net.ipv4.tcp_max_syn_backlog = 4096
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_rmem = 4096 87380 67108864
net.ipv4.tcp_wmem = 4096 65536 67108864
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control = bbr" >>/etc/sysctl.d/local.conf && sysctl --system >/dev/null 2>&1
	else
		echo -e "$Error系统内核版本过低，无法支持 TCP Fast Open ！"
		tfo=false
	fi
}

check_installed_status(){
	[[ ! -e ${FILE} ]] && echo -e "${Error} Snell Server 没有安装，请检查 !" && exit 1
}

check_status(){
	status=`systemctl status ${SERVICE} 2>/dev/null | grep Active | awk '{print $3}' | cut -d "(" -f2 | cut -d ")" -f1`
}


# Snell 官方源
Snell_Download(){
	echo -e "${Info} 试图请求${Yellow_font_prefix}${SNELL_VERSION} 官网源版${Font_color_suffix}Snell Server ……"
	wget --no-check-certificate -N "https://dl.nssurge.com/snell/snell-server-${SNELL_VERSION}-linux-${arch}.zip"
	if [[ ! -e "snell-server-${SNELL_VERSION}-linux-${arch}.zip" ]]; then
		echo -e "${Error} Snell Server${Yellow_font_prefix}${SNELL_VERSION} 官网源版${Font_color_suffix}下载失败！"
		return 1
	else
		unzip -o "snell-server-${SNELL_VERSION}-linux-${arch}.zip"
	fi
	if [[ ! -e "snell-server" ]]; then
		echo -e "${Error} Snell Server${Yellow_font_prefix}${SNELL_VERSION} 官网源版${Font_color_suffix}解压失败 !"
		echo -e "${Error} Snell Server${Yellow_font_prefix}${SNELL_VERSION} 官网源版${Font_color_suffix}安装失败 !"
		return 1
	else
		rm -rf "snell-server-${SNELL_VERSION}-linux-${arch}.zip"
		chmod +x snell-server
		mv -f snell-server "${FILE}"
		echo "${SNELL_VERSION}" > ${Now_ver_File}
		echo -e "${Info} Snell Server 主程序下载安装完毕！"
		return 0
	fi
}

# 安装
Install() {
	[[ ! -e "${FOLDER}" ]] && mkdir "${FOLDER}"
	Install_snell

	rm -f "snell-server-${SNELL_VERSION}-linux-${arch}.zip"

}

Service(){
	cat > "${SERVICE_DIR}/${SERVICE}.service"<<-EOF

[Unit]
Description= Snell v${SLOT} Service
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service
[Service]
LimitNOFILE=32767
Type=simple
User=root
Restart=on-failure
RestartSec=5s
ExecStartPre=/bin/sh -c 'ulimit -n 51200'
ExecStart=${FILE} -c ${CONF}
[Install]
WantedBy=multi-user.target
EOF
	systemctl daemon-reload
	systemctl enable --now ${SERVICE}
	echo -e "${Info} Snell Server v${SLOT} 服务配置完成 !"
}

#系统是否可用 IPv6
ipv6_available(){
	[[ -s /proc/net/if_inet6 ]] && [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6 2>/dev/null)" != "1" ]]
}

#v6 官方没有提供 armv7l 版本
check_arch_support(){
	if [[ "${SLOT}" == "6" && "${arch}" == "armv7l" ]]; then
		echo -e "${Error} Snell v6 官方未提供 armv7l 架构的服务端，请选择 v5 !"
		return 1
	fi
	return 0
}

Select_version(){
	local s5="" s6=""
	slot_installed 5 && s5=" [已安装]"
	slot_installed 6 && s6=" [已安装]"
	echo -e "请选择要安装的 Snell 版本 (v5 和 v6 可以同时安装、同时运行)
==================================
${Green_font_prefix} 1.${Font_color_suffix} v5 (${SNELL_V5_VERSION})${s5}
${Green_font_prefix} 2.${Font_color_suffix} v6 (${SNELL_V6_VERSION})${s6}
=================================="
	read -e -p "(默认：1.v5)：" ver_num
	[[ "${ver_num}" == "2" ]] && use_slot 6 || use_slot 5
	echo && echo "=================================="
	echo -e "Snell 版本：${Red_background_prefix} v${ver} (${SNELL_VERSION}) ${Font_color_suffix}"
	echo "==================================" && echo
}

Write_config(){
	if [[ "${SLOT}" == "6" ]]; then
		local listen="0.0.0.0:${port}"
		ipv6_available && listen="${listen},[::]:${port}"
		cat > ${CONF}<<-EOF
[snell-server]
mode = ${mode:-default}
listen = ${listen}
psk = ${psk}
dns-ip-preference = ${dnspref:-default}
EOF
	else
		cat > ${CONF}<<-EOF
[snell-server]
listen = ::0:${port}
ipv6 = ${ipv6:-true}
psk = ${psk}
obfs = ${obfs:-off}
obfs-host = ${host:-icloud.com}
tfo = ${tfo:-true}
version = ${ver}
EOF
	fi
}
#读取配置文件中某一项的值
conf_get(){
	grep -E "^$1 *=" ${CONF} | head -1 | sed -E "s/^$1 *= *//" | tr -d '\r'
}
Read_config(){
	[[ ! -e ${CONF} ]] && echo -e "${Error} Snell Server 配置文件不存在 !" && exit 1
	local listen=$(conf_get listen)
	port=${listen##*:}
	psk=$(conf_get psk)
	ipv6=$(conf_get ipv6)
	obfs=$(conf_get obfs)
	host=$(conf_get obfs-host)
	tfo=$(conf_get tfo)
	mode=$(conf_get mode)
	dnspref=$(conf_get dns-ip-preference)
	if [[ "${SLOT}" == "6" ]]; then
		# v6 配置文件中没有 version 项
		ver=6
		[[ -z "${mode}" ]] && mode=default
		[[ -z "${dnspref}" ]] && dnspref=default
	else
		ver=$(conf_get version)
		[[ -z "${ver}" ]] && ver=5
	fi
}

rand() { 
 min=$1 
 max=$(($2-$min+1)) 
 num=$(($RANDOM+$RANDOM+$RANDOM+1000000000)) #增加一个10位的数再求余 
 echo $(($num%$max+$min)) 
} 

Set_port(){
	while true
		do
		echo -e "${Info} 本步骤会对系统防火墙(ufw/firewalld)进行端口放行操作，请注意安全性！"
		echo -e "请输入 Snell Server 端口${Yellow_font_prefix}[1-65535]${Font_color_suffix}"
		read -e -p "(默认随机):" port
		[[ -z "${port}" ]] && port=$(rand 10000 59999) 
		echo $((${port}+0)) &>/dev/null
		if [[ $? -eq 0 ]]; then
			if [[ ${port} -ge 1 ]] && [[ ${port} -le 65535 ]]; then
				if [[ "${port}" == "$(other_slot_port)" ]]; then
					echo "端口 ${port} 已被另一个 Snell 实例占用, 请换一个端口。"
					continue
				fi
				open_firewall_port ${port}
				echo && echo "=============================="
				echo -e "端口 : ${port} "
				echo "==============================" && echo
				break
			else
				echo "输入错误, 请输入正确的端口。"
			fi
		else
			echo "输入错误, 请输入正确的端口。"
		fi
		done
}

Set_ipv6_init(){
	ipv6=true
}

Set_ipv6(){
	echo -e "是否开启 IPv6 解析 ？
==================================
${Green_font_prefix} 1.${Font_color_suffix} 开启  ${Green_font_prefix} 2.${Font_color_suffix} 关闭
=================================="
	read -e -p "(默认：1.开启)：" ipv6
	[[ -z "${ipv6}" ]] && ipv6="1"
	if [[ ${ipv6} == "1" ]]; then
		ipv6=true
	else
		ipv6=false
	fi
	echo && echo "=================================="
	echo -e "IPv6 解析 开启状态：${Red_background_prefix} ${ipv6} ${Font_color_suffix}"
	echo "==================================" && echo
}

Set_psk_init(){
	psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
}

Set_psk(){
	echo "请输入 Snell Server 密钥${Yellow_font_prefix}[0-9][a-z][A-Z]${Font_color_suffix}"
	read -e -p "(默认: 随机生成):" psk
	[[ -z "${psk}" ]] && psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
	# Snell v6 要求密钥长度为 12-255
	while [[ "${SLOT}" == "6" ]] && (( ${#psk} < 12 || ${#psk} > 255 )); do
		echo "Snell v6 的密钥长度必须在 12-255 之间, 请重新输入。"
		read -e -p "(默认: 随机生成):" psk
		[[ -z "${psk}" ]] && psk=$(tr -dc A-Za-z0-9 </dev/urandom | head -c 20)
	done
	echo && echo "=============================="
	echo -e "密钥 : ${Red_background_prefix} ${psk} ${Font_color_suffix}"
	echo "==============================" && echo
}

Set_obfs_init(){
	obfs=off
}

Set_obfs(){
	echo -e "配置 OBFS
==================================
${Green_font_prefix} 1.${Font_color_suffix} HTTP ${Green_font_prefix} 2.${Font_color_suffix} 关闭
=================================="
	read -e -p "(默认：2.HTTP)：" obfs
	[[ -z "${obfs}" ]] && obfs="2"
	if [[ ${obfs} == "1" ]]; then
		obfs=http
	elif [[ ${obfs} == "2" ]]; then
		obfs=off
	else
		obfs=off
	fi
	echo && echo "=================================="
	echo -e "OBFS 状态：${Red_background_prefix} ${obfs} ${Font_color_suffix}"
	echo "==================================" && echo
}

Set_mode(){
	echo -e "配置 Snell v6 模式 (客户端与服务端必须一致)
==================================
${Green_font_prefix} 1.${Font_color_suffix} default    流量混淆 + AES 加密
${Green_font_prefix} 2.${Font_color_suffix} unshaped   仅 AES 加密，无混淆
${Green_font_prefix} 3.${Font_color_suffix} unsafe-raw 明文传输，仅限内网/已有安全隧道
=================================="
	read -e -p "(默认：1.default)：" mode
	case "${mode}" in
		2) mode=unshaped ;;
		3) mode=unsafe-raw ;;
		*) mode=default ;;
	esac
	echo && echo "=================================="
	echo -e "模式：${Red_background_prefix} ${mode} ${Font_color_suffix}"
	echo "==================================" && echo
}

Set_dnspref(){
	echo -e "配置 DNS IP 偏好 (dns-ip-preference)
==================================
${Green_font_prefix} 1.${Font_color_suffix} default
${Green_font_prefix} 2.${Font_color_suffix} prefer-ipv4
${Green_font_prefix} 3.${Font_color_suffix} prefer-ipv6
${Green_font_prefix} 4.${Font_color_suffix} ipv4-only
${Green_font_prefix} 5.${Font_color_suffix} ipv6-only
=================================="
	read -e -p "(默认：1.default)：" dnspref
	case "${dnspref}" in
		2) dnspref=prefer-ipv4 ;;
		3) dnspref=prefer-ipv6 ;;
		4) dnspref=ipv4-only ;;
		5) dnspref=ipv6-only ;;
		*) dnspref=default ;;
	esac
	echo && echo "=================================="
	echo -e "DNS IP 偏好：${Red_background_prefix} ${dnspref} ${Font_color_suffix}"
	echo "==================================" && echo
}

Set_host_init(){
	host=icloud.com
}

Set_host(){
	echo "请输入 Snell Server 域名 "
	read -e -p "(默认: icloud.com):" host
	[[ -z "${host}" ]] && host=icloud.com
	echo && echo "=============================="
	echo -e "	域名 : ${Red_background_prefix} ${host} ${Font_color_suffix}"
	echo "==============================" && echo
}

Set_tfo(){
	tfo=true
	enable_systfo
}

Set(){
	Choose_installed
	Read_config
	if [[ "${SLOT}" == "6" ]]; then
		echo && echo -e "你要做什么？(当前 Snell v6)
==============================
 ${Green_font_prefix}1.${Font_color_suffix}  修改 端口
 ${Green_font_prefix}2.${Font_color_suffix}  修改 密钥
 ${Green_font_prefix}3.${Font_color_suffix}  配置 模式
 ${Green_font_prefix}4.${Font_color_suffix}  配置 DNS IP 偏好
==============================
 ${Green_font_prefix}6.${Font_color_suffix}  修改 全部配置" && echo
		read -e -p "(默认: 取消):" modify
		[[ -z "${modify}" ]] && echo "已取消..." && exit 1
		case "${modify}" in
			1) Set_port ;;
			2) Set_psk ;;
			3) Set_mode ;;
			4) Set_dnspref ;;
			6)
			Set_port
			Set_psk
			Set_mode
			Set_dnspref
			;;
			*) echo -e "${Error} 请输入正确的数字${Yellow_font_prefix}[1-6]${Font_color_suffix}" && exit 1 ;;
		esac
	else
		echo && echo -e "你要做什么？(当前 Snell v${ver})
==============================
 ${Green_font_prefix}1.${Font_color_suffix}  修改 端口
 ${Green_font_prefix}2.${Font_color_suffix}  修改 密钥
 ${Green_font_prefix}3.${Font_color_suffix}  配置 OBFS
 ${Green_font_prefix}4.${Font_color_suffix}  配置 OBFS 域名
 ${Green_font_prefix}5.${Font_color_suffix}  开关 IPv6 解析
==============================
 ${Green_font_prefix}6.${Font_color_suffix}  修改 全部配置" && echo
		read -e -p "(默认: 取消):" modify
		[[ -z "${modify}" ]] && echo "已取消..." && exit 1
		case "${modify}" in
			1) Set_port ;;
			2) Set_psk ;;
			3) Set_obfs ;;
			4) Set_host ;;
			5) Set_ipv6 ;;
			6)
			Set_port
			Set_psk
			Set_obfs
			Set_host
			Set_ipv6
			Set_tfo
			;;
			*) echo -e "${Error} 请输入正确的数字${Yellow_font_prefix}[1-6]${Font_color_suffix}" && exit 1 ;;
		esac
	fi
	Write_config
	systemctl restart ${SERVICE}
	echo -e "${Info} Snell Server v${SLOT} 重启完毕!"
	sleep 3s
	View
}

# 安装 (v5 / v6，互不影响，可同时安装)
Install_snell(){
	check_root
	echo -e "${Info} 开始设置 配置..."
	Select_version
	if slot_installed ${SLOT}; then
		echo -e "${Error} 检测到 Snell Server v${SLOT} 已安装 ,请先卸载再重新安装!"
		before_start_menu
		return
	fi
	check_arch_support || exit 1
	Set_port
	Set_psk_init
	if [[ "${SLOT}" == "6" ]]; then
		mode=default
		dnspref=default
	else
		Set_obfs_init
		Set_host_init
		Set_ipv6_init
		Set_tfo
	fi
	echo -e "${Info} 开始安装/配置 依赖..."
	Installation_dependency
	echo -e "${Info} 开始下载/安装 Snell ${SNELL_VERSION}..."
	Snell_Download || exit 1
	echo -e "${Info} 开始写入 配置文件..."
	Write_config
	echo -e "${Info} 开始安装 服务脚本..."
	Service
	echo -e "${Info} 所有步骤 安装完毕，开始启动..."
	check_installed_status
	systemctl restart ${SERVICE}
	check_status
	[[ "$status" == "running" ]] && echo -e "${Info} Snell Server v${SLOT} 启动成功 !"
	Get_subscribe_link
	echo "安装完成，以下是您的订阅链接"
	Show_subscribe_link save
	before_start_menu
}

Start(){
	Choose_installed
	check_status
	[[ "$status" == "running" ]] && echo -e "${Info} Snell Server v${SLOT} 已在运行 !" && exit 1
	systemctl start ${SERVICE}
	check_status
	[[ "$status" == "running" ]] && echo -e "${Info} Snell Server v${SLOT} 启动成功 !"
    sleep 3s
    start_menu
}
Stop(){
	Choose_installed
	check_status
	[[ !"$status" == "running" ]] && echo -e "${Error} Snell Server 没有运行，请检查 !" && exit 1
	systemctl stop ${SERVICE}
	echo -e "${Info} Snell Server v${SLOT} 停止成功 !"
    sleep 3s
    start_menu
}
Restart(){
	Choose_installed
	systemctl restart ${SERVICE}
	echo -e "${Info} Snell Server v${SLOT} 重启完毕!"
	sleep 3s
	View
    start_menu
}
Update(){
	check_installed_status
	echo -e "${Info} Snell Server 更新完毕 !"
    sleep 3s
    start_menu
}
Uninstall(){
	Choose_installed
	echo "确定要卸载 Snell Server v${SLOT} ? (y/N)"
	echo
	read -e -p "(默认: n):" unyn
	[[ -z ${unyn} ]] && unyn="n"
	if [[ ${unyn} == [Yy] ]]; then
		systemctl stop ${SERVICE}
        systemctl disable ${SERVICE}
		rm -rf "${FILE}"
		echo && echo "Snell Server v${SLOT} 卸载完成 !" && echo
	else
		echo && echo "卸载已取消..." && echo
	fi
    sleep 3s
    start_menu
}
getipv4(){
	ipv4=$(wget -qO- -4 -t1 -T2 ipinfo.io/ip)
	if [[ -z "${ipv4}" ]]; then
		ipv4=$(wget -qO- -4 -t1 -T2 api.ip.sb/ip)
		if [[ -z "${ipv4}" ]]; then
			ipv4=$(wget -qO- -4 -t1 -T2 members.3322.org/dyndns/getip)
			if [[ -z "${ipv4}" ]]; then
				ipv4="IPv4_Error"
			fi
		fi
	fi
}
getipv6(){
	ip6=$(wget -qO- -6 -t1 -T2 ifconfig.co)
	if [[ -z "${ip6}" ]]; then
		ip6="IPv6_Error"
	fi
}

# 查看配置：已安装的实例全部列出
View(){
	local s shown=0
	slot_installed 5 || slot_installed 6 || check_installed_status
	getipv6
	clear && echo
	for s in 5 6; do
		slot_installed ${s} || continue
		use_slot ${s}
		[[ ! -e ${CONF} ]] && echo -e "${Error} Snell Server v${s} 配置文件不存在 !" && continue
		View_one
		shown=1
	done
	[[ ${shown} == 0 ]] && exit 1
	before_start_menu
}

View_one(){
	Get_subscribe_link
	echo -e "Snell Server V${ver} 配置信息："
	echo -e "—————————————————————————"
	[[ "${ipv4}" != "IPv4_Error" ]] && echo -e " 地址\t: ${Green_font_prefix}${ipv4}${Font_color_suffix}"
	[[ "${ip6}" != "IPv6_Error" ]] && echo -e " 地址\t: ${Green_font_prefix}${ip6}${Font_color_suffix}"
	echo -e " 端口\t: ${Green_font_prefix}${port}${Font_color_suffix}"
	echo -e " 密钥\t: ${Green_font_prefix}${psk}${Font_color_suffix}"
	if [[ "${SLOT}" == "6" ]]; then
		echo -e " 模式\t: ${Green_font_prefix}${mode}${Font_color_suffix}"
		echo -e " DNS\t: ${Green_font_prefix}${dnspref}${Font_color_suffix}"
	else
		echo -e " OBFS\t: ${Green_font_prefix}${obfs}${Font_color_suffix}"
		echo -e " 域名\t: ${Green_font_prefix}${host}${Font_color_suffix}"
		echo -e " IPv6\t: ${Green_font_prefix}${ipv6}${Font_color_suffix}"
		echo -e " TFO\t: ${Green_font_prefix}${tfo}${Font_color_suffix}"
	fi
	echo -e " VER\t: ${Green_font_prefix}${ver}${Font_color_suffix}"
	echo -e "—————————————————————————"
	echo "以下是您的订阅链接"
	Show_subscribe_link
	echo
}

# 输出订阅链接，参数为 save 时同时追加写入 ~/Proxy.txt
Show_subscribe_link(){
	local line
	for line in "CLASH: ${clash_link}" "SURGE: ${surge_link}" "Shadowrocket: ${shadowrocket_link}"; do
		# 该版本没有的链接留空，跳过
		[[ "${line}" == *": " ]] && continue
		echo "${line}"
		[[ "$1" == "save" ]] && echo "${line}" >> ~/Proxy.txt
	done
	return 0
}

Get_subscribe_link(){
	check_installed_status
	Read_config
	getipv4
	country=$(curl -s ipinfo.io/country)
	hostname=$(hostname)
	node_name="${country}-${hostname}"
	if [[ "${SLOT}" == "6" ]]; then
		# 与 v5 节点同时存在时避免重名
		node_name="${node_name}-v6"
		# mihomo (Clash Meta) proxies 条目
		clash_link="{name: ${node_name}, type: snell, server: ${ipv4}, port: ${port}, psk: ${psk}, version: 6, mode: ${mode}, reuse: true}"
		surge_link="${node_name} = snell, ${ipv4}, ${port}, psk=${psk}, version=6, mode=${mode}, reuse=true"
		# Shadowrocket 暂不支持 v6，不生成
		shadowrocket_link=""
		return
	fi
	shadowrocket_userinfo=$(printf "%s" "chacha20-ietf-poly1305:${psk}" | base64 | tr -d '\n')
	clash_link="{name: ${node_name}, type: snell, server: ${ipv4}, port: ${port}, psk: ${psk}, version: '${ver}'}"
	surge_link="${node_name} = snell, ${ipv4}, ${port}, psk=${psk}, version=${ver}, reuse=true, tfo=${tfo}, ip-version=prefer-v4"
	shadowrocket_link="snell://${shadowrocket_userinfo}@${ipv4}:${port}?version=${ver}&reuse=1#${node_name}"
}

Status(){
	Choose_installed
	echo -e "${Info} 获取 Snell Server 活动日志 ……"
	echo -e "${Tip} 返回主菜单请按 q ！"
	systemctl status ${SERVICE}
	start_menu
}

Update_Shell(){
	local sh_url="https://raw.githubusercontent.com/railzen/cherry-script/main/proxy/snell.sh"
	local sh_tmp="/tmp/cherry_snell.sh"
	echo -e "当前版本为 [ ${sh_ver} ]，开始检测最新版本..."
	sh_new_ver=$(wget --no-check-certificate -qO- "${sh_url}"|grep 'sh_ver="'|awk -F "=" '{print $NF}'|sed 's/\"//g'|head -1)
	[[ -z ${sh_new_ver} ]] && echo -e "${Error} 检测最新版本失败 !" && before_start_menu
	if [[ ${sh_new_ver} != ${sh_ver} ]]; then
		echo -e "发现新版本[ ${sh_new_ver} ]，是否更新？[Y/n]"
		read -p "(默认: y):" yn
		[[ -z "${yn}" ]] && yn="y"
		if [[ ${yn} == [Yy] ]]; then
			if wget -qO "${sh_tmp}" --no-check-certificate "${sh_url}" && grep -q 'sh_ver="' "${sh_tmp}"; then
				chmod +x "${sh_tmp}"
				echo -e "脚本已更新为最新版本[ ${sh_new_ver} ] !"
				echo -e "3s后执行新脚本"
				sleep 3s
				exec bash "${sh_tmp}"
			else
				rm -f "${sh_tmp}"
				echo -e "${Error} 下载最新脚本失败 !"
				before_start_menu
			fi
		else
			echo && echo "	已取消..." && echo
			sleep 3s
			start_menu
		fi
	else
		echo -e "当前已是最新版本[ ${sh_new_ver} ] !"
		sleep 3s
		start_menu
	fi
}
before_start_menu() {
    echo && echo -n -e "${Yellow_font_prefix}按任意键返回主菜单...${Font_color_suffix}" && read -n 1 -s -r -p ""
    start_menu
}

start_menu(){
clear
check_root
check_sys
sysArch
action=$1
	echo && echo -e "  
==============================
Snell Server 管理脚本 $sh_ver 
==============================
 ${Green_font_prefix} 1.${Font_color_suffix} 安装 Snell Server
 ${Green_font_prefix} 2.${Font_color_suffix} 卸载 Snell Server
——————————————————————————————
 ${Green_font_prefix} 3.${Font_color_suffix} 启动 Snell Server
 ${Green_font_prefix} 4.${Font_color_suffix} 停止 Snell Server
 ${Green_font_prefix} 5.${Font_color_suffix} 重启 Snell Server
——————————————————————————————
 ${Green_font_prefix} 6.${Font_color_suffix} 设置 配置信息
 ${Green_font_prefix} 7.${Font_color_suffix} 查看 配置信息
 ${Green_font_prefix} 8.${Font_color_suffix} 查看 运行状态
——————————————————————————————
 ${Green_font_prefix} 9.${Font_color_suffix} 更新脚本
——————————————————————————————
 ${Green_font_prefix} 0.${Font_color_suffix} 退出脚本
==============================" && echo
	local s
	for s in 5 6; do
		use_slot ${s}
		if [[ -e ${FILE} ]]; then
			check_status
			if [[ "$status" == "running" ]]; then
				echo -e " Snell v${s}:  ${Green_font_prefix}已安装${Font_color_suffix} 并 ${Green_font_prefix}已启动${Font_color_suffix}"
			else
				echo -e " Snell v${s}:  ${Green_font_prefix}已安装${Font_color_suffix} 但 ${Red_font_prefix}未启动${Font_color_suffix}"
			fi
		else
			echo -e " Snell v${s}:  ${Red_font_prefix}未安装${Font_color_suffix}"
		fi
	done
	use_slot 5
	echo
	read -e -p " 请输入数字[0-9]:" num
	case "$num" in
		1)
		Install
		;;
		2)
		Uninstall
		;;
		3)
		Start
		;;
		4)
		Stop
		;;
		5)
		Restart
		;;
		6)
		Set
		;;
		7)
		View
		;;
		8)
		Status
		;;
		9)
		Update_Shell
		;;
		0)
		exit 1
		;;
		*)
		echo "请输入正确数字${Yellow_font_prefix}[0-9]${Font_color_suffix}"
		;;
	esac
}

start_menu
