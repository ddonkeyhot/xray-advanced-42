#!/bin/bash
# ==============================================================================
# Script: install.sh (Xray Advanced 42 - Core Installer)
# Author: @ddonkeyhot & AI Assistant
# Description: Установщик Xray-core (VLESS-Reality + xHTTP packet-up),
#              Loyalsoldier GeoIP/GeoSite, RU Blackhole, выборочного Cloudflare WARP
#              и интерактивного TUI-управления.
# Флаги: --upgrade (обновление компонентов), --restore (чистый откат)
# ==============================================================================

set -euo pipefail

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

LOG_FILE="/var/log/xray-advanced-42/health.log"
BACKUP_DIR="/var/lib/xray-advanced-42/backup"
CONFIG_DIR="/usr/local/etc/xray"
CONFIG_FILE="$CONFIG_DIR/config.json"
REALITY_ENV="$CONFIG_DIR/reality.env"
SNI_FILE="$CONFIG_DIR/sni_pool.txt"

mkdir -p /var/log/xray-advanced-42
mkdir -p "$BACKUP_DIR"

log_msg() {
    local level="$1"
    local component="$2"
    local msg="$3"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] [$component] $msg" >> "$LOG_FILE"
}

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[ОШИБКА] Этот скрипт должен быть запущен с правами root (sudo).${NC}" >&2
    exit 1
fi

# ==============================================================================
# 1. РЕЖИМ ОТКАТА (--restore)
# ==============================================================================
if [[ "${1:-}" == "--restore" ]]; then
    clear
    echo -e "${RED}================================================================${NC}"
    echo -e "${RED}             ВНИМАНИЕ: ПОЛНОЕ УДАЛЕНИЕ XRAY ADVANCED 42          ${NC}"
    echo -e "${RED}================================================================${NC}"
    echo -e "Этот процесс полностью удалит Xray, базы и все утилиты:"
    echo -e "  1. Служба Xray будет остановлена и удалена из systemd."
    echo -e "  2. Каталоги /usr/local/etc/xray и /usr/local/share/xray будут стерты."
    echo -e "  3. Все CLI-команды (/usr/local/bin/xray*) будут удалены."
    echo -e "  4. Cron-задача обновления баз будет удалена."
    echo -e "${RED}----------------------------------------------------------------${NC}"
    echo -e "Чтобы подтвердить удаление, введите слово ${RED}RESTORE${NC} заглавными буквами:"
    read -r CONFIRM_INPUT

    if [[ "$CONFIRM_INPUT" != "RESTORE" ]]; then
        echo -e "${GREEN}[ОТМЕНА] Удаление отменено пользователем.${NC}"
        exit 0
    fi

    echo -e "\n${BLUE}▶ 1/4. Остановка и отключение службы Xray...${NC}"
    systemctl stop xray >/dev/null 2>&1 || true
    systemctl disable xray >/dev/null 2>&1 || true
    rm -f /etc/systemd/system/xray.service
    rm -f /etc/systemd/system/xray@.service
    systemctl daemon-reload

    echo -e "${BLUE}▶ 2/4. Удаление конфигураций и баз данных...${NC}"
    rm -rf /usr/local/etc/xray
    rm -rf /usr/local/share/xray
    rm -f /etc/cron.d/xray-geoip-update

    echo -e "${BLUE}▶ 3/4. Удаление CLI-команд...${NC}"
    rm -f /usr/local/bin/xray \
          /usr/local/bin/xray_menu \
          /usr/local/bin/userlist \
          /usr/local/bin/newuser \
          /usr/local/bin/show_problems \
          /usr/local/bin/xray_update_geoip \
          /usr/local/bin/xray_upgrade \
          /usr/local/bin/xray_help

    echo -e "${BLUE}▶ 4/4. Сброс логов...${NC}"
    log_msg "INFO" "RESTORE" "Выполнено полное удаление системы Xray Advanced 42."

    echo -e "\n${GREEN}================================================================${NC}"
    echo -e "${GREEN}            УДАЛЕНИЕ УСПЕШНО ЗАВЕРШЕНО                          ${NC}"
    echo -e "${GREEN}================================================================${NC}"
    echo -e "Система полностью очищена от компонентов Xray.\n"
    exit 0
fi

