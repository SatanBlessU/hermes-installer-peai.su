#!/usr/bin/env bash
# ==============================================================================
# Автоматический инсталлятор: Hermes Agent + Hermes WebUI для Ubuntu Server
# Репозиторий WebUI: https://github.com/nesquena/hermes-webui
# Провайдер модели: https://api.peai.su/v1
# Стандартная модель: ds/deepseek-v4-flash
# ==============================================================================

set -Eeuo pipefail

# Цветовое оформление
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------------------------------------------------------------
# 1. Проверка прав суперпользователя (root / sudo)
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  log_error "Скрипт должен быть запущен с правами root или через sudo!"
  echo "Пример: sudo bash $0"
  exit 1
fi

TARGET_USER="${SUDO_USER:-root}"
if [[ "$TARGET_USER" == "root" ]]; then
  TARGET_HOME="/root"
else
  TARGET_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
  if [[ -z "$TARGET_HOME" || ! -d "$TARGET_HOME" ]]; then
    TARGET_HOME="/home/$TARGET_USER"
  fi
fi

# Параметры по умолчанию
PEAI_BASE_URL="https://api.peai.su/v1"
PEAI_API_KEY=""
DEFAULT_MODEL="ds/deepseek-v4-flash"
WEBUI_HOST="0.0.0.0"
WEBUI_PORT="8787"
WEBUI_DIR="/opt/hermes-webui"
HERMES_CONFIG_DIR="${TARGET_HOME}/.hermes"

# ------------------------------------------------------------------------------
# 2. Обработка CLI флагов
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
${BOLD}Использование:${NC}
  sudo bash $0 [ОПЦИИ]
  curl -fsSL <URL>/install.sh | sudo bash -s -- [ОПЦИИ]

${BOLD}Опции:${NC}
  --apikeypeai <KEY>    API-ключ для https://api.peai.su/v1 (по умолчанию: пусто)
  --model <MODEL_NAME>  Имя модели (по умолчанию: ${DEFAULT_MODEL})
  --port <PORT>         Порт для Hermes WebUI (по умолчанию: ${WEBUI_PORT})
  -h, --help            Показать эту справку
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apikeypeai)
      if [[ -n "${2:-}" && ! "$2" =~ ^-- ]]; then
        PEAI_API_KEY="$2"
        shift 2
      else
        log_error "Флаг --apikeypeai требует аргумент (значение ключа)."
        exit 1
      fi
      ;;
    --apikeypeai=*)
      PEAI_API_KEY="${1#*=}"
      shift 1
      ;;
    --model)
      DEFAULT_MODEL="$2"
      shift 2
      ;;
    --model=*)
      DEFAULT_MODEL="${1#*=}"
      shift 1
      ;;
    --port)
      WEBUI_PORT="$2"
      shift 2
      ;;
    --port=*)
      WEBUI_PORT="${1#*=}"
      shift 1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      log_warn "Неизвестный параметр: $1 (пропущен)"
      shift 1
      ;;
  esac
done

echo "=================================================================="
echo -e "${CYAN}${BOLD}   Установка Hermes Agent & Hermes WebUI (QuickStart Auto)${NC}"
echo "=================================================================="
log_info "Целевой пользователь: ${TARGET_USER} (${TARGET_HOME})"
log_info "Провайдер LLM:        ${PEAI_BASE_URL}"
if [[ -n "${PEAI_API_KEY}" ]]; then
  log_info "API-ключ PEAI:        ${PEAI_API_KEY:0:7}*** (установлен)"
else
  log_info "API-ключ PEAI:        <ПУСТОЙ> (будет записан в конфигурацию)"
fi
log_info "Модель по умолчанию:  ${DEFAULT_MODEL}"
log_info "Порт WebUI:           ${WEBUI_PORT} (Host: ${WEBUI_HOST})"
echo "=================================================================="

# ------------------------------------------------------------------------------
# 3. Обновление системы (apt update && upgrade) и системные пакеты
# ------------------------------------------------------------------------------
log_info "Шаг 1/5: Обновление системы (apt update && apt upgrade)..."

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

apt-get update -y
apt-get -y \
  -o Dpkg::Options::=--force-confdef \
  -o Dpkg::Options::=--force-confold \
  upgrade

apt-get install -y --no-install-recommends \
    curl \
    git \
    ca-certificates \
    jq \
    python3 \
    python3-venv \
    python3-pip \
    tar \
    unzip \
    systemd \
    ufw

