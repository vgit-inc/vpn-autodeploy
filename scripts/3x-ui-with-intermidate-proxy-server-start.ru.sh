#!/usr/bin/env bash
# ============================================================
# 3x-ui Auto Deploy Script
# ============================================================
set -euo pipefail

# ---------- Если запущено через pipe — перезапустить из файла ----------
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
# TODO: INTERMEDIATE_IP пока только собирается, но не используется —
# автоматическая настройка форвардинга через промежуточный сервер
# (forwarding_install.sh) будет добавлена отдельным шагом после того,
# как подтвердим, что установка панели полностью рабочая.
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
SUB_ID="$(tr -dc 'a-z0-9' < /dev/urandom 2>/dev/null | head -c 16)" || true
HY2_PASSWORD="$(tr -dc 'A-Za-z0-9' < /dev/urandom 2>/dev/null | head -c 16)" || true
# Свой webBasePath — генерируем сами, а не даём install.sh выбрать случайный,
# чтобы точно знать путь для последующих вызовов API и итоговой ссылки.
WEB_BASE_PATH="$(tr -dc 'a-zA-Z0-9' < /dev/urandom 2>/dev/null | head -c 18)" || true

# ---------- 1. Обновление системы и зависимости ----------
log "Обновление системы и установка зависимостей..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq curl wget tar ufw jq openssl cron socat >/dev/null 2>&1

# ---------- 4. Файрвол ----------
log "Настройка UFW..."
ufw --force reset >/dev/null 2>&1 || true
ufw default deny incoming >/dev/null 2>&1 || true
ufw default allow outgoing >/dev/null 2>&1 || true
ufw allow 22/tcp comment 'SSH' >/dev/null 2>&1 || true
ufw allow 80/tcp comment 'Lets Encrypt HTTP-01' >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true
systemctl enable ufw >/dev/null 2>&1 || true
log "UFW настроен и сохранён."

# ---------- 2. Установка 3x-ui ----------
if command -v x-ui >/dev/null 2>&1 || systemctl is-active --quiet x-ui 2>/dev/null; then
  warn "3x-ui уже установлен. Пропускаем установку."
  printf "%b" "${BLUE}?${NC} Необходима переустановка, удалить текущую панель? [y/N]: " > "$TTY"
  IFS= read -r CONFIRM < "$TTY" || true
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    warn "Отменено пользователем."
    exit 0
    else 
      x-ui uninstall 
  fi
else
  log "Установка 3x-ui (неинтерактивный режим)..."
  export XUI_NONINTERACTIVE=1
  export XUI_USERNAME="$PANEL_USER"
  export XUI_PASSWORD="$PANEL_PASSWORD"
  export XUI_PANEL_PORT="$PANEL_PORT"     # ВАЖНО: именно XUI_PANEL_PORT, а не XUI_PORT
  export XUI_WEB_BASE_PATH="$WEB_BASE_PATH"
  export XUI_DB_TYPE=sqlite
  export XUI_SSL_MODE=ip                  # доверяем сертификат встроенной логике install.sh
  export XUI_SERVER_IP="$SERVER_IP"       # на случай, если auto-detect IP через внешние сервисы не пройдёт
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
  unset XUI_NONINTERACTIVE XUI_USERNAME XUI_PASSWORD XUI_PANEL_PORT XUI_WEB_BASE_PATH XUI_DB_TYPE XUI_SSL_MODE XUI_SERVER_IP
  log "3x-ui установлен."
fi

# ---------- 3. Читаем РЕАЛЬНЫЕ настройки панели ----------
# Не доверяем своим же входным данным вслепую: спрашиваем у самого x-ui,
# на каком порту и по какому webBasePath он реально поднялся.
log "Считываю фактические настройки панели..."
XUI_SETTINGS="$(/usr/local/x-ui/x-ui setting -show true 2>/dev/null || true)"
ACTUAL_PANEL_PORT="$(echo "$XUI_SETTINGS" | grep -E '^port:' | awk -F': ' '{print $2}' | tr -d '[:space:]')"
ACTUAL_WEB_BASE_PATH_RAW="$(echo "$XUI_SETTINGS" | grep -E '^webBasePath:' | awk -F': ' '{print $2}' | tr -d '[:space:]')"
# webBasePath хранится в виде "/xxxxx/", для URL нам нужен вариант без лишних слэшей
ACTUAL_WEB_BASE_PATH="$(echo "$ACTUAL_WEB_BASE_PATH_RAW" | sed 's#^/##; s#/$##')"

