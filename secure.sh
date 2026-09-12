#!/bin/bash
# ==============================================================================
# Script: secure.sh (Xray Advanced 42 - Server Hardening & Security)
# ==============================================================================
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ОШИБКА] Этот скрипт должен быть запущен с правами root (sudo).${NC}" >&2
    exit 1
fi

if [[ "${1:-}" == "--restore" ]]; then
    echo -e "${YELLOW}Начат откат настроек безопасности...${NC}"
    rm -f /etc/ssh/sshd_config.d/99-xray-hardening.conf
    sed -i 's/^Port .*/Port 22/' /etc/ssh/sshd_config || true
    systemctl restart sshd || systemctl restart ssh || true
    if command -v ufw >/dev/null; then
        ufw --force disable
    fi
    if command -v systemctl >/dev/null; then
        systemctl stop fail2ban 2>/dev/null || true
        systemctl disable fail2ban 2>/dev/null || true
    fi
    echo -e "${GREEN}✓ Откат завершен. SSH доступен на стандартном порту 22.${NC}"
    exit 0
fi

clear
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}       Xray Advanced 42 — Скрипт защиты сервера (Hardening)     ${NC}"
echo -e "${CYAN}================================================================${NC}"

# 1. Проверка SSH ключей
echo -e "${BLUE}▶ Шаг 1/7. Проверка наличия публичного SSH-ключа...${NC}"
AUTH_KEYS="$HOME/.ssh/authorized_keys"
KEY_EXISTS=false
if [[ -f "$AUTH_KEYS" ]] && grep -qE '^(ssh-rsa|ssh-ed25519|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521)' "$AUTH_KEYS"; then
    KEY_EXISTS=true
fi

if [[ "$KEY_EXISTS" = false ]]; then
    echo -e "\n${RED}⚠️  ВНИМАНИЕ! В файле $AUTH_KEYS не найден публичный SSH-ключ!${NC}"
    echo -e "${YELLOW}Если мы сейчас отключим пароли, вы НАВСЕГДА потеряете доступ к этому серверу!${NC}\n"
    echo -e "Вставьте ваш публичный ключ (обычно начинается на 'ssh-ed25519 ...' или 'ssh-rsa ...'):"
    read -r USER_PUB_KEY
    if [[ -z "$USER_PUB_KEY" || ! "$USER_PUB_KEY" =~ ^(ssh-rsa|ssh-ed25519|ecdsa-) ]]; then
        echo -e "${RED}[ОТМЕНА] Введен некорректный ключ. Настройка прервана во избежание блокировки.${NC}"
        exit 1
    fi
    mkdir -p "$HOME/.ssh"
    chmod 700 "$HOME/.ssh"
    echo "$USER_PUB_KEY" >> "$AUTH_KEYS"
    chmod 600 "$AUTH_KEYS"
    echo -e "${GREEN}✓ Публичный ключ успешно добавлен в $AUTH_KEYS!${NC}"
else
    KEY_COUNT=$(grep -cE '^(ssh-rsa|ssh-ed25519|ecdsa-)' "$AUTH_KEYS" || true)
    echo -e "${GREEN}✓ Проверка пройдена: обнаружено действительных SSH-ключей: $KEY_COUNT.${NC}"
fi

# 2. Порт SSH
echo -e "\n${BLUE}▶ Шаг 2/7. Настройка порта SSH...${NC}"
DEFAULT_RANDOM_PORT=$((RANDOM % 30000 + 20000))
echo -e "Стандартный порт 22 постоянно сканируют боты."
echo -e "Рекомендуется выбрать порт из диапазона 10000-60000."
echo -e "Нажмите Enter для использования сгенерированного случайного порта: ${GREEN}${DEFAULT_RANDOM_PORT}${NC},"
read -p "или введите свой желаемый порт: " INPUT_SSH_PORT
SSH_PORT="${INPUT_SSH_PORT:-$DEFAULT_RANDOM_PORT}"

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
    echo -e "${RED}[ОШИБКА] Порт должен быть числом от 1024 до 65535.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Выбран порт SSH: $SSH_PORT${NC}"