# ==============================================================================
# 2. РЕЖИМ ОБНОВЛЕНИЯ (--upgrade)
# ==============================================================================
if [[ "${1:-}" == "--upgrade" ]]; then
    if [[ -f "/usr/local/bin/xray_upgrade" ]]; then
        exec /usr/local/bin/xray_upgrade
    else
        echo -e "${RED}[ОШИБКА] Xray еще не установлен. Запустите скрипт без флагов для установки.${NC}"
        exit 1
    fi
fi

# ==============================================================================
# 3. ОСНОВНОЙ РЕЖИМ УСТАНОВКИ
# ==============================================================================
clear
echo -e "${CYAN}================================================================${NC}"
echo -e "${CYAN}        Xray Advanced 42 — Мастер развертывания сервера         ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "Стек технологий:"
echo -e "  • Протокол:    ${GREEN}VLESS + XTLS Reality${NC}"
echo -e "  • Транспорт:   ${GREEN}xHTTP (режим packet-up)${NC}"
echo -e "  • Защита IP:   ${GREEN}Blackhole для зоны .ru и IP РФ (Loyalsoldier)${NC}"
echo -e "  • Режим WARP:  ${GREEN}Cloudflare Wireguard outbound (индивидуально)${NC}"
echo -e "  • Управление:  ${GREEN}Интерактивный TUI дашборд и CLI утилиты${NC}"
echo -e "${CYAN}================================================================${NC}\n"

# Шаг 1: Системные пакеты
echo -e "${BLUE}▶ [1/7] Установка системных зависимостей...${NC}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y >/dev/null 2>&1 || true
apt-get install -y curl jq qrencode wireguard-tools git coreutils util-linux unzip openssl >/dev/null 2>&1
MISSING_PKGS=""
for cmd in curl jq qrencode wg git unzip openssl; do
    if ! command -v $cmd >/dev/null 2>&1; then
        MISSING_PKGS="$MISSING_PKGS $cmd"
    fi
done

if [[ -n "$MISSING_PKGS" ]]; then
    echo -e "${RED}[ОШИБКА] Не удалось установить следующие утилиты: $MISSING_PKGS${NC}"
    echo -e "Пожалуйста, установите их вручную: sudo apt-get update \&\& sudo apt-get install -y curl jq qrencode wireguard-tools git unzip openssl"
    exit 1
fi

echo -e "${GREEN}[✓] Зависимости установлены.${NC}"

# Шаг 2: Установка Xray-core
echo -e "\n${BLUE}▶ [2/7] Установка ядра Xray-core последней версии...${NC}"
if ! bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" - install; then
    echo -e "${RED}[ОШИБКА] Не удалось установить Xray-core. Проверьте вывод выше.${NC}"
    exit 1
fi
if [[ ! -f /usr/local/bin/xray ]]; then
    echo -e "${RED}[ОШИБКА] Исполняемый файл /usr/local/bin/xray не найден после установки.${NC}"
    exit 1
fi
echo -e "${GREEN}[✓] Ядро Xray-core успешно установлено ($(/usr/local/bin/xray version | head -n 1 | awk '{print $2}')).${NC}"

# Шаг 3: Скачивание баз Loyalsoldier
echo -e "\n${BLUE}▶ [3/7] Загрузка баз маршрутизации GeoIP и GeoSite (Loyalsoldier)...${NC}"
mkdir -p /usr/local/share/xray
TMP_GEO=$(mktemp -d)
curl -fsSL --connect-timeout 10 https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat -o "$TMP_GEO/geoip.dat"
curl -fsSL --connect-timeout 10 https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geosite.dat -o "$TMP_GEO/geosite.dat"
mv "$TMP_GEO/geoip.dat" /usr/local/share/xray/geoip.dat
mv "$TMP_GEO/geosite.dat" /usr/local/share/xray/geosite.dat
rm -rf "$TMP_GEO"
echo -e "${GREEN}[✓] Базы маршрутизации установлены.${NC}"

# Еженедельный крон
cat << 'CRON_EOF' > /etc/cron.d/xray-geoip-update
15 3 * * 1 root /usr/local/bin/xray_update_geoip >/dev/null 2>&1
CRON_EOF
chmod 644 /etc/cron.d/xray-geoip-update

# Шаг 4: Ключи Reality
echo -e "\n${BLUE}▶ [4/7] Настройка криптографических ключей Reality...${NC}"
mkdir -p "$CONFIG_DIR"