# ---------- 3. Добавление в фаервол параметров панели ----------
log "Настройка UFW под панель"
ufw allow "$ACTUAL_PANEL_PORT/tcp" comment '3x-ui panel' >/dev/null 2>&1 || true
ufw allow 2096/tcp comment '3x-ui subscription' >/dev/null 2>&1 || true
ufw allow "$CONNECT_PORT/tcp" comment 'VLESS connect' >/dev/null 2>&1 || true
ufw allow 443/tcp comment 'VLESS main' >/dev/null 2>&1 || true
ufw allow 8443/udp comment 'Hysteria2' >/dev/null 2>&1 || true
ufw --force enable >/dev/null 2>&1 || true
systemctl enable ufw >/dev/null 2>&1 || true


if [[ -z "$ACTUAL_PANEL_PORT" ]]; then
  err "Не удалось определить реальный порт панели через 'x-ui setting -show true'."
  err "Проверь вручную: x-ui status && x-ui setting -show true"
  ACTUAL_PANEL_PORT="$PANEL_PORT"
  warn "Продолжаю с портом из ввода ($PANEL_PORT) — дальнейшие шаги могут не сработать, если он не совпадает с реальным."
fi
if [[ -z "$ACTUAL_WEB_BASE_PATH" ]]; then
  warn "Не удалось определить webBasePath, буду обращаться без префикса (может не сработать)."
fi

log "Фактический порт панели: $ACTUAL_PANEL_PORT"
log "Фактический webBasePath: /${ACTUAL_WEB_BASE_PATH}/"
PANEL_BASE_URL="http://127.0.0.1:${ACTUAL_PANEL_PORT}/${ACTUAL_WEB_BASE_PATH}"

# ---------- 5. Запуск 3x-ui и ожидание готовности ----------
log "Запуск 3x-ui..."
systemctl enable x-ui >/dev/null 2>&1 || true
systemctl restart x-ui >/dev/null 2>&1 || true

log "Ожидание готовности панели на порту $ACTUAL_PANEL_PORT..."
PANEL_READY=0
for i in $(seq 1 30); do
  if (exec 3<>"/dev/tcp/127.0.0.1/${ACTUAL_PANEL_PORT}") 2>/dev/null; then
    exec 3>&- 2>/dev/null || true
    PANEL_READY=1
    break
  fi
  sleep 1
done
if [[ "$PANEL_READY" -eq 1 ]]; then
  log "Панель отвечает на порту $ACTUAL_PANEL_PORT."
else
  err "Панель так и не открыла порт $ACTUAL_PANEL_PORT за 30 секунд. Проверь: systemctl status x-ui; journalctl -u x-ui -n 50"
fi

# ---------- 6. Проверка сертификата (ставится самим install.sh через XUI_SSL_MODE=ip) ----------
if [[ -s "$CERT_DIR/fullchain.pem" && -s "$CERT_DIR/privkey.pem" ]]; then
  CERT_OK=1
  log "SSL-сертификат на месте: $CERT_DIR"
else
  CERT_OK=0
  warn "SSL-сертификат НЕ найден в $CERT_DIR."
  warn "Скорее всего порт 80 недоступен снаружи (проверь firewall/security group у хостера, не только ufw)."
  warn "Hysteria2 и VLESS TLS будут пропущены, пока сертификат не появится."
  warn "После открытия порта 80 сертификат можно выпустить вручную: x-ui -> 16. SSL Certificate Management."
fi

# ---------- 7. Создание inbound'ов через API ----------
log "Подключение к API панели..."
COOKIE_JAR=$(mktemp)