# ------------------------------------------------------------------------------
# 4. Установка Hermes Agent
# ------------------------------------------------------------------------------
log_info "Шаг 2/5: Установка Hermes Agent..."

pkill -9 -f 'hermes setup' 2>/dev/null || true

su - "$TARGET_USER" -c 'curl -fsSL https://hermes-agent.nousresearch.com/install.sh | bash -s -- --non-interactive' || {
    log_warn "Официальный curl-скрипт вернул код ошибки, разворачиваем через astral uv..."
    su - "$TARGET_USER" -c 'curl -LsSf https://astral.sh/uv/install.sh | sh'
    su - "$TARGET_USER" -c 'export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH" && uv tool install hermes-agent || true'
}

HERMES_BIN=""
for path_cand in "${TARGET_HOME}/.local/bin/hermes" "/usr/local/bin/hermes" "/usr/bin/hermes" "${TARGET_HOME}/.cargo/bin/hermes"; do
  if [[ -x "$path_cand" ]]; then
    HERMES_BIN="$path_cand"
    break
  fi
done

if [[ -z "$HERMES_BIN" ]]; then
  HERMES_BIN=$(find "${TARGET_HOME}" -type f -name "hermes" -perm -111 2>/dev/null | head -n 1 || true)
fi

if [[ -n "$HERMES_BIN" ]]; then
  ln -sf "$HERMES_BIN" /usr/local/bin/hermes || true
  log_success "Hermes Agent бинарник: ${HERMES_BIN}"
fi

# ------------------------------------------------------------------------------
# 5. Применение кастомного провайдера PEAI и модели ds/deepseek-v4-flash
# ------------------------------------------------------------------------------
log_info "Шаг 3/5: Настройка провайдера PEAI (${PEAI_BASE_URL}) и модели ${DEFAULT_MODEL}..."

mkdir -p "${HERMES_CONFIG_DIR}"

cat <<EOF > "${HERMES_CONFIG_DIR}/config.yaml"
# Hermes Agent Configuration
model:
  default: "${DEFAULT_MODEL}"
  provider: custom
  base_url: "${PEAI_BASE_URL}"
  api_key: "${PEAI_API_KEY}"
  aliases:
    ds:
      model: "${DEFAULT_MODEL}"
      provider: custom
      base_url: "${PEAI_BASE_URL}"
      api_key: "${PEAI_API_KEY}"
    peai:
      model: "${DEFAULT_MODEL}"
      provider: custom
      base_url: "${PEAI_BASE_URL}"
      api_key: "${PEAI_API_KEY}"

agent:
  max_turns: 90
  tool_use_enforcement: true

display:
  interface: cli
  language: ru

terminal:
  backend: local
  timeout: 180
EOF

cat <<EOF > "${HERMES_CONFIG_DIR}/.env"
OPENAI_BASE_URL="${PEAI_BASE_URL}"
OPENAI_API_BASE="${PEAI_BASE_URL}"
OPENAI_API_KEY="${PEAI_API_KEY}"
HERMES_BASE_URL="${PEAI_BASE_URL}"
HERMES_API_KEY="${PEAI_API_KEY}"
PEAI_BASE_URL="${PEAI_BASE_URL}"
PEAI_API_KEY="${PEAI_API_KEY}"
HERMES_WEBUI_DEFAULT_MODEL="${DEFAULT_MODEL}"
EOF

chown -R "${TARGET_USER}:${TARGET_USER}" "${HERMES_CONFIG_DIR}"
chmod 600 "${HERMES_CONFIG_DIR}/.env"
chmod 644 "${HERMES_CONFIG_DIR}/config.yaml"

# Применение конфигурации через официальный CLI
su - "$TARGET_USER" -c "
  export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"
  if command -v hermes >/dev/null 2>&1; then
    hermes config set model.provider custom 2>/dev/null || true
    hermes config set model.base_url \"${PEAI_BASE_URL}\" 2>/dev/null || true
    hermes config set model.default \"${DEFAULT_MODEL}\" 2>/dev/null || true
    hermes config set model.api_key \"${PEAI_API_KEY}\" 2>/dev/null || true
  fi
"

log_success "Конфигурация PEAI и модели ${DEFAULT_MODEL} записана."

