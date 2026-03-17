#!/bin/bash
# =============================================================================
# Скрипт проверки Модуля 1: SSH Fallback (v11.1 - Исправлены кавычки)
# КОД 09.02.06-1-2026
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# =============================================================================
# ⚙️ КОНФИГУРАЦИЯ
# =============================================================================

DOMAIN="au-team.irpo"
DNS_SERVER_IP="192.168.100.2"
ROOT_PASS='P@$$w0rd'
SSHUSER_PASS='P@ssw0rd'

declare -A VM_IDS=(
    ["ISP"]="10601"
    ["HQ-RTR"]="10602"
    ["HQ-SRV"]="10603"
    ["HQ-CLI"]="10604"
    ["BR-RTR"]="10605"
    ["BR-SRV"]="10606"
)

declare -A DEV_TYPE=(
    ["ISP"]="linux"
    ["HQ-RTR"]="ecorouter"
    ["HQ-SRV"]="linux"
    ["HQ-CLI"]="linux"
    ["BR-RTR"]="ecorouter"
    ["BR-SRV"]="linux"
)

declare -A VM_IPS=(
    ["ISP"]="172.16.1.1"
    ["HQ-RTR"]="172.16.1.2"
    ["HQ-SRV"]="192.168.100.2"
    ["HQ-CLI"]="192.168.200.2"
    ["BR-RTR"]="172.16.2.2"
    ["BR-SRV"]="192.168.0.2"
)

PORT_ROOT=22
PORT_SECURE=2026

TOTAL=0
PASSED=0
FAILED=0

LOG_FILE="/root/check_module1_$(date +%Y%m%d_%H%M%S).log"
JSON_FILE="/root/results_module1_$(date +%Y%m%d_%H%M%S).json"

# =============================================================================
# 📦 ФУНКЦИИ
# =============================================================================

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" >> "$LOG_FILE"
}

print_result() {
    local task="$1"
    local check="$2"
    local status="$3"
    local details="$4"
    
    ((TOTAL++))
    log "TASK:$task CHECK:$check STATUS:$status DETAILS:$details"
    
    if [[ "$status" == "PASS" ]]; then
        ((PASSED++))
        echo -e "${GREEN}[✓]${NC} Задание $task: $check"
    else
        ((FAILED++))
        echo -e "${RED}[✗]${NC} Задание $task: $check"
    fi
    if [[ -n "$details" ]]; then
        echo -e "    ${BLUE}ℹ️${NC} $details"
    fi
}

ssh_linux() {
    local host="$1"
    local cmd="$2"
    local port="${3:-$PORT_ROOT}"
    
    sshpass -p "$ROOT_PASS" ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null \
        -p "$port" root@"$host" "$cmd" 2>/dev/null
}

ssh_eco() {
    local host="$1"
    local cmd="$2"
    
    sshpass -p "$ROOT_PASS" ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=10 -o UserKnownHostsFile=/dev/null \
        root@"$host" "$cmd" 2>/dev/null
}

exec_cmd() {
    local vmname="$1"
    local cmd="$2"
    local ip="${VM_IPS[$vmname]}"
    local dtype="${DEV_TYPE[$vmname]}"
    
    if [[ "$dtype" == "ecorouter" ]]; then
        ssh_eco "$ip" "$cmd"
    else
        ssh_linux "$ip" "$cmd"
    fi
}

# =============================================================================
# ✅ ПРОВЕРКИ
# =============================================================================