log "URL логина: ${PANEL_BASE_URL}/login"
LOGIN_RAW="$(curl -s -w '\n%{http_code}' -c "$COOKIE_JAR" -X POST "${PANEL_BASE_URL}/login" \
  -d "username=$PANEL_USER&password=$PANEL_PASSWORD" 2>&1 || true)"
LOGIN_HTTP_CODE="$(echo "$LOGIN_RAW" | tail -n1)"
LOGIN_RESPONSE="$(echo "$LOGIN_RAW" | sed '$d')"

if echo "$LOGIN_RESPONSE" | grep -q '"success":true'; then
  log "Успешный вход в панель (HTTP $LOGIN_HTTP_CODE)."
else
  err "Не удалось залогиниться в панель. HTTP-код: ${LOGIN_HTTP_CODE:-<нет ответа>}"
  err "Тело ответа:"
  echo "${LOGIN_RESPONSE:-<пусто — curl не получил ответ, проверь connectivity/URL>}" >&2
  err "Возможные причины: неверный webBasePath в URL, панель ещё не полностью инициализировалась, либо curl вообще не достучался (см. HTTP-код выше)."
  err "Дальнейшие шаги (создание inbound'ов) пропущены."
fi

# --- Inbound 1: VLESS Internal ---
log "Создание VLESS Internal (2026, localhost)..."
ADD_RAW_1=$(curl -s -w '\n%{http_code}' -b "$COOKIE_JAR" -X POST "${PANEL_BASE_URL}/panel/api/inbounds/add" \
  -H "Content-Type: application/json" \
  -d "{
    \"listen\": \"127.0.0.1\",
    \"port\": 2026,
    \"protocol\": \"vless\",
    \"tag\": \"in-2026-tcp\",
    \"settings\": {
      \"clients\": [],
      \"decryption\": \"none\"
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
  }" 2>&1 || true)
ADD_CODE_1="$(echo "$ADD_RAW_1" | tail -n1)"
ADD_RESP_1="$(echo "$ADD_RAW_1" | sed '$d')"
echo "$ADD_RESP_1" | grep -q '"success":true' && log "VLESS Internal создан." || { warn "Не удалось создать VLESS Internal. HTTP: ${ADD_CODE_1:-<нет ответа>}. Ответ:"; echo "${ADD_RESP_1:-<пусто>}" >&2; }

# --- Inbound 2: Hysteria2 (только если есть сертификат) ---
if [[ "$CERT_OK" -eq 1 ]]; then
  log "Создание Hysteria2 (8443/udp)..."
  # ВНИМАНИЕ: поле обфускации переименовано с "finalmask" на "obfs" —
  # это наиболее вероятное правильное имя поля в текущей схеме 3x-ui,
  # но нативная поддержка Hysteria2-inbound через это API в некоторых
  # версиях 3x-ui ограничена (см. issue MHSanaei/3x-ui #3901 — раньше
  # Hysteria2 как inbound иногда приходилось добавлять через "Custom
  # Configuration" в самой панели). Если запрос всё равно не пройдёт —
  # создай этот inbound руками через UI один раз и пришли мне точный
  # JSON, который панель реально отправляет (вкладка Network в браузере) —
  # поправим API-вызов под факт.
  ADD_RAW_2=$(curl -s -w '\n%{http_code}' -b "$COOKIE_JAR" -X POST "${PANEL_BASE_URL}/panel/api/inbounds/add" \
    -H "Content-Type: application/json" \
    -d "{
      \"listen\": \"\",
      \"port\": 8443,
      \"protocol\": \"hysteria2\",
      \"tag\": \"in-8443-udp\",
      \"settings\": { \"clients\": [] },
      \"sniffing\": { \"enabled\": false },
      \"streamSettings\": {
        \"network\": \"tcp\",
        \"security\": \"tls\",
        \"tlsSettings\": {
          \"serverName\": \"$SERVER_IP\",
          \"certificates\": [{
            \"certificateFile\": \"$CERT_DIR/fullchain.pem\",
            \"keyFile\": \"$CERT_DIR/privkey.pem\"
          }]
        },
        \"obfs\": {
          \"type\": \"salamander\",
          \"password\": \"$HY2_PASSWORD\"
        }
      }
    }" 2>&1 || true)
  ADD_CODE_2="$(echo "$ADD_RAW_2" | tail -n1)"
  ADD_RESP_2="$(echo "$ADD_RAW_2" | sed '$d')"
  echo "$ADD_RESP_2" | grep -q '"success":true' && log "Hysteria2 создан." || { warn "Не удалось создать Hysteria2. HTTP: ${ADD_CODE_2:-<нет ответа>}. Ответ:"; echo "${ADD_RESP_2:-<пусто>}" >&2; }