# ------------------------------------------------------------------------------
# 6. Установка и настройка Hermes WebUI
# ------------------------------------------------------------------------------
log_info "Шаг 4/5: Развертывание Hermes WebUI..."

mkdir -p "$(dirname "$WEBUI_DIR")"

# Остановка старой службы при повторной установке
systemctl stop hermes-webui.service 2>/dev/null || true

if [[ -d "${WEBUI_DIR}/.git" ]]; then
    log_info "Обновление существующего репозитория WebUI..."
    cd "${WEBUI_DIR}"
    git pull || true
else
    rm -rf "${WEBUI_DIR}"
    git clone https://github.com/nesquena/hermes-webui.git "${WEBUI_DIR}"
fi

cd "${WEBUI_DIR}"

cat <<EOF > "${WEBUI_DIR}/.env"
HERMES_WEBUI_HOST=${WEBUI_HOST}
HERMES_WEBUI_PORT=${WEBUI_PORT}
HERMES_HOME=${HERMES_CONFIG_DIR}
HERMES_WEBUI_DEFAULT_MODEL=${DEFAULT_MODEL}
OPENAI_BASE_URL=${PEAI_BASE_URL}
OPENAI_API_KEY=${PEAI_API_KEY}
HERMES_WEBUI_CTL_ALLOW_SYSTEMD_CONFLICT=1
EOF

chmod +x "${WEBUI_DIR}/ctl.sh"
chown -R "${TARGET_USER}:${TARGET_USER}" "${WEBUI_DIR}"

if ufw status 2>/dev/null | grep -qw "active"; then
  ufw allow "${WEBUI_PORT}/tcp" || true
fi

# ------------------------------------------------------------------------------
# 7. Настройка Systemd автозапуска (Надёжный Type=simple с bootstrap.py)
# ------------------------------------------------------------------------------
log_info "Шаг 5/5: Настройка Systemd службы автозапуска..."

cat <<EOF > /etc/systemd/system/hermes-webui.service
[Unit]
Description=Hermes Web UI Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${TARGET_USER}
WorkingDirectory=${WEBUI_DIR}
Environment=HOME=${TARGET_HOME}
Environment=HERMES_HOME=${HERMES_CONFIG_DIR}
Environment=HERMES_WEBUI_HOST=${WEBUI_HOST}
Environment=HERMES_WEBUI_PORT=${WEBUI_PORT}
EnvironmentFile=-${WEBUI_DIR}/.env
ExecStart=/usr/bin/python3 ${WEBUI_DIR}/bootstrap.py --no-browser --foreground --host ${WEBUI_HOST} ${WEBUI_PORT}
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hermes-webui.service
systemctl restart hermes-webui.service

# Ожидание старта
sleep 4

# ------------------------------------------------------------------------------
# 8. Проверка работоспособности
# ------------------------------------------------------------------------------
WEBUI_ENABLED=$(systemctl is-enabled hermes-webui.service 2>/dev/null || echo "not-found")
WEBUI_ACTIVE=$(systemctl is-active hermes-webui.service 2>/dev/null || echo "inactive")
SERVER_IP=$(curl -s4 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')

echo ""
echo "=================================================================="
echo -e "${GREEN}${BOLD}             УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
echo "=================================================================="
echo -e " • Hermes WebUI в автозапуске:  ${BOLD}${WEBUI_ENABLED}${NC} (Статус: ${WEBUI_ACTIVE})"
echo -e " • Провайдер LLM:               ${CYAN}${PEAI_BASE_URL}${NC}"
echo -e " • Модель по умолчанию:         ${GREEN}${DEFAULT_MODEL}${NC}"
if [[ -n "${PEAI_API_KEY}" ]]; then
  echo -e " • API-ключ:                    ${GREEN}Задан (${PEAI_API_KEY:0:7}***)${NC}"
else
  echo -e " • API-ключ:                    ${YELLOW}<Пусто>${NC} (можно задать позже)"
fi
echo -e " • Панель WebUI доступна по:    ${BOLD}http://${SERVER_IP}:${WEBUI_PORT}${NC}"
echo "=================================================================="
echo -e "${BOLD}Команды управления:${NC}"
echo "  sudo systemctl status hermes-webui     # Статус службы"
echo "  sudo journalctl -u hermes-webui -f     # Логи в реальном времени"
echo "  sudo systemctl restart hermes-webui    # Перезапуск службы"
echo "=================================================================="