check_hostname() {
    local vmname="$1"
    local dtype="${DEV_TYPE[$vmname]}"
    
    echo -e "\n${YELLOW}>>> Проверка hostname: $vmname${NC}"
    
    local cmd=""
    if [[ "$dtype" == "ecorouter" ]]; then
        cmd="show hostname"
    else
        cmd="hostname"
    fi
    
    local hn
    hn=$(exec_cmd "$vmname" "$cmd")
    
    if [[ -z "$hn" ]]; then
        print_result "1.1" "Hostname $vmname" "FAIL" "Не удалось получить hostname"
        return
    fi
    
    shopt -s nocasematch
    
    if [[ "$vmname" == "ISP" ]]; then
        if [[ "$hn" == isp* ]]; then
            print_result "1.1" "Hostname ISP" "PASS" "$hn"
        else
            print_result "1.1" "Hostname ISP" "FAIL" "Ожидается: isp (получено: $hn)"
        fi
    else
        local expected="${vmname,,}.$DOMAIN"
        if [[ "$hn" == *"$expected"* ]] || [[ "$hn" == "${vmname,,}"* ]] || \
           [[ "$hn" == *"hq-sru"* ]] || [[ "$hn" == *"hq-rtcr"* ]] || \
           [[ "$hn" == *"br-sru"* ]] || [[ "$hn" == *"br-rtcr"* ]]; then
            print_result "1.1" "Hostname $vmname" "PASS" "$hn"
        else
            print_result "1.1" "Hostname $vmname" "FAIL" "Ожидается: $expected (получено: $hn)"
        fi
    fi
    shopt -u nocasematch
}

check_ipv4() {
    local vmname="$1"
    local dtype="${DEV_TYPE[$vmname]}"
    
    echo -e "\n${YELLOW}>>> Проверка IPv4: $vmname${NC}"
    
    local cmd=""
    if [[ "$dtype" == "ecorouter" ]]; then
        cmd="show ip interface brief"
    else
        cmd="ip -br addr show"
    fi
    
    local ip_info
    ip_info=$(exec_cmd "$vmname" "$cmd")
    local expected_ip="${VM_IPS[$vmname]}"
    
    if [[ "$ip_info" == *"$expected_ip"* ]]; then
        print_result "1.2" "IPv4 $vmname" "PASS" "IP $expected_ip найден"
    else
        print_result "1.2" "IPv4 $vmname" "FAIL" "IP $expected_ip не найден"
    fi
}

check_isp_nat() {
    local vmname="ISP"
    
    echo -e "\n${YELLOW}>>> Проверка NAT на ISP${NC}"
    
    local nat
    nat=$(exec_cmd "$vmname" "iptables -t nat -L POSTROUTING -n 2>/dev/null")
    
    shopt -s nocasematch
    
    if [[ "$nat" == *"172.16.1.0/28"* ]] && [[ "$nat" == *"MASQUERADE"* ]]; then
        print_result "2.1" "NAT 172.16.1.0/28" "PASS" "Правило найдено"
    else
        print_result "2.1" "NAT 172.16.1.0/28" "FAIL" "Правило не найдено"
    fi
    
    if [[ "$nat" == *"172.16.2.0/28"* ]] && [[ "$nat" == *"MASQUERADE"* ]]; then
        print_result "2.2" "NAT 172.16.2.0/28" "PASS" "Правило найдено"
    else
        print_result "2.2" "NAT 172.16.2.0/28" "FAIL" "Правило не найдено"
    fi
    
    shopt -u nocasematch
}

check_isp_forwarding() {
    local vmname="ISP"
    
    echo -e "\n${YELLOW}>>> Проверка IP Forwarding: $vmname${NC}"
    
    local fwd
    fwd=$(exec_cmd "$vmname" "sysctl net.ipv4.ip_forward 2>/dev/null")
    
    if [[ "$fwd" == *"= 1"* ]] || [[ "$fwd" == "1" ]]; then
        print_result "2.3" "IP forwarding" "PASS" "Включён"
    else
        print_result "2.3" "IP forwarding" "FAIL" "Выключен"
    fi
}

check_isp_iptables_saved() {
    local vmname="ISP"
    
    echo -e "\n${YELLOW}>>> Проверка сохранения iptables: $vmname${NC}"
    
    local saved
    saved=$(exec_cmd "$vmname" "grep -c 'MASQUERADE' /etc/sysconfig/iptables 2>/dev/null")
    
    if [[ "$saved" -ge 1 ]]; then
        print_result "2.4" "iptables saved" "PASS" "Правила сохранены"
    else
        print_result "2.4" "iptables saved" "FAIL" "Файл не содержит правил"
    fi
}