# 3. Порт Xray
echo -e "\n${BLUE}▶ Шаг 3/7. Определение портов для файрвола...${NC}"
XRAY_PORT=443
if [[ -f "/usr/local/etc/xray/config.json" ]]; then
    if command -v jq >/dev/null; then
        DETECTED_PORT=$(jq -r '.inbounds[0].port // empty' /usr/local/etc/xray/config.json 2>/dev/null || true)
        if [[ -n "$DETECTED_PORT" && "$DETECTED_PORT" =~ ^[0-9]+$ ]]; then
            XRAY_PORT="$DETECTED_PORT"
            echo -e "${GREEN}✓ Обнаружен установленный Xray, использующий порт: $XRAY_PORT${NC}"
        fi
    fi
fi

# 4. Установка пакетов
echo -e "\n${BLUE}▶ Шаг 4/7. Установка защитных утилит (ufw, fail2ban)...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y ufw fail2ban unattended-upgrades curl jq >/dev/null 2>&1

# 5. SSH Config
echo -e "\n${BLUE}▶ Шаг 5/7. Настройка SSH демона...${NC}"
SSHD_HARDEN_CONF="/etc/ssh/sshd_config.d/99-xray-hardening.conf"
mkdir -p /etc/ssh/sshd_config.d/
cat << INNER_EOF > "$SSHD_HARDEN_CONF"
Port $SSH_PORT
AddressFamily inet
Protocol 2
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no
PermitRootLogin prohibit-password
MaxAuthTries 3
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
INNER_EOF

# Ensure main sshd_config includes the .d directory
if [ -f "/etc/ssh/sshd_config" ] && ! grep -q "^Include /etc/ssh/sshd_config.d/\*.conf" /etc/ssh/sshd_config; then
    echo "Include /etc/ssh/sshd_config.d/*.conf" | cat - /etc/ssh/sshd_config > temp && mv temp /etc/ssh/sshd_config
fi

systemctl restart sshd || systemctl restart ssh || true

# 6. UFW
echo -e "\n${BLUE}▶ Шаг 6/7. Настройка файрвола UFW...${NC}"
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null 2>&1 || true
ufw default allow outgoing >/dev/null 2>&1 || true
ufw allow $SSH_PORT/tcp >/dev/null 2>&1 || true
ufw allow $XRAY_PORT/tcp >/dev/null 2>&1 || true
ufw allow $XRAY_PORT/udp >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true
echo -e "${GREEN}✓ UFW включен. Открыты порты: $SSH_PORT (SSH) и $XRAY_PORT (Xray).${NC}"

# 7. Fail2ban
echo -e "\n${BLUE}▶ Шаг 7/7. Настройка Fail2ban...${NC}"
cat << INNER_EOF > /etc/fail2ban/jail.local
[sshd]
enabled = true
port = $SSH_PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
INNER_EOF
systemctl restart fail2ban >/dev/null 2>&1 || true
systemctl enable fail2ban >/dev/null 2>&1 || true
echo -e "${GREEN}✓ Fail2ban активирован для порта $SSH_PORT.${NC}"

# Sysctl (Anti-DDoS basics)
cat << INNER_EOF > /etc/sysctl.d/99-xray-net.conf
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.tcp_max_syn_backlog = 2048
INNER_EOF
sysctl -p /etc/sysctl.d/99-xray-net.conf >/dev/null 2>&1 || true

echo -e "\n${CYAN}================================================================${NC}"
echo -e "${GREEN}🎉 ЗАЩИТА СЕРВЕРА УСПЕШНО НАСТРОЕНА!${NC}"
echo -e "Ваш новый порт SSH: ${RED}$SSH_PORT${NC} (ЗАПИШИТЕ ЕГО!)"
echo -e "Вход по паролю ${RED}ОТКЛЮЧЕН${NC}."
echo -e "Для подключения теперь используйте: ${CYAN}ssh -p $SSH_PORT root@<IP_СЕРВЕРА>${NC}"
echo -e "${CYAN}================================================================${NC}\n"
