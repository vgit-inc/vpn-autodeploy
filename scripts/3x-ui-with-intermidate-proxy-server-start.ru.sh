#!/usr/bin/env bash
# ============================================================
# 3x-ui Auto Deploy Script (v4 — интерактивный ввод)
# Запуск: sudo bash <(curl -Ls https://raw.githubusercontent.com/<USER>/<REPO>/main/deploy-proxy.sh)
# ============================================================
set -euo pipefail

# ---------- Если запущено через pipe — перезапустить из файла ----------
# Детект: stdin — не терминал (pipe из curl) И это не перенаправление из файла
if [[ ! -t 0 ]] && [[ -z "${__SELF_RELAUNCHED:-}" ]]; then
  echo "[+] Обнаружен запуск через pipe. Перезапуск из файла..."
  __TMP_SCRIPT="$(mktemp /tmp/deploy-proxy.XXXXXX.sh)"
  cat > "$__TMP_SCRIPT"
  chmod +x "$__TMP_SCRIPT"
  export __SELF_RELAUNCHED=1
  exec sudo -E bash "$__TMP_SCRIPT" "$@"
fi

# ---------- Самоперезапуск от root ----------
if [[ $EUID -ne 0 ]]; then
  echo "[!] Требуется root. Перезапуск через sudo..."
  exec sudo -E bash "$0" "$@"
fi

# ---------- Цвета ----------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[x]${NC} $*" >&2; }

# ---------- Чтение из терминала (даже если stdin занят pipe) ----------
TTY=/dev/tty
if [[ ! -e "$TTY" ]]; then
  err "Нет доступа к $TTY. Запустите скрипт из интерактивной сессии."
  exit 1
fi

# prompt <переменная> <текст> [default] [silent]
prompt() {
  local __var="$1" __text="$2" __default="${3:-}" __silent="${4:-}"
  local __value=""
  while true; do
    if [[ -n "$__default" ]]; then
      printf "%b" "${BLUE}?${NC} ${__text} [${__default}]: " > "$TTY"
    else
      printf "%b" "${BLUE}?${NC} ${__text}: " > "$TTY"
    fi
    if [[ "$__silent" == "silent" ]]; then
      IFS= read -rs __value < "$TTY" || true
      echo > "$TTY"
    else
      IFS= read -r __value < "$TTY" || true
    fi
    [[ -z "$__value" && -n "$__default" ]] && __value="$__default"
    [[ -n "$__value" ]] && break
    echo -e "${RED}  Поле обязательно для заполнения.${NC}" > "$TTY"
  done
  printf -v "$__var" '%s' "$__value"
}