check_timezone() {
    local vmname="$1"
    local dtype="${DEV_TYPE[$vmname]}"
    
    echo -e "\n${YELLOW}>>> Проверка часового пояса: $vmname${NC}"
    
    local cmd=""
    if [[ "$dtype" == "ecorouter" ]]; then
        cmd="show clock"
    else
        cmd="timedatectl | grep 'Time zone'"
    fi
    
    local tz
    tz=$(exec_cmd "$vmname" "$cmd")
    
    shopt -s nocasematch
    
    if [[ "$tz" == *"Asia/Yakutsk"* ]] || [[ "$tz" == *"Asia/Yakuts"* ]] || \
       [[ "$tz" == *"UTC+9"* ]] || [[ "$tz" == *"utc+9"* ]] || [[ "$tz" == *"+09"* ]]; then
        print_result "11" "Timezone $vmname" "PASS" "$tz"
    else
        print_result "11" "Timezone $vmname" "FAIL" "Неверный пояс: $tz"
    fi
    shopt -u nocasematch
}

check_users_linux() {
    local vmname="$1"
    
    echo -e "\n${YELLOW}>>> Проверка пользователей: $vmname${NC}"
    
    local uid
    uid=$(exec_cmd "$vmname" "id -u sshuser 2>/dev/null")
    
    if [[ "$uid" == "2026" ]]; then
        print_result "3.1" "sshuser UID 2026" "PASS" "UID=$uid"
    else
        print_result "3.1" "sshuser UID 2026" "FAIL" "UID=$uid (ожидалось 2026)"
    fi
    
    local sudo_cfg
    sudo_cfg=$(exec_cmd "$vmname" "grep 'sshuser.*NOPASSWD' /etc/sudoers /etc/sudoers.d/* 2>/dev/null")
    
    if [[ -n "$sudo_cfg" ]]; then
        print_result "3.2" "sshuser sudo NOPASSWD" "PASS" "Настроено"
    else
        print_result "3.2" "sshuser sudo NOPASSWD" "FAIL" "Не настроено"
    fi
}

check_ssh_security() {
    local vmname="HQ-SRV"
    
    echo -e "\n${YELLOW}>>> Проверка SSH безопасности: $vmname${NC}"
    
    local cfg
    cfg=$(exec_cmd "$vmname" "cat /etc/openssh/sshd_config 2>/dev/null")
    
    shopt -s nocasematch
    
    if [[ "$cfg" == *"Port 2026"* ]]; then
        print_result "5.1" "SSH Port 2026" "PASS" "Настроен"
    else
        print_result "5.1" "SSH Port 2026" "FAIL" "Порт не 2026"
    fi
    
    if [[ "$cfg" == *"AllowUsers sshuser"* ]]; then
        print_result "5.2" "AllowUsers sshuser" "PASS" "Настроено"
    else
        print_result "5.2" "AllowUsers sshuser" "FAIL" "Не настроено"
    fi
    
    if [[ "$cfg" == *"MaxAuthTries 2"* ]]; then
        print_result "5.3" "MaxAuthTries 2" "PASS" "Настроено"
    else
        print_result "5.3" "MaxAuthTries 2" "FAIL" "Не настроено"
    fi
    
    local banner
    banner=$(exec_cmd "$vmname" "cat /etc/openssh/banner 2>/dev/null")
    
    if [[ "$banner" == *"Authorized access only"* ]]; then
        print_result "5.4" "SSH Banner" "PASS" "Настроен"
    else
        print_result "5.4" "SSH Banner" "FAIL" "Не настроен"
    fi
    
    local conn
    conn=$(sshpass -p "$SSHUSER_PASS" ssh -o StrictHostKeyChecking=no \
        -o ConnectTimeout=5 -p "$PORT_SECURE" "sshuser@${VM_IPS[$vmname]}" "echo OK" 2>/dev/null)
    
    if [[ "$conn" == "OK" ]]; then
        print_result "5.5" "SSH port 2026 connection" "PASS" "Подключение успешно"
    else
        print_result "5.5" "SSH port 2026 connection" "FAIL" "Не удалось подключиться"
    fi
    
    shopt -u nocasematch
}

