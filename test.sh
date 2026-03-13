#!/bin/bash
# =============================================================================
# Скрипт проверки Модуля 1: Настройка сетевой инфраструктуры
# КОД 09.02.06-1-2026
# =============================================================================

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# =============================================================================
# ⚙️ КОНФИГУРАЦИЯ
# =============================================================================

# Домен (оставлен для проверок конфигурации внутри ВМ)
DOMAIN="au-team.irpo"

# Учетные данные
ROOT_PASS='P@$$w0rd'
SSHUSER_PASS='P@ssw0rd'
NETADMIN_PASS='P@ssw0rd'

# Порты
PORT_ROOT=22
PORT_SECURE=2026

# 🔥 Хосты с реальными IP-адресами (вместо DNS-имён)
declare -A HOSTS=(
    ["ISP"]="172.16.1.1"           # Шлюз для офисов
    ["HQ-RTR"]="172.16.1.2"        # Основной интерфейс HQ-RTR
    ["BR-RTR"]="172.16.2.2"        # Основной интерфейс BR-RTR
    ["HQ-SRV"]="192.168.100.2"     # Сервер HQ (VLAN 100)
    ["BR-SRV"]="192.168.0.2"       # Сервер BR
    ["HQ-CLI"]="192.168.200.2"     # Клиент HQ (VLAN 200)
)

# Типы устройств (linux/ecorouter)
declare -A DEV_TYPE=(
    ["ISP"]="linux"
    ["HQ-RTR"]="ecorouter"
    ["BR-RTR"]="ecorouter"
    ["HQ-SRV"]="linux"
    ["BR-SRV"]="linux"
    ["HQ-CLI"]="linux"
)

# Счетчики
TOTAL=0
PASSED=0
FAILED=0

# Лог файл
LOG_FILE="check_module1_$(date +%Y%m%d_%H%M%S).log"
JSON_FILE="results_module1_$(date +%Y%m%d_%H%M%S).json"

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
    [[ -n "$details" ]] && echo -e "    ${BLUE}ℹ️${NC} $details"
}

# SSH подключение к Linux-устройству
ssh_linux() {
    local host="$1"
    local user="${2:-root}"
    local pass="${3:-$ROOT_PASS}"
    local port="${4:-$PORT_ROOT}"
    local cmd="$5"
    
    sshpass -p "$pass" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p "$port" "${user}@${host}" "$cmd" 2>/dev/null
}

# SSH подключение к EcoRouter
ssh_eco() {
    local host="$1"
    local cmd="$2"
    # EcoRouter использует стандартный SSH с паролем root
    sshpass -p "$ROOT_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
        -p 22 "root@${host}" "$cmd" 2>/dev/null
}

# Выполнение команды с учётом типа устройства
exec_cmd() {
    local vm="$1"
    local cmd="$2"
    local dtype="${DEV_TYPE[$vm]}"
    local host="${HOSTS[$vm]}"
    
    if [[ "$dtype" == "ecorouter" ]]; then
        ssh_eco "$host" "$cmd"
    else
        ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "$cmd"
    fi
}

# =============================================================================
# ✅ ПРОВЕРКИ
# =============================================================================

# Задание 1.1: Hostname (FQDN)
check_hostname() {
    local vm="$1"
    local host="${HOSTS[$vm]}"
    local dtype="${DEV_TYPE[$vm]}"
    local expected="${vm,,}.$DOMAIN"
    
    echo -e "\n${YELLOW}>>> Проверка hostname: $vm${NC}"
    
    if [[ "$dtype" == "ecorouter" ]]; then
        # ISP не требует FQDN
        [[ "$vm" == "ISP" ]] && { print_result "1.1" "Hostname $vm" "PASS" "ISP - имя без домена"; return; }
        
        local out=$(ssh_eco "$host" "show hostname 2>/dev/null")
        if [[ "$out" == *"$expected"* ]]; then
            print_result "1.1" "Hostname $vm" "PASS" "$out"
        else
            print_result "1.1" "Hostname $vm" "FAIL" "Ожидается: $expected"
        fi
    else
        local out=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "hostname -f 2>/dev/null")
        if [[ "$out" == *"$expected"* ]]; then
            print_result "1.1" "Hostname $vm" "PASS" "$out"
        else
            print_result "1.1" "Hostname $vm" "FAIL" "Ожидается: $expected, получено: $out"
        fi
    fi
}