validate_ip() {
  local ip="$1"
  if [[ ! "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo -e "${RED}  Некорректный IP: $ip${NC}" > "$TTY"
    return 1
  fi
  local o
  IFS='.' read -ra o <<< "$ip"
  for n in "${o[@]}"; do
    if (( n < 0 || n > 255 )); then
      echo -e "${RED}  Некорректный октет: $n${NC}" > "$TTY"
      return 1
    fi
  done
  return 0
}

validate_port() {
  local p="$1"
  [[ "$p" =~ ^[0-9]+$ ]] && (( p >= 1 && p <= 65535 ))
}

prompt_ip() {
  local __var="$1" __text="$2"
  local __value=""
  while true; do
    printf "%b" "${BLUE}?${NC} ${__text}: " > "$TTY"
    IFS= read -r __value < "$TTY" || true
    if validate_ip "$__value"; then break; fi
  done
  printf -v "$__var" '%s' "$__value"
}

prompt_port() {
  local __var="$1" __text="$2"
  local __value=""
  while true; do
    printf "%b" "${BLUE}?${NC} ${__text}: " > "$TTY"
    IFS= read -r __value < "$TTY" || true
    if validate_port "$__value"; then break; fi
    echo -e "${RED}  Порт должен быть числом от 1 до 65535.${NC}" > "$TTY"
  done
  printf -v "$__var" '%s' "$__value"
}

# ---------- Интерактивный опрос ----------
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}   3x-ui Auto Deploy — ввод параметров${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""

prompt_ip   SERVER_IP        "IP текущего сервера"
prompt_ip   INTERMEDIATE_IP  "IP промежуточного сервера"
prompt_port CONNECT_PORT     "Порт для VLESS TLS (подключения)"
prompt_port PANEL_PORT       "Порт панели 3x-ui"
prompt      PANEL_USER       "Логин панели 3x-ui"
prompt      PANEL_PASSWORD   "Пароль панели 3x-ui" "" silent

echo ""
echo -e "${BLUE}----------------------------------------${NC}"
echo -e "  IP сервера:        ${GREEN}$SERVER_IP${NC}"
echo -e "  IP промежуточного: ${GREEN}$INTERMEDIATE_IP${NC}"
echo -e "  Порт подключений:  ${GREEN}$CONNECT_PORT${NC}"
echo -e "  Порт панели:       ${GREEN}$PANEL_PORT${NC}"
echo -e "  Логин панели:      ${GREEN}$PANEL_USER${NC}"
echo -e "  Пароль панели:     ${GREEN}********${NC}"
echo -e "${BLUE}----------------------------------------${NC}"
printf "%b" "${BLUE}?${NC} Всё верно? Начинаем установку? [y/N]: " > "$TTY"
IFS= read -r CONFIRM < "$TTY" || true
if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
  warn "Отменено пользователем."
  exit 0
fi
echo ""

# ---------- Генерация секретов ----------
CERT_DIR="/root/cert/ip"
CLIENT_UUID="$(cat /proc/sys/kernel/random/uuid)"
SUB_ID="$(tr -dc 'a-z0-9' < /dev/urandom | head -c 16)"
HY2_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom | head -c 16)"

# ---------- 1. Обновление системы и зависимости ----------
log "Обновление системы и установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget tar ufw jq openssl cron socat >/dev/null 2>&1

# ---------- 2. Установка 3x-ui ----------
if command -v x-ui >/dev/null 2>&1 || systemctl is-active --quiet x-ui 2>/dev/null; then
  warn "3x-ui уже установлен. Пропускаем установку."
else
  log "Установка 3x-ui (неинтерактивный режим)..."
  export XUI_NONINTERACTIVE=1
  export XUI_USERNAME="$PANEL_USER"
  export XUI_PASSWORD="$PANEL_PASSWORD"
  export XUI_PORT="$PANEL_PORT"
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) >/dev/null 2>&1
  unset XUI_NONINTERACTIVE XUI_USERNAME XUI_PASSWORD XUI_PORT
  log "3x-ui установлен."
fi

# ---------- 3. Файрвол ----------
log "Настройка UFW..."
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null 2>&1 || true
ufw default allow outgoing >/dev/null 2>&1 || true
ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1 || true
ufw allow "$PANEL_PORT/tcp" comment '3x-ui panel' >/dev/null 2>&1 || true
ufw allow 80/tcp comment "Let's Encrypt HTTP-01" >/dev/null 2>&1 || true
ufw allow 443/tcp comment 'VLESS main' >/dev/null 2>&1 || true
ufw allow 8443/udp comment 'Hysteria2' >/dev/null 2>&1 || true
ufw allow "$CONNECT_PORT/tcp" comment 'VLESS connect' >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true
systemctl enable ufw >/dev/null 2>&1 || true
log "UFW настроен и сохранён."

# ---------- 4. Запуск 3x-ui ----------
log "Запуск 3x-ui..."
systemctl enable x-ui >/dev/null 2>&1 || true
systemctl restart x-ui >/dev/null 2>&1 || true
sleep 5

# ---------- 5. SSL-сертификат для IP ----------
log "Установка и настройка acme.sh для IP-сертификата..."
if [[ ! -f ~/.acme.sh/acme.sh ]]; then
  curl -s https://get.acme.sh | sh -s email=admin@localhost >/dev/null 2>&1
fi