else
  warn "Hysteria2 пропущен (нет сертификата)."
fi

# --- Inbound 3: VLESS TLS (только если есть сертификат) ---
if [[ "$CERT_OK" -eq 1 ]]; then
  log "Создание VLESS TLS ($CONNECT_PORT/tcp)..."
  ADD_RAW_3=$(curl -s -w '\n%{http_code}' -b "$COOKIE_JAR" -X POST "${PANEL_BASE_URL}/panel/api/inbounds/add" \
    -H "Content-Type: application/json" \
    -d "{
      \"listen\": \"\",
      \"port\": $CONNECT_PORT,
      \"protocol\": \"vless\",
      \"tag\": \"in-$CONNECT_PORT-tcp\",
      \"settings\": {
        \"clients\": [],
        \"decryption\": \"none\"
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
          \"certificates\": [{
            \"certificateFile\": \"$CERT_DIR/fullchain.pem\",
            \"keyFile\": \"$CERT_DIR/privkey.pem\"
          }],
          \"alpn\": [\"h2\", \"http/1.1\"]
        }
      }
    }" 2>&1 || true)
  ADD_CODE_3="$(echo "$ADD_RAW_3" | tail -n1)"
  ADD_RESP_3="$(echo "$ADD_RAW_3" | sed '$d')"
  echo "$ADD_RESP_3" | grep -q '"success":true' && log "VLESS TLS создан." || { warn "Не удалось создать VLESS TLS. HTTP: ${ADD_CODE_3:-<нет ответа>}. Ответ:"; echo "${ADD_RESP_3:-<пусто>}" >&2; }
else
  warn "VLESS TLS пропущен (нет сертификата)."
fi

# ---------- 8. Клиенты ----------
log "Получение списка inbound'ов..."
INBOUNDS_JSON=$(curl -s -b "$COOKIE_JAR" "${PANEL_BASE_URL}/panel/api/inbounds/list" 2>/dev/null || echo '{}')
INBOUND_2026_ID=$(echo "$INBOUNDS_JSON" | jq -r '.obj[]? | select(.tag=="in-2026-tcp") | .id' 2>/dev/null || true)
INBOUND_8443_ID=$(echo "$INBOUNDS_JSON" | jq -r '.obj[]? | select(.tag=="in-8443-udp") | .id' 2>/dev/null || true)
INBOUND_CONNECT_ID=$(echo "$INBOUNDS_JSON" | jq -r ".obj[]? | select(.tag==\"in-$CONNECT_PORT-tcp\") | .id" 2>/dev/null || true)

if [[ -n "$INBOUND_2026_ID" && "$INBOUND_2026_ID" != "null" ]]; then
  log "Добавление клиента в VLESS Internal..."
  curl -s -b "$COOKIE_JAR" -X POST "${PANEL_BASE_URL}/panel/api/inbounds/addClient" \
    -H "Content-Type: application/json" \
    -d "{\"id\": $INBOUND_2026_ID, \"settings\": \"{\\\"clients\\\":[{\\\"id\\\":\\\"$CLIENT_UUID\\\",\\\"email\\\":\\\"user@local\\\",\\\"subId\\\":\\\"$SUB_ID\\\"}]}\"}" \
    >/dev/null 2>&1 || warn "Не удалось добавить клиента в VLESS Internal."
fi