# Задание 1.2: IPv4 конфигурация и маски подсетей
check_ipv4_subnets() {
    local vm="$1"
    local host="${HOSTS[$vm]}"
    local dtype="${DEV_TYPE[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка IPv4 подсетей: $vm${NC}"
    
    if [[ "$dtype" == "ecorouter" ]]; then
        local out=$(ssh_eco "$host" "show ip interface brief 2>/dev/null")
        [[ -n "$out" ]] && print_result "1.2" "IPv4 on $vm" "PASS" "Интерфейсы настроены" \
            || print_result "1.2" "IPv4 on $vm" "FAIL" "Нет IP-адресов"
    else
        local out=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "ip -br addr show 2>/dev/null | grep -v lo")
        if [[ -n "$out" ]]; then
            print_result "1.2" "IPv4 on $vm" "PASS" "Адреса настроены"
            
            # Проверка масок для VLAN (только для HQ-RTR)
            if [[ "$vm" == "HQ-RTR" ]]; then
                # VLAN 100: /27 (≤32 адреса)
                [[ "$out" == *"192.168.100."*"/27"* ]] && \
                    print_result "1.2" "VLAN 100 mask /27" "PASS" "HQ-SRV сеть" \
                    || print_result "1.2" "VLAN 100 mask /27" "FAIL" "Неверная маска"
                
                # VLAN 200: ≥16 адресов (/24, /28 и т.д.)
                [[ "$out" == *"192.168.200."* ]] && \
                    print_result "1.2" "VLAN 200 subnet" "PASS" "HQ-CLI сеть" \
                    || print_result "1.2" "VLAN 200 subnet" "FAIL" "Сеть не найдена"
                
                # VLAN 999: /29 (≤8 адресов)
                [[ "$out" == *"192.168.99."*"/29"* ]] && \
                    print_result "1.2" "VLAN 999 mask /29" "PASS" "Management сеть" \
                    || print_result "1.2" "VLAN 999 mask /29" "FAIL" "Неверная маска"
            fi
        else
            print_result "1.2" "IPv4 on $vm" "FAIL" "IP-адреса не найдены"
        fi
    fi
}

# Задание 2: ISP настройка (интерфейсы, NAT, маршрут)
check_isp_config() {
    local vm="ISP"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка ISP конфигурации${NC}"
    
    # Интерфейсы 172.16.1.0/28 и 172.16.2.0/28
    local out=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "ip addr show 2>/dev/null")
    if [[ "$out" == *"172.16.1."* ]] && [[ "$out" == *"172.16.2."* ]]; then
        print_result "2.1" "ISP interfaces" "PASS" "Сети 172.16.1.0/28 и 172.16.2.0/28"
    else
        print_result "2.1" "ISP interfaces" "FAIL" "Интерфейсы не настроены"
    fi
    
    # Маршрут по умолчанию
    local route=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "ip route show default 2>/dev/null")
    [[ -n "$route" ]] && print_result "2.2" "Default route" "PASS" "$route" \
        || print_result "2.2" "Default route" "FAIL" "Маршрут не найден"
    
    # NAT (MASQUERADE/SNAT)
    local nat=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "iptables -t nat -L POSTROUTING -n 2>/dev/null")
    if [[ "$nat" == *"MASQUERADE"* ]] || [[ "$nat" == *"SNAT"* ]]; then
        print_result "2.3" "NAT configured" "PASS" "Трансляция адресов активна"
    else
        print_result "2.3" "NAT configured" "FAIL" "NAT не настроен"
    fi
}