log "Выпуск Let's Encrypt сертификата для IP $SERVER_IP..."
~/.acme.sh/acme.sh --issue \
  -d "$SERVER_IP" \
  --standalone \
  --server letsencrypt \
  --certificate-profile shortlived \
  --days 5 \
  --httpport 80 >/dev/null 2>&1 || warn "Не удалось выпустить сертификат. Проверьте, что порт 80 открыт."

log "Установка сертификата в $CERT_DIR..."
mkdir -p "$CERT_DIR"
~/.acme.sh/acme.sh --installcert -d "$SERVER_IP" \
  --certpath "$CERT_DIR/cert.pem" \
  --keypath "$CERT_DIR/privkey.pem" \
  --capath "$CERT_DIR/ca.pem" \
  --fullchainpath "$CERT_DIR/fullchain.pem" \
  --reloadcmd "x-ui restart" >/dev/null 2>&1 || warn "Не удалось установить сертификат."

~/.acme.sh/acme.sh --upgrade --auto-upgrade >/dev/null 2>&1 || true
log "Сертификат установлен. Авто-обновление включено (cron)."

# ---------- 6. Настройка панели на сертификат ----------
log "Настройка путей к сертификату для панели 3x-ui..."
/usr/local/x-ui/x-ui cert -webCert "$CERT_DIR/fullchain.pem" -webCertKey "$CERT_DIR/privkey.pem" >/dev/null 2>&1 || true

# ---------- 7. Создание inbound'ов через API ----------
log "Подключение к API панели..."
COOKIE_JAR=$(mktemp)
for i in $(seq 1 20); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:$PANEL_PORT/panel/" || true)
  if [[ "$HTTP_CODE" =~ ^(200|302|401)$ ]]; then break; fi
  sleep 2
done

curl -s -c "$COOKIE_JAR" -X POST "http://127.0.0.1:$PANEL_PORT/panel/login" \
  -d "username=$PANEL_USER&password=$PANEL_PASSWORD" >/dev/null 2>&1 || true

# --- Inbound 1: VLESS Internal ---
log "Создание VLESS Internal (2026, localhost)..."
curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:$PANEL_PORT/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -d "{
    \"listen\": \"127.0.0.1\",
    \"port\": 2026,
    \"protocol\": \"vless\",
    \"tag\": \"in-2026-tcp\",
    \"settings\": {
      \"clients\": [],
      \"decryption\": \"none\",
      \"encryption\": \"none\",
      \"testseed\": [900, 500, 900, 256]
    },
    \"sniffing\": { \"enabled\": false },
    \"streamSettings\": {
      \"network\": \"tcp\",
      \"tcpSettings\": {
        \"acceptProxyProtocol\": true,
        \"header\": { \"type\": \"none\" }
      },
      \"security\": \"none\"
    }
  }" >/dev/null 2>&1 || warn "Не удалось создать VLESS Internal."

# --- Inbound 2: Hysteria2 ---
log "Создание Hysteria2 (8443/udp)..."
curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:$PANEL_PORT/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -d "{
    \"listen\": \"\",
    \"port\": 8443,
    \"protocol\": \"hysteria\",
    \"tag\": \"in-8443-udp\",
    \"settings\": { \"clients\": [], \"version\": 2 },
    \"sniffing\": { \"enabled\": false },
    \"streamSettings\": {
      \"network\": \"hysteria\",
      \"hysteriaSettings\": {
        \"version\": 2,
        \"udpIdleTimeout\": 60,
        \"masquerade\": {
          \"type\": \"\", \"dir\": \"\", \"url\": \"\", \"rewriteHost\": false,
          \"insecure\": false, \"content\": \"\", \"headers\": {}, \"statusCode\": 0
        }
      },
      \"security\": \"tls\",
      \"tlsSettings\": {
        \"serverName\": \"$SERVER_IP\",
        \"minVersion\": \"1.2\",
        \"maxVersion\": \"1.3\",
        \"cipherSuites\": \"\",
        \"rejectUnknownSni\": false,
        \"disableSystemRoot\": false,
        \"enableSessionResumption\": false,
        \"certificates\": [{
          \"certificateFile\": \"$CERT_DIR/fullchain.pem\",
          \"keyFile\": \"$CERT_DIR/privkey.pem\",
          \"ocspStapling\": 0,
          \"oneTimeLoading\": false,
          \"usage\": \"encipherment\",
          \"buildChain\": false,
          \"useFile\": true
        }],
        \"alpn\": [\"h3\", \"h2\", \"http/1.1\"],
        \"echServerKeys\": \"\",
        \"settings\": {
          \"fingerprint\": \"firefox\",
          \"echConfigList\": \"\",
          \"pinnedPeerCertSha256\": [],
          \"verifyPeerCertByName\": \"\"
        }
      },
      \"finalmask\": {
        \"udp\": [{
          \"type\": \"salamander\",
          \"settings\": { \"password\": \"$HY2_PASSWORD\" }
        }]
      }
    }
  }" >/dev/null 2>&1 || warn "Не удалось создать Hysteria2."