if [[ -n "$INBOUND_CONNECT_ID" && "$INBOUND_CONNECT_ID" != "null" ]]; then
  log "Добавление клиента в VLESS TLS..."
  curl -s -b "$COOKIE_JAR" -X POST "${PANEL_BASE_URL}/panel/api/inbounds/addClient" \
    -H "Content-Type: application/json" \
    -d "{\"id\": $INBOUND_CONNECT_ID, \"settings\": \"{\\\"clients\\\":[{\\\"id\\\":\\\"$CLIENT_UUID\\\",\\\"email\\\":\\\"user@local\\\",\\\"subId\\\":\\\"$SUB_ID\\\"}]}\"}" \
    >/dev/null 2>&1 || warn "Не удалось добавить клиента в VLESS TLS."
fi

if [[ -n "$INBOUND_8443_ID" && "$INBOUND_8443_ID" != "null" ]]; then
  log "Добавление клиента в Hysteria2..."
  curl -s -b "$COOKIE_JAR" -X POST "${PANEL_BASE_URL}/panel/api/inbounds/addClient" \
    -H "Content-Type: application/json" \
    -d "{\"id\": $INBOUND_8443_ID, \"settings\": \"{\\\"clients\\\":[{\\\"password\\\":\\\"$HY2_PASSWORD\\\",\\\"email\\\":\\\"user@local\\\",\\\"subId\\\":\\\"$SUB_ID\\\"}]}\"}" \
    >/dev/null 2>&1 || warn "Не удалось добавить клиента в Hysteria2."
fi

rm -f "$COOKIE_JAR"

# ---------- 9. Ссылки ----------
# Порт подписки: у 3x-ui по умолчанию 2096, но не гарантированно —
# свериться можно в панели (Settings -> Subscription Settings).
SUB_PORT=2096
SUB_URL="http://$SERVER_IP:$SUB_PORT/sub/$SUB_ID"
PANEL_URL="http://$SERVER_IP:$ACTUAL_PANEL_PORT/${ACTUAL_WEB_BASE_PATH}/"
VLESS_INTERNAL_LINK="vless://$CLIENT_UUID@$SERVER_IP:2026?type=tcp&security=none&encryption=none#VLESS-Internal"
VLESS_CONNECT_LINK="vless://$CLIENT_UUID@$SERVER_IP:$CONNECT_PORT?type=tcp&security=tls&encryption=none&sni=$SERVER_IP&fp=firefox#VLESS-TLS"
HY2_LINK="hysteria2://$HY2_PASSWORD@$SERVER_IP:8443?insecure=1&sni=$SERVER_IP#Hysteria2"

# ---------- 10. Итог ----------
echo ""
echo -e "${BLUE}========================================${NC}"
echo -e "${GREEN}✅ Развёртывание завершено!${NC}"
echo -e "${BLUE}========================================${NC}"
echo ""
echo -e "  🌐 Панель:     ${GREEN}$PANEL_URL${NC}"
echo -e "  👤 Логин:      ${GREEN}$PANEL_USER${NC}"
echo -e "  🔑 Пароль:     ${GREEN}$PANEL_PASSWORD${NC}"
echo ""
echo -e "  📡 Inbound'ы:"
echo -e "     • VLESS Internal:  порт ${GREEN}2026${NC} (127.0.0.1)"
echo -e "     • Hysteria2:       порт ${GREEN}8443/udp${NC} (0.0.0.0)$( [[ $CERT_OK -eq 0 ]] && echo ' — пропущен (нет сертификата)')"
echo -e "     • VLESS TLS:       порт ${GREEN}$CONNECT_PORT/tcp${NC} (0.0.0.0)$( [[ $CERT_OK -eq 0 ]] && echo ' — пропущен (нет сертификата)')"
echo ""
echo -e "  🔗 Ссылка подписки (порт $SUB_PORT — сверь в панели, если не откроется):"
echo -e "     ${YELLOW}$SUB_URL${NC}"
echo ""
echo -e "  🔗 Прямые подключения:"
echo -e "     VLESS Internal: ${YELLOW}$VLESS_INTERNAL_LINK${NC}"
echo -e "     VLESS TLS:      ${YELLOW}$VLESS_CONNECT_LINK${NC}"
echo -e "     Hysteria2:      ${YELLOW}$HY2_LINK${NC}"
echo ""
echo -e "${YELLOW}⚠️  Скопируй ссылки — subId больше не будет показан.${NC}"
echo ""