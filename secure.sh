#!/bin/bash
# ==============================================================================
# Script: secure.sh (Xray Advanced 42 - Server Hardening & Security)
# Author: @ddonkeyhot & AI Assistant
# Description: Комплексная защита сервера: SSH-ключи, смена порта, UFW,
#              Fail2ban, автообновления безопасности и защита сетевого стека (sysctl).
# ==============================================================================

set -euo pipefail

# Цвета для красивого вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# ------------------------------------------------------------------------------
# 1. Проверка прав суперпользователя (root)
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ОШИБКА] Этот скрипт должен быть запущен с правами root (sudo).${NC}" >&2
    exit 1
fi

clear
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}       Xray Advanced 42 — Скрипт защиты сервера (Hardening)     ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "Этот скрипт выполнит:"
echo -e "  1. Проверку наличия SSH-ключа (защита от случайной блокировки)"
echo -e "  2. Смену стандартного SSH-порта (отсекает 99% ботнетов)"
echo -e "  3. Отключение входа по паролю (только по криптографическим ключам)"
echo -e "  4. Настройку файрвола UFW (открыты только SSH и Xray)"
echo -e "  5. Установку и конфигурацию Fail2ban под новый порт SSH"
echo -e "  6. Включение автоматических обновлений безопасности (unattended-upgrades)"
echo -e "  7. Усиление сетевого стека sysctl (защита от SYN-flood, spoofing и др.)"
echo -e "${CYAN}================================================================${NC}\n"

# ------------------------------------------------------------------------------
# 2. Защита от дурака (Anti-Lockout Check): проверка SSH-ключей
# ------------------------------------------------------------------------------
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

# ------------------------------------------------------------------------------
# 3. Выбор порта SSH
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}▶ Шаг 2/7. Настройка порта SSH...${NC}"
DEFAULT_RANDOM_PORT=$((RANDOM % 30000 + 20000)) # Порт в безопасном диапазоне 20000-50000

echo -e "Стандартный порт 22 постоянно сканируют боты."
echo -e "Рекомендуется выбрать порт из диапазона 10000-60000."
echo -e "Нажмите Enter для использования сгенерированного случайного порта: ${GREEN}${DEFAULT_RANDOM_PORT}${NC},"
read -p "или введите свой желаемый порт: " INPUT_SSH_PORT

SSH_PORT="${INPUT_SSH_PORT:-$DEFAULT_RANDOM_PORT}"

# Проверка валидности порта
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || (( SSH_PORT < 1024 || SSH_PORT > 65535 )); then
    echo -e "${RED}[ОШИБКА] Порт должен быть числом от 1024 до 65535.${NC}"
    exit 1
fi
echo -e "${GREEN}✓ Выбран порт SSH: $SSH_PORT${NC}"

# ------------------------------------------------------------------------------
# 4. Проверка порта Xray для файрвола
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}▶ Шаг 3/7. Определение портов для файрвола...${NC}"
XRAY_PORT=443
if [[ -f "/usr/local/etc/xray/config.json" ]]; then
    DETECTED_PORT=$(jq -r '.inbounds[0].port // empty' /usr/local/etc/xray/config.json 2>/dev/null || true)
    if [[ -n "$DETECTED_PORT" && "$DETECTED_PORT" =~ ^[0-9]+$ ]]; then
        XRAY_PORT="$DETECTED_PORT"
        echo -e "${GREEN}✓ Обнаружен установленный Xray, использующий порт: $XRAY_PORT${NC}"
    fi
else
    echo -e "${YELLOW}ℹ Xray еще не установлен. Резервируем порт по умолчанию: $XRAY_PORT (https).${NC}"
fi

# ------------------------------------------------------------------------------
# 5. Установка необходимых пакетов
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}▶ Шаг 4/7. Обновление репозиториев и установка защитных утилит (ufw, fail2ban, unattended-upgrades)...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y ufw fail2ban unattended-upgrades curl jq

# ------------------------------------------------------------------------------
# 6. Конфигурация OpenSSH Daemon
# ------------------------------------------------------------------------------
echo -e "\n${BLUE}▶ Шаг 5/7. Настройка SSH демона (ключи, порт, отключение паролей)...${NC}"

# Делаем резервную копию sshd_config
cp /etc/ssh/sshd_config "/etc/ssh/sshd_config.bak.$(date +%F_%H%M%S)"

# В современных Ubuntu (22.04 / 24.04 / 26.04) настройки могут также лежать в sshd_config.d/
SSHD_HARDEN_CONF="/etc/ssh/sshd_config.d/99-xray-hardening.conf"
mkdir -p /etc/ssh/sshd_config.d/

cat << EOF > "$SSHD_HARDEN_CONF"
# Конфигурация безопасности Xray Advanced 42
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