# --- Inbound 3: VLESS TLS ---
log "Создание VLESS TLS ($CONNECT_PORT/tcp)..."
curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:$PANEL_PORT/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -d "{
    \"listen\": \"\",
    \"port\": $CONNECT_PORT,
    \"protocol\": \"vless\",
    \"tag\": \"in-$CONNECT_PORT-tcp\",
    \"settings\": {
      \"clients\": [],
      \"decryption\": \"none\",
      \"encryption\": \"none\",
      \"testseed\": [900, 500, 900, 256]
    },
    \"sniffing\": { \"enabled\": false },
    \"streamSettings\": {
      \"network\": \"tcp\",
      \"tcpSettings\": {
        \"acceptProxyProtocol\": false,
        \"header\": { \"type\": \"none\" }
      },
      \"security\": \"tls\",
      \"tlsSettings\": {
        \"serverName\": \"$SERVER_IP\",
        \"minVersion\": \"1.2\",
        \"maxVersion\": \"1.3\",
        \"cipherSuites\": \"\",
        \"rejectUnknownSni\": false,
        \"disableSystemRoot\": false,
        \"enableSessionResumption\": false,
        \"certificates\": [{
          \"certificateFile\": \"$CERT_DIR/fullchain.pem\",
          \"keyFile\": \"$CERT_DIR/privkey.pem\",
          \"ocspStapling\": 0,
          \"oneTimeLoading\": false,
          \"usage\": \"encipherment\",
          \"buildChain\": false,
          \"useFile\": true
        }],
        \"alpn\": [\"h2\", \"http/1.1\"],
        \"echServerKeys\": \"\",
        \"settings\": {
          \"fingerprint\": \"firefox\",
          \"echConfigList\": \"\",
          \"pinnedPeerCertSha256\": [],
          \"verifyPeerCertByName\": \"\"
        }
      }
    }
  }" >/dev/null 2>&1 || warn "Не удалось создать VLESS TLS."

# ---------- 8. Клиенты ----------
log "Получение списка inbound'ов..."
INBOUNDS_JSON=$(curl -s -b "$COOKIE_JAR" "http://127.0.0.1:$PANEL_PORT/panel/api/inbounds/list" 2>/dev/null || echo '{}')
INBOUND_2026_ID=$(echo "$INBOUNDS_JSON" | jq -r '.obj[] | select(.tag=="in-2026-tcp") | .id' 2>/dev/null || true)
INBOUND_8443_ID=$(echo "$INBOUNDS_JSON" | jq -r '.obj[] | select(.tag=="in-8443-udp") | .id' 2>/dev/null || true)
INBOUND_CONNECT_ID=$(echo "$INBOUNDS_JSON" | jq -r ".obj[] | select(.tag==\"in-$CONNECT_PORT-tcp\") | .id" 2>/dev/null || true)

