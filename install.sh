#!/usr/bin/env bash
# ==============================================================================
# Высокоскоростной автоинсталлятор: Hermes Agent + Hermes WebUI
# Репозиторий WebUI: https://github.com/nesquena/hermes-webui
# Официальный инсталлятор: Astral uv tool + Hermes Agent + ctl.sh QuickStart
# Провайдер модели: https://api.peai.su/v1
# Модель по умолчанию: ds/deepseek-v4-flash
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
  echo "Пример: curl -fsSL <URL>/install.sh | sudo bash -s -- [ОПЦИИ]"
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
WEBUI_STATE_DIR="${HERMES_CONFIG_DIR}/webui"

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
echo -e "${CYAN}${BOLD}   Высокоскоростная установка Hermes Agent & Hermes WebUI${NC}"
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
# 3. Быстрая установка критических зависимостей
# ------------------------------------------------------------------------------
log_info "Шаг 1/4: Проверка системных зависимостей..."

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

REQUIRED_PACKAGES=(curl git ca-certificates jq python3 python3-venv python3-pip libatomic1 libgomp1 ffmpeg systemd ufw)
MISSING_PACKAGES=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PACKAGES+=("$pkg")
  fi
done

if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
  log_info "Установка недостающих пакетов: ${MISSING_PACKAGES[*]}..."
  apt-get update -y -qq
  apt-get install -y -qq --no-install-recommends "${MISSING_PACKAGES[@]}"
else
  log_success "Все системные зависимости уже присутствуют."
fi

# ------------------------------------------------------------------------------
# 4. Параллельное развертывание Hermes Agent и Hermes WebUI
# ------------------------------------------------------------------------------
log_info "Шаг 2/4: Параллельная установка Hermes Agent (uv) и загрузка WebUI..."

# Очистка старых процессов и лок-файлов
pkill -9 -f 'hermes' 2>/dev/null || true
pkill -9 -f 'bootstrap.py' 2>/dev/null || true
pkill -9 -f 'server.py' 2>/dev/null || true
pkill -9 -f 'ctl.sh' 2>/dev/null || true
rm -f /root/.hermes/tools/.install.lock 2>/dev/null || true
rm -f "${TARGET_HOME}/.hermes/tools/.install.lock" 2>/dev/null || true

# 4.1. Параллельный легковесный клон репозитория WebUI (--depth 1)
(
  systemctl stop hermes-webui.service 2>/dev/null || true
  mkdir -p "$(dirname "$WEBUI_DIR")"
  if [[ -d "${WEBUI_DIR}/.git" ]]; then
    cd "${WEBUI_DIR}" && git pull -q || true
  else
    rm -rf "${WEBUI_DIR}"
    git clone --depth 1 -q https://github.com/nesquena/hermes-webui.git "${WEBUI_DIR}"
  fi
) &
WEBUI_CLONE_PID=$!

# 4.2. Установка официального быстрого uv и hermes-agent
su - "$TARGET_USER" -c '
  if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
  fi
  export PATH="$HOME/.local/bin:$HOME/.cargo/bin:$PATH"
  uv tool install --force hermes-agent
'

# Ожидание клонирования WebUI
wait "$WEBUI_CLONE_PID"

# Определение бинарника hermes и виртуального окружения python
HERMES_BIN=""
for path_cand in "${TARGET_HOME}/.local/bin/hermes" "/usr/local/bin/hermes" "/usr/bin/hermes"; do
  if [[ -x "$path_cand" ]]; then
    HERMES_BIN="$path_cand"
    break
  fi
done

if [[ -n "$HERMES_BIN" ]]; then
  ln -sf "$HERMES_BIN" /usr/local/bin/hermes || true
  log_success "Hermes Agent бинарник: ${HERMES_BIN}"
fi

HERMES_PYTHON="${TARGET_HOME}/.local/share/uv/tools/hermes-agent/bin/python"
if [[ ! -x "$HERMES_PYTHON" ]]; then
  HERMES_PYTHON=$(find "${TARGET_HOME}/.local/share/uv" -type f -name "python" -perm -111 2>/dev/null | head -n 1 || which python3)
fi
log_success "Окружение Python: ${HERMES_PYTHON}"

# Привязка пакетов agent к каталогу .hermes/hermes-agent для обнаружения WebUI
HERMES_AGENT_SRC=""
if [[ -x "$HERMES_PYTHON" ]]; then
  HERMES_AGENT_SRC=$("$HERMES_PYTHON" -c 'import run_agent, pathlib; print(pathlib.Path(run_agent.__file__).parent)' 2>/dev/null || true)
fi

mkdir -p "${HERMES_CONFIG_DIR}"
if [[ -n "$HERMES_AGENT_SRC" && -d "$HERMES_AGENT_SRC" ]]; then
  ln -sfn "$HERMES_AGENT_SRC" "${HERMES_CONFIG_DIR}/hermes-agent"
fi