if [[ ! -f "$REALITY_ENV" ]]; then
    if ! KEY_PAIR=$(/usr/local/bin/xray x25519 2>&1); then
        echo -e "${RED}[ОШИБКА] Команда xray x25519 завершилась с ошибкой:${NC}\n$KEY_PAIR"
        exit 1
    fi
    # Отлавливаем ошибки grep через || true, чтобы скрипт не упал по set -e
    PRIVATE_KEY=$(echo "$KEY_PAIR" | grep -i 'Private' | awk -F':' '{print $2}' | tr -d ' ' || true)
    PUBLIC_KEY=$(echo "$KEY_PAIR" | grep -i 'Public' | awk -F':' '{print $2}' | tr -d ' ' || true)
    SHORT_ID=$(openssl rand -hex 8 || tr -dc 'a-f0-9' < /dev/urandom | head -c 16) || true

    if [[ -z "$PRIVATE_KEY" || -z "$PUBLIC_KEY" ]]; then
        echo -e "${RED}[ОШИБКА] Не удалось распарсить ключи из вывода Xray:${NC}\n$KEY_PAIR"
        exit 1
    fi

    cat << ENV_EOF > "$REALITY_ENV"
PRIVATE_KEY="$PRIVATE_KEY"
PUBLIC_KEY="$PUBLIC_KEY"
SHORT_ID="$SHORT_ID"
ENV_EOF
    chmod 600 "$REALITY_ENV"
    echo -e "${GREEN}[✓] Сгенерированы новые ключи Reality.${NC}"
else
    source "$REALITY_ENV"
    echo -e "${GREEN}[✓] Загружены существующие ключи Reality.${NC}"
fi

# Пул SNI
cat << 'SNI_EOF' > "$SNI_FILE"
gateway.icloud.com
swdist.apple.com
appldnld.apple.com
configuration.apple.com
SNI_EOF

# Шаг 5: Регистрация Cloudflare WARP
echo -e "\n${BLUE}▶ [5/7] Регистрация Cloudflare WARP (Wireguard Outbound)...${NC}"
WARP_CONFIG_AVAILABLE=false
WARP_PRIVATE_KEY=""
WARP_IPV4=""
WARP_IPV6=""
WARP_PEER_PUBKEY="bmXOC+F1FxEMF9dyiK2H5/1SUtzHZsVoW++ZKgukR2g="

WARP_LOCAL_PRIV=$(wg genkey)
WARP_LOCAL_PUB=$(echo "$WARP_LOCAL_PRIV" | wg pubkey)

WARP_RESP=$(curl -s -X POST "https://api.cloudflareclient.com/v0a1922/reg" \
    -H "User-Agent: okhttp/3.12.1" \
    -H "Content-Type: application/json; charset=UTF-8" \
    -d "{\"key\":\"${WARP_LOCAL_PUB}\",\"install_id\":\"\",\"fcm_token\":\"\",\"tos\":\"$(date -u +%Y-%m-%dT%H:%M:%S.000Z)\",\"model\":\"PC\",\"serial_number\":\"\",\"locale\":\"en_US\"}" || true)

if echo "$WARP_RESP" | jq -e '.result.id' >/dev/null 2>&1; then
    WARP_PRIVATE_KEY="$WARP_LOCAL_PRIV"
    WARP_IPV4=$(echo "$WARP_RESP" | jq -r '.result.config.interface.addresses.v4')
    WARP_IPV6=$(echo "$WARP_RESP" | jq -r '.result.config.interface.addresses.v6')
    WARP_CONFIG_AVAILABLE=true
    echo -e "${GREEN}[✓] Учетная запись Cloudflare WARP зарегистрирована (IPv4: $WARP_IPV4).${NC}"
    log_msg "INFO" "WARP" "WARP успешно зарегистрирован (IP: $WARP_IPV4)"
else
    echo -e "${YELLOW}[!] Не удалось связаться с API (таймаут). Сервер продолжит работу в режиме Direct.${NC}"
    log_msg "WARN" "WARP" "Таймаут обращения к Cloudflare API. Активирован режим Direct."
fi