if [[ -n "$INBOUND_2026_ID" && "$INBOUND_2026_ID" != "null" ]]; then
  log "Добавление клиента в VLESS Internal..."
  curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:$PANEL_PORT/panel/api/inbounds/addClient" \
    -H "Content-Type: application/json" \
    -d "{\"id\": $INBOUND_2026_ID, \"settings\": \"{\\\"clients\\\":[{\\\"id\\\":\\\"$CLIENT_UUID\\\",\\\"email\\\":\\\"user@local\\\",\\\"subId\\\":\\\"$SUB_ID\\\"}]}\"}" \
    >/dev/null 2>&1 || warn "Не удалось добавить клиента в VLESS Internal."
fi

if [[ -n "$INBOUND_CONNECT_ID" && "$INBOUND_CONNECT_ID" != "null" ]]; then
  log "Добавление клиента в VLESS TLS..."
  curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:$PANEL_PORT/panel/api/inbounds/addClient" \
    -H "Content-Type: application/json" \
    -d "{\"id\": $INBOUND_CONNECT_ID, \"settings\": \"{\\\"clients\\\":[{\\\"id\\\":\\\"$CLIENT_UUID\\\",\\\"email\\\":\\\"user@local\\\",\\\"subId\\\":\\\"$SUB_ID\\\"}]}\"}" \
    >/dev/null 2>&1 || warn "Не удалось добавить клиента в VLESS TLS."
fi

if [[ -n "$INBOUND_8443_ID" && "$INBOUND_8443_ID" != "null" ]]; then
  log "Добавление клиента в Hysteria2..."
  curl -s -b "$COOKIE_JAR" -X POST "http://127.0.0.1:$PANEL_PORT/panel/api/inbounds/addClient" \
    -H "Content-Type: application/json" \
    -d "{\"id\": $INBOUND_8443_ID, \"settings\": \"{\\\"clients\\\":[{\\\"password\\\":\\\"$HY2_PASSWORD\\\",\\\"email\\\":\\\"user@local\\\",\\\"subId\\\":\\\"$SUB_ID\\\"}]}\"}" \
    >/dev/null 2>&1 || warn "Не удалось добавить клиента в Hysteria2."
fi

rm -f "$COOKIE_JAR"

# ---------- 9. Ссылки ----------
SUB_URL="http://$SERVER_IP:$PANEL_PORT/sub/$SUB_ID"
VLESS_INTERNAL_LINK="vless://$CLIENT_UUID@$SERVER_IP:2026?type=tcp&security=none&encryption=none#VLESS-Internal"
VLESS_CONNECT_LINK="vless://$CLIENT_UUID@$SERVER_IP:$CONNECT_PORT?type=tcp&security=tls&encryption=none&sni=$SERVER_IP&fp=firefox#VLESS-TLS"
HY2_LINK="hysteria2://$HY2_PASSWORD@$SERVER_IP:8443?insecure=1&sni=$SERVER_IP#Hysteria2"

# ---------- 10. Итог ----------
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✅ Развёртывание завершено!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "  🌐 Панель:     ${GREEN}http://$SERVER_IP:$PANEL_PORT/panel${NC}"
echo -e "  👤 Логин:      ${GREEN}$PANEL_USER${NC}"
echo -e "  🔑 Пароль:     ${GREEN}$PANEL_PASSWORD${NC}"
echo ""
echo -e "  📡 Inbound'ы:"
echo -e "     • VLESS Internal:  порт ${GREEN}2026${NC} (127.0.0.1)"
echo -e "     • Hysteria2:       порт ${GREEN}8443/udp${NC} (0.0.0.0)"
echo -e "     • VLESS TLS:       порт ${GREEN}$CONNECT_PORT/tcp${NC} (0.0.0.0)"
echo ""
echo -e "  🔗 Ссылка подписки:"
echo -e "     ${YELLOW}$SUB_URL${NC}"
echo ""
echo -e "  🔗 Прямые подключения:"
echo -e "     VLESS Internal: ${YELLOW}$VLESS_INTERNAL_LINK${NC}"
echo -e "     VLESS TLS:      ${YELLOW}$VLESS_CONNECT_LINK${NC}"
echo -e "     Hysteria2:      ${YELLOW}$HY2_LINK${NC}"
echo ""
echo -e "${YELLOW}⚠️  Скопируй ссылки — subId больше не будет показан.${NC}"
echo ""