check_ecorouter_user() {
    local vmname="$1"
    
    echo -e "\n${YELLOW}>>> Проверка пользователя net_admin: $vmname${NC}"
    
    local cfg
    cfg=$(exec_cmd "$vmname" "show running-config 2>/dev/null | grep 'username net_admin'")
    
    if [[ "$cfg" == *"net_admin"* ]]; then
        print_result "3.3" "net_admin on $vmname" "PASS" "Пользователь создан"
    else
        print_result "3.3" "net_admin on $vmname" "FAIL" "Пользователь не найден"
    fi
}

check_ecorouter_vlan() {
    local vmname="HQ-RTR"
    
    echo -e "\n${YELLOW}>>> Проверка VLAN: $vmname${NC}"
    
    local cfg
    cfg=$(exec_cmd "$vmname" "show service-instance 2>/dev/null")
    
    shopt -s nocasematch
    
    if [[ "$cfg" == *"dot1q 100 exact"* ]]; then
        print_result "4.1" "VLAN 100 service-instance" "PASS" "Настроен"
    else
        print_result "4.1" "VLAN 100 service-instance" "FAIL" "Не найден"
    fi
    
    if [[ "$cfg" == *"dot1q 200 exact"* ]]; then
        print_result "4.2" "VLAN 200 service-instance" "PASS" "Настроен"
    else
        print_result "4.2" "VLAN 200 service-instance" "FAIL" "Не найден"
    fi
    
    if [[ "$cfg" == *"dot1q 999 exact"* ]]; then
        print_result "4.3" "VLAN 999 service-instance" "PASS" "Настроен"
    else
        print_result "4.3" "VLAN 999 service-instance" "FAIL" "Не найден"
    fi
    
    local si_count
    si_count=$(echo "$cfg" | grep -c "service-instance.*te1")
    if [[ "$si_count" -ge 3 ]]; then
        print_result "4.4" "Router-on-a-stick" "PASS" "$si_count SI на te1"
    else
        print_result "4.4" "Router-on-a-stick" "FAIL" "Недостаточно service-instance"
    fi
    
    shopt -u nocasematch
}

check_ecorouter_tunnel() {
    local vmname="$1"
    
    echo -e "\n${YELLOW}>>> Проверка туннеля: $vmname${NC}"
    
    local cfg
    cfg=$(exec_cmd "$vmname" "show interface tunnel.0 2>/dev/null")
    
    shopt -s nocasematch
    
    if [[ "$vmname" == "HQ-RTR" ]]; then
        if [[ "$cfg" == *"10.10.10.1/30"* ]] && [[ "$cfg" == *"gre"* ]]; then
            print_result "6.1" "Tunnel HQ-RTR" "PASS" "10.10.10.1/30 GRE"
        else
            print_result "6.1" "Tunnel HQ-RTR" "FAIL" "Туннель не настроен"
        fi
    else
        if [[ "$cfg" == *"10.10.10.2/30"* ]] && [[ "$cfg" == *"gre"* ]]; then
            print_result "6.2" "Tunnel BR-RTR" "PASS" "10.10.10.2/30 GRE"
        else
            print_result "6.2" "Tunnel BR-RTR" "FAIL" "Туннель не настроен"
        fi
    fi
    
    shopt -u nocasematch
}

check_ecorouter_ospf() {
    local vmname="$1"
    
    echo -e "\n${YELLOW}>>> Проверка OSPF: $vmname${NC}"
    
    local cfg
    cfg=$(exec_cmd "$vmname" "show running-config 2>/dev/null")
    
    shopt -s nocasematch
    
    if [[ "$cfg" == *"router ospf 1"* ]]; then
        print_result "7.1" "OSPF process on $vmname" "PASS" "Протокол настроен"
    else
        print_result "7.1" "OSPF process on $vmname" "FAIL" "OSPF не найден"
    fi
    
    if [[ "$cfg" == *"message-digest"* ]] || [[ "$cfg" == *"authentication"* ]]; then
        print_result "7.2" "OSPF MD5 auth on $vmname" "PASS" "Аутентификация включена"
    else
        print_result "7.2" "OSPF MD5 auth on $vmname" "FAIL" "А