# Задание 3: Пользователи (sshuser, net_admin)
check_users() {
    local vm="$1"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка пользователей: $vm${NC}"
    
    if [[ "$vm" == *"SRV"* ]]; then
        # Проверка sshuser
        local uid=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "id -u sshuser 2>/dev/null")
        if [[ "$uid" == "2026" ]]; then
            print_result "3.1" "sshuser UID 2026" "PASS" "UID=$uid"
        else
            print_result "3.1" "sshuser UID 2026" "FAIL" "UID=$uid (ожидалось 2026)"
        fi
        
        # Проверка sudo NOPASSWD
        local sudo_cfg=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "grep -r 'sshuser' /etc/sudoers* 2>/dev/null | grep NOPASSWD")
        [[ -n "$sudo_cfg" ]] && print_result "3.2" "sshuser sudo NOPASSWD" "PASS" "Настроено" \
            || print_result "3.2" "sshuser sudo NOPASSWD" "FAIL" "Не настроено"
            
    elif [[ "$vm" == *"RTR"* ]]; then
        # Проверка net_admin на маршрутизаторах
        local dtype="${DEV_TYPE[$vm]}"
        if [[ "$dtype" == "ecorouter" ]]; then
            local eco_user=$(ssh_eco "$host" "show running-config | grep username 2>/dev/null")
            [[ "$eco_user" == *"net_admin"* ]] && print_result "3.3" "net_admin on $vm" "PASS" "Пользователь создан" \
                || print_result "3.3" "net_admin on $vm" "FAIL" "Пользователь не найден"
        else
            local linux_user=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "id net_admin 2>/dev/null")
            [[ -n "$linux_user" ]] && print_result "3.3" "net_admin on $vm" "PASS" "$linux_user" \
                || print_result "3.3" "net_admin on $vm" "FAIL" "Пользователь не найден"
            
            local sudo_cfg=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "grep -r 'net_admin' /etc/sudoers* 2>/dev/null | grep NOPASSWD")
            [[ -n "$sudo_cfg" ]] && print_result "3.4" "net_admin sudo NOPASSWD" "PASS" "Настроено" \
                || print_result "3.4" "net_admin sudo NOPASSWD" "FAIL" "Не настроено"
        fi
    fi
}

# Задание 4: VLAN конфигурация на HQ-RTR
check_vlans() {
    local vm="HQ-RTR"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка VLAN на $vm${NC}"
    
    local out=$(ssh_eco "$host" "show port brief 2>/dev/null; show service-instance 2>/dev/null")
    
    # Проверка service-instance для VLAN
    [[ "$out" == *"dot1q 100"* ]] && print_result "4.1" "VLAN 100 service-instance" "PASS" "Настроен" \
        || print_result "4.1" "VLAN 100 service-instance" "FAIL" "Не найден"
    
    [[ "$out" == *"dot1q 200"* ]] && print_result "4.2" "VLAN 200 service-instance" "PASS" "Настроен" \
        || print_result "4.2" "VLAN 200 service-instance" "FAIL" "Не найден"
    
    [[ "$out" == *"dot1q 999"* ]] && print_result "4.3" "VLAN 999 service-instance" "PASS" "Настроен" \
        || print_result "4.3" "VLAN 999 service-instance" "FAIL" "Не найден"
    
    # Router-on-a-stick (один порт для всех VLAN)
    local si_count=$(echo "$out" | grep -c "service-instance.*te1")
    [[ "$si_count" -ge 3 ]] && print_result "4.4" "Router-on-a-stick" "PASS" "$si_count SI на te1" \
        || print_result "4.4" "Router-on-a-stick" "FAIL" "Недостаточно service-instance"
}

