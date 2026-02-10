#!/bin/bash
CONFIG_DIR="/opt/CherryScript/gost"
CONFIG_FILE="$CONFIG_DIR/forwards.conf"
ENV_FILE="$CONFIG_DIR/env"
SERVICE_FILE="/etc/systemd/system/Cherry-gost-forward.service"

Yellow='\033[33m'
White='\033[0m'
Green='\033[0;32m'
Blue='\033[0;34m'
Red='\033[31m'
Gray='\e[37m'
LightBlue='\033[96m'
DarkYellow='\033[93m'

# ===========================
# 安装 Gost
# ===========================
install_gost() {
    bash <(curl -fsSL https://github.com/go-gost/gost/raw/master/install.sh) --install
}

# ===========================
# 生成 env
# ===========================
generate_env() {
    ARGS=""
    while IFS= read -r line; do
        [ -n "$line" ] && ARGS="$ARGS $line"
    done < "$CONFIG_FILE"
    echo "ARGS=\"$ARGS\"" > "$ENV_FILE"
}

# ===========================
# 生成 systemd 服务
# ===========================
generate_service() {
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=GOST TCP+UDP Port Forwarder
After=network.target

[Service]
Type=simple
EnvironmentFile=$ENV_FILE
ExecStart=gost \$ARGS
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable Cherry-gost-forward
    systemctl start Cherry-gost-forward
    echo "服务已生成并启动: Cherry-gost-forward"
}

# ===========================
# 校验函数
# ===========================
validate_ip() {
    local ip=$1
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        for octet in $(echo "$ip" | tr '.' ' '); do
            ((octet>=0 && octet<=255)) || return 1
        done
        return 0
    elif [[ "$ip" =~ ^([0-9a-fA-F]{0,4}:){2,7}[0-9a-fA-F]{0,4}$ ]]; then
        return 0
    else
        return 1
    fi
}

validate_port() {
    local port=$1
    [[ "$port" =~ ^[0-9]+$ ]] && ((port>=0 && port<=65535))
}

# ===========================
# 解析规则
# ===========================
parse_rule() {
    local line="$1"
    line="${line#-L tcp://:}"
    local LPORT="${line%%/*}"
    local tmp="${line#*/}"
    local RIP="${tmp%%:*}"
    local RPORT="${tmp##*:}"
    echo "$LPORT|$RIP|$RPORT"
}

list_rules() {
    echo ""
    echo -e "----- 当前转发规则 ${White}-----${White}"
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "没有任何规则"
        echo "------------------------"
        return
    fi
    i=1
    echo
    while IFS= read -r line; do
        parsed=$(parse_rule "$line")
        LPORT=$(echo "$parsed" | cut -d '|' -f1)
        RIP=$(echo "$parsed" | cut -d '|' -f2)
        RPORT=$(echo "$parsed" | cut -d '|' -f3)
        printf "[%d] 本地 %s - 远程 %s:%s \n" "$i" "$LPORT" "$RIP" "$RPORT"
        i=$((i+1))
    done < "$CONFIG_FILE"
    echo
    echo "------------------------"
}

# ===========================
# 添加规则
# ===========================
add_rule() {
    while true; do
        read -p "输入本机监听端口: " LPORT
        validate_port "$LPORT" || { echo -e "${Red}本地端口无效${White}"; continue; }
        port_in_use "$LPORT" && { echo -e "${Red}本地端口无效${White}"; continue; }
        read -p "输入目标 IP: " RIP
        validate_ip "$RIP" || { echo -e "${Red}IP 地址无效${White}"; continue; }
        read -p "输入目标端口: " RPORT
        validate_port "$RPORT" || { echo -e "${Red}目标端口无效${White}"; continue; }
        RULE="-L tcp://:${LPORT}/${RIP}:${RPORT}"
        echo "$RULE" >> "$CONFIG_FILE"
        echo "已添加规则: 本地 $LPORT : $RIP:$RPORT"
        generate_env
        systemctl restart Cherry-gost-forward
        break
    done
}

delete_rule() {
    if [ ! -s "$CONFIG_FILE" ]; then
        echo "没有规则可删除"
        return
    fi
    list_rules
    read -p "请输入要删除的规则序号: " ID
    sed -i "${ID}d" "$CONFIG_FILE"
    echo "已删除规则编号 $ID"
    generate_env
    systemctl restart Cherry-gost-forward
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

port_in_use() {
	local p="$1"
	if have_cmd ss; then
		ss -lntp 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$" && return 0
	elif have_cmd netstat; then
		netstat -lntp 2>/dev/null | awk '{print $4}' | grep -Eq "[:.]${p}$" && return 0
	fi
	return 1
}

delete_all() {
    echo "将删除所有规则并卸载服务"
    read -p "确认？(y/N): " yn
    [[ -z "${yn}" ]] && yn="n"
	if [[ ${yn} == [Yy] ]]; then
        systemctl stop Cherry-gost-forward 2>/dev/null
        systemctl disable Cherry-gost-forward 2>/dev/null
        rm -f "$SERVICE_FILE" "$CONFIG_FILE" "$ENV_FILE"
        systemctl daemon-reload
        echo "已删除服务和所有配置"
    else
        echo "已取消"; return;
    fi
}

break_end() {
	echo -e "${Green}操作完成, 按任意键继续...${White}"
	read -n 1 -s -r -p ""
	echo ""
	clear
}
menu() {
    echo "------------------------"
    echo -e "GOST 管理脚本"
    echo "------------------------"
    echo "1. 添加转发规则"
    echo "2. 查看当前规则"
    echo "3. 删除单条规则"
    echo "4. 重启服务"
    echo "5. 卸载服务"
    echo "------------------------"
    echo "0. 退出"
    echo "------------------------"
    echo -n "请选择: "
}

# ===========================
# 主程序
# ===========================
clear
mkdir -p "$CONFIG_DIR"
(command -v gost >/dev/null 2>&1) || install_gost
[ ! -f "$CONFIG_FILE" ] && touch "$CONFIG_FILE"
generate_env

while true; do
    menu
    read CHOICE
    case "$CHOICE" in
        1) [ ! -f "$SERVICE_FILE" ] && generate_service; add_rule ; break_end; ;;
        2) list_rules ; break_end; ;;
        3) delete_rule ; break_end; ;;
        4) systemctl restart Cherry-gost-forward; echo "服务已重启" ; break_end; ;;
        5) delete_all ; break_end; ;;
        0) exit 0 ;;
        *) echo "无效选项, 请重新输入：" ;;
    esac
done