# ------------------------------------------------------------------------------
# 5. Применение кастомного провайдера PEAI и автоматическое завершение онбординга
# ------------------------------------------------------------------------------
log_info "Шаг 3/4: Настройка провайдера PEAI (${PEAI_BASE_URL}) и автозавершение онбординга..."

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
HERMES_WEBUI_PYTHON="${HERMES_PYTHON}"
HERMES_WEBUI_SKIP_ONBOARDING="1"
HERMES_WEBUI_ONBOARDING_OPEN="1"
EOF

# Инициализация settings.json для WebUI с onboarding_completed: true
mkdir -p "${WEBUI_STATE_DIR}" "${TARGET_HOME}/workspace"
cat <<EOF > "${WEBUI_STATE_DIR}/settings.json"
{
  "onboarding_completed": true,
  "default_model": "${DEFAULT_MODEL}",
  "default_model_provider": "custom",
  "default_workspace": "${TARGET_HOME}/workspace",
  "password_hash": null,
  "auth_disabled_acknowledged": true,
  "bot_name": "Hermes"
}
EOF

chown -R "${TARGET_USER}:${TARGET_USER}" "${HERMES_CONFIG_DIR}" "${TARGET_HOME}/workspace"
chmod 600 "${HERMES_CONFIG_DIR}/.env"
chmod 644 "${HERMES_CONFIG_DIR}/config.yaml" "${WEBUI_STATE_DIR}/settings.json"

su - "$TARGET_USER" -c "
  export PATH=\"\$HOME/.local/bin:/usr/local/bin:\$PATH\"
  if command -v hermes >/dev/null 2>&1; then
    hermes config set model.provider custom 2>/dev/null || true
    hermes config set model.base_url \"${PEAI_BASE_URL}\" 2>/dev/null || true
    hermes config set model.default \"${DEFAULT_MODEL}\" 2>/dev/null || true
    hermes config set model.api_key \"${PEAI_API_KEY}\" 2>/dev/null || true
  fi
"

log_success "Конфигурация PEAI сохранена, мастер первого запуска помечен завершенным."

# ------------------------------------------------------------------------------
# 6. Настройка Hermes WebUI и автозапуск через Systemd
# ------------------------------------------------------------------------------
log_info "Шаг 4/4: Запуск Hermes WebUI и настройка Systemd автозапуска..."

cd "${WEBUI_DIR}"

cat <<EOF > "${WEBUI_DIR}/.env"
HERMES_WEBUI_HOST=${WEBUI_HOST}
HERMES_WEBUI_PORT=${WEBUI_PORT}
HERMES_HOME=${HERMES_CONFIG_DIR}
HERMES_WEBUI_STATE_DIR=${WEBUI_STATE_DIR}
HERMES_WEBUI_DEFAULT_MODEL=${DEFAULT_MODEL}
HERMES_WEBUI_PYTHON=${HERMES_PYTHON}
HERMES_WEBUI_AGENT_DIR=${HERMES_AGENT_SRC}
HERMES_WEBUI_SKIP_ONBOARDING=1
HERMES_WEBUI_ONBOARDING_OPEN=1
OPENAI_BASE_URL=${PEAI_BASE_URL}
OPENAI_API_KEY=${PEAI_API_KEY}
HERMES_WEBUI_CTL_ALLOW_SYSTEMD_CONFLICT=1
EOF

chmod +x "${WEBUI_DIR}/ctl.sh"
chown -R "${TARGET_USER}:${TARGET_USER}" "${WEBUI_DIR}"

# Настройка автозапуска в Systemd
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
Environment=HERMES_WEBUI_STATE_DIR=${WEBUI_STATE_DIR}
Environment=HERMES_WEBUI_HOST=${WEBUI_HOST}
Environment=HERMES_WEBUI_PORT=${WEBUI_PORT}
Environment=HERMES_WEBUI_PYTHON=${HERMES_PYTHON}
Environment=HERMES_WEBUI_AGENT_DIR=${HERMES_AGENT_SRC}
Environment=HERMES_WEBUI_SKIP_ONBOARDING=1
Environment=HERMES_WEBUI_ONBOARDING_OPEN=1
EnvironmentFile=-${WEBUI_DIR}/.env
ExecStart=${HERMES_PYTHON} ${WEBUI_DIR}/server.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hermes-webui.service
systemctl restart hermes-webui.service

if ufw status 2>/dev/null | grep -qw "active"; then
  ufw allow "${WEBUI_PORT}/tcp" || true
fi

sleep 3

# ------------------------------------------------------------------------------
# 7. Проверка работоспособности
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
echo -e " • Онбординг (мастер настройки): ${GREEN}Автоматически пройден (готово к чату)${NC}"
echo -e " • Панель WebUI доступна по:    ${BOLD}http://${SERVER_IP}:${WEBUI_PORT}${NC}"
echo "=================================================================="
echo -e "${BOLD}Команды управления:${NC}"
echo "  sudo systemctl status hermes-webui     # Статус службы"
echo "  sudo journalctl -u hermes-webui -f     # Логи в реальном времени"
echo "  sudo systemctl restart hermes-webui    # Перезапуск службы"
echo "=================================================================="