# Задание 5: Безопасный SSH (порт 2026, AllowUsers, MaxAuthTries, Banner)
check_ssh_security() {
    local vm="$1"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка SSH безопасности: $vm${NC}"
    
    # Подключение на порт 2026 пользователем sshuser
    local conn=$(sshpass -p "$SSHUSER_PASS" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        -p "$PORT_SECURE" "sshuser@${host}" "echo OK" 2>/dev/null)
    
    if [[ "$conn" == "OK" ]]; then
        print_result "5.1" "SSH port 2026" "PASS" "Подключение успешно"
    else
        print_result "5.1" "SSH port 2026" "FAIL" "Не удалось подключиться"
    fi
    
    # Проверка конфигурации sshd
    local cfg=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "cat /etc/ssh/sshd_config 2>/dev/null")
    
    [[ "$cfg" == *"Port 2026"* ]] && print_result "5.2" "SSH Port config" "PASS" "Port 2026" \
        || print_result "5.2" "SSH Port config" "FAIL" "Порт не 2026"
    
    [[ "$cfg" == *"AllowUsers sshuser"* ]] && print_result "5.3" "AllowUsers sshuser" "PASS" "Настроено" \
        || print_result "5.3" "AllowUsers sshuser" "FAIL" "Не настроено"
    
    [[ "$cfg" == *"MaxAuthTries 2"* ]] && print_result "5.4" "MaxAuthTries 2" "PASS" "Настроено" \
        || print_result "5.4" "MaxAuthTries 2" "FAIL" "Не настроено"
    
    local banner=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "cat /etc/issue.net 2>/dev/null")
    [[ "$banner" == *"Authorized access only"* ]] && print_result "5.5" "Banner" "PASS" "Настроен" \
        || print_result "5.5" "Banner" "FAIL" "Не настроен"
}

# Задание 6: IP туннель (GRE/IPinIP)
check_tunnel() {
    echo -e "\n${YELLOW}>>> Проверка IP туннеля${NC}"
    
    for vm in "HQ-RTR" "BR-RTR"; do
        local host="${HOSTS[$vm]}"
        local out=$(ssh_eco "$host" "show ip tunnel 2>/dev/null; show interface | grep -i tunnel 2>/dev/null")
        
        if [[ "$out" == *"gre"* ]] || [[ "$out" == *"ipip"* ]] || [[ "$out" == *"tunnel"* ]]; then
            print_result "6" "Tunnel on $vm" "PASS" "Туннель настроен"
        else
            print_result "6" "Tunnel on $vm" "FAIL" "Туннель не найден"
        fi
    done
}

# Задание 7: OSPF с аутентификацией
check_ospf() {
    echo -e "\n${YELLOW}>>> Проверка OSPF маршрутизации${NC}"
    
    for vm in "HQ-RTR" "BR-RTR"; do
        local host="${HOSTS[$vm]}"
        local cfg=$(ssh_eco "$host" "show running-config 2>/dev/null | grep -i ospf")
        
        if [[ -n "$cfg" ]]; then
            print_result "7.1" "OSPF on $vm" "PASS" "Протокол настроен"
            
            # Проверка аутентификации
            if [[ "$cfg" == *"password"* ]] || [[ "$cfg" == *"authentication"* ]]; then
                print_result "7.2" "OSPF auth on $vm" "PASS" "Парольная защита включена"
            else
                print_result "7.2" "OSPF auth on $vm" "FAIL" "Аутентификация не найдена"
            fi
        else
            print_result "7.1" "OSPF on $vm" "FAIL" "OSPF не настроен"
        fi
    done
}

# Задание 8: Dynamic NAT/SNAT на офисных роутерах
check_nat_dynamic() {
    echo -e "\n${YELLOW}>>> Проверка динамического NAT${NC}"
    
    for vm in "HQ-RTR" "BR-RTR"; do
        local host="${HOSTS[$vm]}"
        local dtype="${DEV_TYPE[$vm]}"
        
        if [[ "$dtype" == "ecorouter" ]]; then
            local nat=$(ssh_eco "$host" "show running-config | grep -i nat 2>/dev/null")
            [[ "$nat" == *"masquerade"* ]] || [[ "$nat" == *"src-nat"* ]] && \
                print_result "8" "SNAT on $vm" "PASS" "Настроен" \
                || print_result "8" "SNAT on $vm" "FAIL" "Не найден"
        else
            local ipt=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "iptables -t nat -L POSTROUTING -n 2>/dev/null")
            [[ "$ipt" == *"MASQUERADE"* ]] || [[ "$ipt" == *"SNAT"* ]] && \
                print_result "8" "SNAT on $vm" "PASS" "Настроен" \
                || print_result "8" "SNAT on $vm" "FAIL" "Не найден"
        fi
    done
}