# Шаг 6: Генерация config.json
echo -e "\n${BLUE}▶ [6/7] Сборка и валидация конфигурации Xray...${NC}"
cat << CONF_EOF > "$CONFIG_FILE"
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "servers": [
      "1.1.1.1",
      "8.8.8.8",
      "localhost"
    ]
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "xhttp",
        "xhttpSettings": {
          "path": "/download",
          "mode": "packet-up"
        },
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "gateway.icloud.com:443",
          "xver": 0,
          "serverNames": [
            "gateway.icloud.com",
            "swdist.apple.com",
            "appldnld.apple.com",
            "configuration.apple.com"
          ],
          "privateKey": "$PRIVATE_KEY",
          "shortIds": [
            "$SHORT_ID"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"]
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "tag": "direct",
      "settings": {
        "domainStrategy": "UseIPv4"
      }
    },
    {
      "protocol": "blackhole",
      "tag": "block"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "outboundTag": "block",
        "domain": [
          "geosite:category-ru"
        ]
      },
      {
        "type": "field",
        "outboundTag": "block",
        "ip": [
          "geoip:ru",
          "geoip:private"
        ]
      },
      {
        "type": "field",
        "outboundTag": "warp",
        "user": ["user1"]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "network": "tcp,udp"
      }
    ]
  }
}
CONF_EOF

if [[ "$WARP_CONFIG_AVAILABLE" = true ]]; then
    WARP_OUTBOUND=$(jq -n \
        --arg priv "$WARP_PRIVATE_KEY" \
        --arg pub "$WARP_PEER_PUBKEY" \
        --arg ip4 "$WARP_IPV4/32" \
        --arg ip6 "$WARP_IPV6/128" \
        '{
          protocol: "wireguard",
          tag: "warp",
          settings: {
            secretKey: $priv,
            address: [$ip4, $ip6],
            peers: [
              {
                publicKey: $pub,
                endpoint: "162.159.192.1:2408",
                keepAlive: 25
              }
            ]
          }
        }')
    TMP_CFG=$(mktemp)
    jq --argjson warp "$WARP_OUTBOUND" '.outbounds += [$warp]' "$CONFIG_FILE" > "$TMP_CFG" && mv "$TMP_CFG" "$CONFIG_FILE"
fi

if ! /usr/local/bin/xray -test -config "$CONFIG_FILE"; then
    echo -e "${RED}[ОШИБКА] Конфигурация Xray не прошла проверку синтаксиса!${NC}"
    exit 1
fi

systemctl enable xray
systemctl restart xray
echo -e "${GREEN}[✓] Служба Xray запущена и добавлена в автозагрузку.${NC}"

# Шаг 7: Установка CLI-утилит
echo -e "\n${BLUE}▶ [7/7] Развертывание CLI-утилит в /usr/local/bin/...${NC}"
# Если скрипт запущен локально из клонированного репозитория:
if [[ -d "./bin" && -f "./bin/xray_menu" ]]; then
    cp -r ./bin/* /usr/local/bin/
# Если скрипт запущен удаленно через curl:
else
    echo -e "▶ Скачивание утилит из репозитория GitHub..."
    TMP_BIN=$(mktemp -d)
    curl -sL https://github.com/ddonkeyhot/xray-advanced-42/archive/refs/heads/main.tar.gz | tar -xz -C "$TMP_BIN" --strip-components=1
    cp -r "$TMP_BIN/bin/"* /usr/local/bin/
    rm -rf "$TMP_BIN"
fi
chmod +x /usr/local/bin/*
ln -sf /usr/local/bin/xray_menu /usr/local/bin/xray || true
echo -e "${GREEN}[✓] Утилиты (xray_menu, userlist, newuser, show_problems, xray_update_geoip, xray_upgrade, xray_help) установлены.${NC}"

log_msg "INFO" "INSTALL" "Сервер успешно установлен и запущен на порту 443."

echo -e "\n${CYAN}================================================================${NC}"
echo -e "${GREEN}          УСТАНОВКА СЕРВЕРА УСПЕШНО ЗАВЕРШЕНА!                 ${NC}"
echo -e "${CYAN}================================================================${NC}"
echo -e "Теперь сервер готов к работе."
echo -e "Создать первого пользователя прямо сейчас? [Y/n]: "
read -r CREATE_FIRST

if [[ -z "$CREATE_FIRST" || "$CREATE_FIRST" =~ ^[yYдД]$ ]]; then
    newuser
fi

echo -e "\n${CYAN}================================================================${NC}"
echo -e "Управление сервером в любое время: команда ${GREEN}xray${NC} или ${GREEN}xray_menu${NC}"
echo -e "Справка по всем командам:          команда ${GREEN}xray_help${NC}"
echo -e "${CYAN}================================================================${NC}\n"