# Задание 9: DHCP сервер на HQ-RTR для HQ-CLI
check_dhcp() {
    local vm="HQ-RTR"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка DHCP сервера${NC}"
    
    # Проверка службы (для Linux-версии EcoRouter)
    local svc=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "systemctl is-active dhcpd 2>/dev/null || systemctl is-active isc-dhcp-server 2>/dev/null")
    
    if [[ "$svc" == *"active"* ]]; then
        print_result "9.1" "DHCP service" "PASS" "Служба запущена"
    else
        # Проверка через процесс
        local proc=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "ps aux | grep -E 'dhcpd|dnsmasq' | grep -v grep")
        [[ -n "$proc" ]] && print_result "9.1" "DHCP service" "PASS" "Процесс запущен" \
            || print_result "9.1" "DHCP service" "FAIL" "Служба не активна"
    fi
    
    # Проверка конфигурации
    local cfg=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "cat /etc/dhcp/dhcpd.conf 2>/dev/null")
    if [[ -n "$cfg" ]]; then
        [[ "$cfg" == *"au-team.irpo"* ]] && print_result "9.2" "DHCP domain-name" "PASS" "DNS суффикс настроен" \
            || print_result "9.2" "DHCP domain-name" "FAIL" "DNS суффикс не найден"
        
        [[ "$cfg" == *"option routers"* ]] && print_result "9.3" "DHCP gateway" "PASS" "Шлюз указан" \
            || print_result "9.3" "DHCP gateway" "FAIL" "Шлюз не указан"
    fi
}

# Задание 10: DNS сервер на HQ-SRV
check_dns() {
    local vm="HQ-SRV"
    local host="${HOSTS[$vm]}"
    
    echo -e "\n${YELLOW}>>> Проверка DNS сервера${NC}"
    
    # Проверка службы
    local svc=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "systemctl is-active named 2>/dev/null || systemctl is-active bind9 2>/dev/null")
    [[ "$svc" == *"active"* ]] && print_result "10.1" "DNS service" "PASS" "Служба запущена" \
        || print_result "10.1" "DNS service" "FAIL" "Служба не активна"
    
    # Проверка записей из Таблицы 3
    local records=("hq-rtr" "hq-srv" "hq-cli" "br-rtr" "br-srv")
    for rec in "${records[@]}"; do
        local fqdn="${rec}.${DOMAIN}"
        local lookup=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "dig +short ${fqdn} @localhost 2>/dev/null || host ${fqdn} localhost 2>/dev/null")
        [[ -n "$lookup" ]] && print_result "10.2" "DNS A-record ${fqdn}" "PASS" "$lookup" \
            || print_result "10.2" "DNS A-record ${fqdn}" "FAIL" "Запись не найдена"
    done
    
    # Проверка forwarder
    local fwd=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "grep -E 'forwarders|77.88.8' /etc/bind/named.conf.options 2>/dev/null")
    [[ -n "$fwd" ]] && print_result "10.3" "DNS forwarder" "PASS" "Пересылка настроена" \
        || print_result "10.3" "DNS forwarder" "FAIL" "Пересылка не найдена"
}

# Задание 11: Часовой пояс
check_timezone() {
    echo -e "\n${YELLOW}>>> Проверка часового пояса${NC}"
    
    for vm in "${!HOSTS[@]}"; do
        [[ "$vm" == "ISP" ]] && continue  # ISP может не требовать TZ
        local host="${HOSTS[$vm]}"
        local dtype="${DEV_TYPE[$vm]}"
        
        if [[ "$dtype" == "ecorouter" ]]; then
            local tz=$(ssh_eco "$host" "show clock 2>/dev/null")
            [[ -n "$tz" ]] && print_result "11" "Timezone $vm" "PASS" "$tz" \
                || print_result "11" "Timezone $vm" "FAIL" "Не определено"
        else
            local tz=$(ssh_linux "$host" root "$ROOT_PASS" "$PORT_ROOT" "timedatectl | grep 'Time zone' 2>/dev/null")
            [[ -n "$tz" ]] && print_result "11" "Timezone $vm" "PASS" "$tz" \
                || print_result "11" "Timezone $vm" "FAIL" "Не определено"
        fi
    done
}

# =============================================================================
# 🚀 ЗАПУСК ПРОВЕРКИ
# =============================================================================

run_checks() {
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  ПРОВЕРКА МОДУЛЯ 1: Сетевая инфраструктура${NC}"
    echo -e "${BLUE}  КОД 09.02.06-1-2026${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    
    log "=== START Module 1 Check ==="
    
    # Задание 1: Hostname и IPv4
    for vm in "${!HOSTS[@]}"; do
        check_hostname "$vm"
        check_ipv4_subnets "$vm"
    done
    
    # Задание 2: ISP
    check_isp_config
    
    # Задание 3: Пользователи
    for vm in "HQ-SRV" "BR-SRV" "HQ-RTR" "BR-RTR"; do
        check_users "$vm"
    done
    
    # Задание 4: VLAN
    check_vlans
    
    # Задание 5: SSH Security
    for vm in "HQ-SRV" "BR-SRV"; do
        check_ssh_security "$vm"
    done
    
    # Задание 6: Tunnel
    check_tunnel
    
    # Задание 7: OSPF
    check_ospf
    
    # Задание 8: Dynamic NAT
    check_nat_dynamic
    
    # Задание 9: DHCP
    check_dhcp
    
    # Задание 10: DNS
    check_dns
    
    # Задание 11: Timezone
    check_timezone
    
    print_summary
}

print_summary() {
    echo -e "\n${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  ИТОГОВЫЙ ОТЧЕТ${NC}"
    echo -e "${BLUE}════════════════════════════════════════════════════${NC}"
    echo -e "Всего проверок: ${TOTAL}"
    echo -e "${GREEN}✅ Пройдено: ${PASSED}${NC}"
    echo -e "${RED}❌ Не пройдено: ${FAILED}${NC}"
    
    if [[ $TOTAL -gt 0 ]]; then
        local percent=$((PASSED * 100 / TOTAL))
        echo -e "📊 Успешность: ${percent}%"
    fi
    
    # Сохранение JSON-отчета
    cat > "$JSON_FILE" << EOF
{
  "module": "Module 1 - Network Infrastructure",
  "kod": "09.02.06-1-2026",
  "timestamp": "$(date -Iseconds)",
  "total_checks": $TOTAL,
  "passed_checks": $PASSED,
  "failed_checks": $FAILED,
  "success_rate": "$((TOTAL > 0 ? PASSED * 100 / TOTAL : 0))%"
}
EOF
    
    echo -e "\n💾 Результаты сохранены:"
    echo "   📄 $LOG_FILE"
    echo "   📊 $JSON_FILE"
    
    log "=== END Module 1 Check ==="
}

# =============================================================================
# 🎯 MAIN
# =============================================================================

main() {
    # Проверка зависимостей
    if ! command -v sshpass &>/dev/null; then
        echo -e "${RED}❌ Ошибка: не установлен sshpass${NC}"
        echo "Установите: sudo apt install sshpass  # для Debian/Alt Linux"
        exit 1
    fi
    
    if ! command -v ssh &>/dev/null; then
        echo -e "${RED}❌ Ошибка: не установлен ssh клиент${NC}"
        exit 1
    fi
    
    # Запуск
    run_checks
}

# Запуск скрипта
main "$@"
