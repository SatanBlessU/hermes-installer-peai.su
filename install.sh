#!/usr/bin/env bash
# ==============================================================================
# Высокоскоростной автоинсталлятор: Hermes Agent + Hermes WebUI (Production)
# Разработано для автоматического провижининга VPS (1-click provisioning)
# Поддержка JSON-протокола для бэкендов (--json)
# Провайдер: https://api.peai.su/v1 (HERMES_CUSTOM_API_PEAI_SU_API_KEY)
# ==============================================================================

set -Eeuo pipefail

# Цветовое оформление (для TTY)
if [[ -t 1 ]]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' NC=''
fi

log_info()    { [[ "${OUTPUT_JSON}" == "false" ]] && echo -e "${BLUE}[INFO]${NC} $1" >&2 || true; }
log_success() { [[ "${OUTPUT_JSON}" == "false" ]] && echo -e "${GREEN}[OK]${NC} $1" >&2 || true; }
log_warn()    { [[ "${OUTPUT_JSON}" == "false" ]] && echo -e "${YELLOW}[WARN]${NC} $1" >&2 || true; }
log_error()   { [[ "${OUTPUT_JSON}" == "false" ]] && echo -e "${RED}[ERROR]${NC} $1" >&2 || true; }

# ------------------------------------------------------------------------------
# 1. Проверка прав суперпользователя (root / sudo)
# ------------------------------------------------------------------------------
if [[ $EUID -ne 0 ]]; then
  log_error "Скрипт должен быть запущен с правами root или через sudo!"
  if [[ "${1:-}" == *"--json"* ]]; then
    echo "{\"status\":\"error\",\"message\":\"root_required\",\"error_code\":1}"
  fi
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
WEBUI_DIR="${TARGET_HOME}/hermes-webui"
HERMES_CONFIG_DIR="${TARGET_HOME}/.hermes"
WEBUI_STATE_DIR="${HERMES_CONFIG_DIR}/webui"
OUTPUT_JSON=false

# ------------------------------------------------------------------------------
# 2. Обработка CLI флагов
# ------------------------------------------------------------------------------
usage() {
  cat <<EOF
${BOLD}Использование:${NC}
  sudo bash $0 [ОПЦИИ]
  curl -fsSL <URL>/install.sh | sudo bash -s -- [ОПЦИИ]

${BOLD}Опции:${NC}
  --apikeypeai <KEY>    API-ключ для https://api.peai.su/v1 (записывается в HERMES_CUSTOM_API_PEAI_SU_API_KEY)
  --model <MODEL_NAME>  Имя модели по умолчанию (по умолчанию: ${DEFAULT_MODEL})
  --port <PORT>         Порт для Hermes WebUI (по умолчанию: ${WEBUI_PORT})
  --json                Вывод только JSON-результата (удобно для бэкендов и API)
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
    --json)
      OUTPUT_JSON=true
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

if [[ "${OUTPUT_JSON}" == "false" ]]; then
  echo "=================================================================="
  echo -e "${CYAN}${BOLD}   Автоматическая установка Hermes Agent & Hermes WebUI${NC}"
  echo "=================================================================="
  log_info "Целевой пользователь: ${TARGET_USER} (${TARGET_HOME})"
  log_info "Каталог WebUI:        ${WEBUI_DIR}"
  log_info "Провайдер LLM:        ${PEAI_BASE_URL}"
  if [[ -n "${PEAI_API_KEY}" ]]; then
    log_info "API-ключ PEAI:        ${PEAI_API_KEY:0:7}*** (установлен)"
  else
    log_info "API-ключ PEAI:        <ПУСТОЙ> (будет записан в HERMES_CUSTOM_API_PEAI_SU_API_KEY)"
  fi
  log_info "Модель по умолчанию:  ${DEFAULT_MODEL}"
  log_info "Порт WebUI:           ${WEBUI_PORT} (Host: ${WEBUI_HOST})"
  echo "=================================================================="
fi

# ------------------------------------------------------------------------------
# 3. Быстрая установка критических зависимостей
# ------------------------------------------------------------------------------
log_info "Шаг 1/4: Проверка системных зависимостей Ubuntu/Debian..."

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

REQUIRED_PACKAGES=(curl git ca-certificates jq python3 python3-venv python3-pip libatomic1 libgomp1 ffmpeg systemd ufw tmux procps)
MISSING_PACKAGES=()

for pkg in "${REQUIRED_PACKAGES[@]}"; do
  if ! dpkg -s "$pkg" >/dev/null 2>&1; then
    MISSING_PACKAGES+=("$pkg")
  fi
done

if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
  log_info "Установка недостающих пакетов: ${MISSING_PACKAGES[*]}..."
  apt-get update -y -qq >/dev/null 2>&1 || true
  apt-get install -y -qq --no-install-recommends "${MISSING_PACKAGES[@]}" >/dev/null 2>&1 || true
else
  log_success "Все системные зависимости присутствуют."
fi

# ------------------------------------------------------------------------------
# 4. Развертывание Hermes Agent (всегда последняя версия) и WebUI в ${WEBUI_DIR}
# ------------------------------------------------------------------------------
log_info "Шаг 2/4: Установка актуальных версий Hermes Agent и Hermes WebUI..."

# Очистка конфликтующих процессов
pkill -9 -f 'hermes' 2>/dev/null || true
pkill -9 -f 'bootstrap.py' 2>/dev/null || true
pkill -9 -f 'server.py' 2>/dev/null || true
pkill -9 -f 'ctl.sh' 2>/dev/null || true
rm -f /root/.hermes/tools/.install.lock 2>/dev/null || true
rm -f "${TARGET_HOME}/.hermes/tools/.install.lock" 2>/dev/null || true

# 4.1. Параллельный легковесный клон свежего репозитория WebUI (--depth 1)
(
  systemctl stop hermes-webui.service 2>/dev/null || true
  mkdir -p "$(dirname "$WEBUI_DIR")"
  if [[ -d "${WEBUI_DIR}/.git" ]]; then
    cd "${WEBUI_DIR}" && git fetch origin main -q 2>/dev/null && git reset --hard origin/main -q 2>/dev/null || true
  else
    rm -rf "${WEBUI_DIR}"
    git clone --depth 1 -q https://github.com/nesquena/hermes-webui.git "${WEBUI_DIR}"
  fi
) &
WEBUI_CLONE_PID=$!

# 4.2. Установка официальным скриптом Nous Research Hermes Agent
log_info "Установка Hermes Agent через официальный скрипт..."
su - "$TARGET_USER" -c '
  curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash -s -- --non-interactive --skip-browser
'

# Ожидание клонирования WebUI
wait "$WEBUI_CLONE_PID"

# Определение бинарника hermes и виртуального окружения python
HERMES_BIN=""
for path_cand in "${TARGET_HOME}/.local/bin/hermes" "${HERMES_CONFIG_DIR}/hermes-agent/.hermes/bin/hermes" "/usr/local/bin/hermes" "/usr/bin/hermes"; do
  if [[ -x "$path_cand" ]]; then
    HERMES_BIN="$path_cand"
    break
  fi
done

if [[ -n "$HERMES_BIN" ]]; then
  ln -sf "$HERMES_BIN" /usr/local/bin/hermes || true
  log_success "Hermes Agent бинарник: ${HERMES_BIN}"
fi

# Настройка провайдера через официальные команды hermes config set
log_info "Настройка конфигурации модели через hermes config set..."
su - "$TARGET_USER" -c "
  export PATH=\"\$HOME/.local/bin:\$PATH\"
  hermes config set model.provider \"custom\"
  hermes config set model.base_url \"${PEAI_BASE_URL}\"
  hermes config set model.default \"${DEFAULT_MODEL}\"
  if [[ -n \"${PEAI_API_KEY}\" ]]; then
    hermes config set model.api_key \"${PEAI_API_KEY}\"
  fi
"

HERMES_PYTHON=""
for py_cand in "${TARGET_HOME}/.hermes/tools"/python-*/bin/python3 "${TARGET_HOME}/.local/share/uv/tools/hermes-agent/bin/python"; do
  if [[ -x "$py_cand" ]]; then
    HERMES_PYTHON="$py_cand"
    break
  fi
done

if [[ -z "$HERMES_PYTHON" || ! -x "$HERMES_PYTHON" ]]; then
  HERMES_PYTHON=$(find "${HERMES_CONFIG_DIR}" -type f -name "python" -perm -111 2>/dev/null | head -n 1 || which python3)
fi
log_success "Окружение Python: ${HERMES_PYTHON}"

# Привязка пакетов agent к каталогу .hermes/hermes-agent для обнаружения WebUI
HERMES_AGENT_SRC="${TARGET_HOME}/.hermes/hermes-agent"
if [[ ! -d "$HERMES_AGENT_SRC" && -x "$HERMES_PYTHON" ]]; then
  HERMES_AGENT_SRC=$("$HERMES_PYTHON" -c 'import run_agent, pathlib; print(pathlib.Path(run_agent.__file__).parent)' 2>/dev/null || true)
fi

mkdir -p "${HERMES_CONFIG_DIR}"
if [[ -n "$HERMES_AGENT_SRC" && -d "$HERMES_AGENT_SRC" && "$HERMES_AGENT_SRC" != "${HERMES_CONFIG_DIR}/hermes-agent" ]]; then
  ln -sfn "$HERMES_AGENT_SRC" "${HERMES_CONFIG_DIR}/hermes-agent"
fi

# ------------------------------------------------------------------------------
# 5. Применение кастомного провайдера PEAI, config.yaml, .env и автоонбординг
# ------------------------------------------------------------------------------
log_info "Шаг 3/4: Настройка config.yaml, .env и токенов авторизации PEAI..."

cat <<'EOF' > "${HERMES_CONFIG_DIR}/config.yaml"
_config_version: 49
database:
  journal_mode: wal
runtime:
  nofile_soft_limit: 4096
attachments:
  storage: hermes-home
plugins:
  clone_timeout_seconds: 300
model:
  default: ds/deepseek-v4-flash
  provider: custom
  base_url: https://api.peai.su/v1
  api_key: https://api.peai.su/v1
kanban:
  review_dispatch: true
cron:
  catch_up_missed: true
terminal:
  backend: local
  cwd: .
  timeout: 180
  home_mode: auto
  docker_mount_cwd_to_workspace: false
  lifetime_seconds: 300
  container_cpu: 1
  container_memory: 5120
  container_disk: 51200
  container_persistent: true
browser:
  inactivity_timeout: 120
  extension_control:
    enabled: false
tool_loop_guardrails:
  warnings_enabled: true
  hard_stop_enabled: false
  non_interactive_hard_stop_enabled: true
  warn_after:
    exact_failure: 2
    same_tool_failure: 3
    idempotent_no_progress: 2
  hard_stop_after:
    exact_failure: 5
    same_tool_failure: 8
    idempotent_no_progress: 5
compression:
  enabled: true
  checkpoint_required: false
  progress_notices: false
  threshold: 0.5
  codex_gpt55_autoraise: true
  target_ratio: 0.2
  protect_last_n: 20
  min_tail_user_messages: 1
  max_attempts: 3
  codex_app_server_auto: native
  codex_responses_native: false
  codex_responses_compact_threshold: null
  protect_first_n: 3
  idle_compact_after_seconds: 0
  hygiene_max_turn_hold_seconds: 10
  proactive_prune_tokens: 0
  proactive_prune_min_result_chars: 8000
  proactive_prune_min_reclaim_tokens: 4096
prompt_caching:
  cache_ttl: 5m
memory:
  memory_enabled: true
  user_profile_enabled: true
  memory_char_limit: 2200
  user_char_limit: 1375
  nudge_interval: 10
max_concurrent_sessions: null
group_sessions_per_user: true
streaming:
  enabled: false
skills:
  creation_nudge_interval: 15
agent:
  max_turns: 150
  verbose: false
  reasoning_effort: none
  service_tier: ''
  fast_auto_seconds: 60
gateway:
  signal_interrupt_grace_timeout: 1
  delivery_ledger: true
  platform_connect_timeout: 30
  loop_watchdog: true
  loop_watchdog_probe_interval_s: 30.0
  loop_watchdog_probe_timeout_s: 10.0
  loop_watchdog_max_strikes: 3
  allow_all_users: false
  bot_loop_guard:
    enabled: true
    max_events: 20
    window_seconds: 300
    cooldown_seconds: 600
  startup_watchdog: true
  startup_watchdog_timeout_seconds: 300
  write_sessions_json: true
  multiplex_profiles: true
  auto_multiplex_migration: true
  profile_routes: []
  scale_to_zero:
    idle_timeout_minutes: 2
  restart_loop_guard:
    max_restarts: 3
    window_seconds: 60
    max_gap_seconds: 300
  respawn_storm:
    max_starts: 5
    window_seconds: 120
  message_timestamps:
    enabled: false
  max_inbound_media_bytes: 134217728
  trust_env: true
  strict: false
  media_delivery_allow_dirs: []
  trust_recent_files: true
  trust_recent_files_seconds: 600
  api_server:
    max_concurrent_runs: 10
    history_tool_output_max_chars: 0
platform_toolsets:
  cli:
  - hermes-cli
  telegram:
  - hermes-telegram
  discord:
  - hermes-discord
  whatsapp:
  - hermes-whatsapp
  slack:
  - hermes-slack
  signal:
  - hermes-signal
  homeassistant:
  - hermes-homeassistant
  qqbot:
  - hermes-qqbot
  yuanbao:
  - hermes-yuanbao
  teams:
  - hermes-teams
  google_chat:
  - hermes-google_chat
stt:
  enabled: true
  local:
    model: base
  language: en
  openai:
    model: whisper-1
    language: ''
    timeout: 60
    max_retries: 1
code_execution:
  timeout: 300
  max_tool_calls: 50
delegation:
  max_iterations: 250
display:
  compact: false
  cleanup_progress: false
  suppress_warning_notifications: false
  busy_input_mode: interrupt
  background_process_notifications: concise
  bell_on_complete: false
  bell_on_prompt: false
  streaming: true
  skin: default
telemetry:
  shared_metrics:
    enabled: false
    send: false
auth:
  adopt_external_logins: true
  codex_login_flow: device_code
updates:
  check: true
  pre_update_backup: false
  backup_keep: 5
  non_interactive_local_changes: stash
custom_providers:
- name: Api.peai.su
  base_url: https://api.peai.su/v1
  key_env: HERMES_CUSTOM_API_PEAI_SU_API_KEY
  model: ds/deepseek-v4-flash
  models:
    nano-banana-lite: {}
    nano-banana: {}
    nano-banana-pro: {}
    ag/gemini-3.7-flash-high: {}
    ag/gemini-3.7-flash-medium: {}
    ag/gemini-3.7-flash-low: {}
    ag/gemini-3.6-flash-high: {}
    ag/gemini-3.6-flash-medium: {}
    ag/gemini-3.6-flash-low: {}
    ag/gemini-pro-agent: {}
    ag/gemini-3.1-pro-low: {}
    ag/claude-sonnet-4-6: {}
    ag/gpt-oss-120b-medium: {}
    ag/gemini-3-flash: {}
    ag/gemini-2.5-flash: {}
    ag/gemini-2.5-flash-lite: {}
    ag/gemini-3.1-flash-lite-preview: {}
    am/nemotron-3-ultra-550b-a55b: {}
    am/gpt-oss-20b: {}
    am/nemotron-3-super-120b-a12b: {}
    am/nemotron-3.5-lightning-30b-a3b: {}
    am/laguna-xs-2.1: {}
    am/kimi-k3: {}
    am/llama-3.2-11b-vision-instruct: {}
    am/nemotron-3-nano-omni-30b-a3b-reasoning: {}
    am/diffusiongemma-26b-a4b-it: {}
    am/riva-translate-4b-instruct-v2: {}
    am/nemotron-3.5-content-safety: {}
    cx/gpt-6-astra: {}
    cx/gpt-6-sol: {}
    cx/gpt-6-sol-review: {}
    cx/gpt-6-luna: {}
    cx/gpt-6-luna-review: {}
    cx/gpt-5.6-sol: {}
    cx/gpt-5.6-sol-review: {}
    cx/gpt-5.6-terra: {}
    cx/gpt-5.6-terra-review: {}
    cx/gpt-5.6-luna: {}
    cx/gpt-5.6-luna-review: {}
    cx/gpt-5.5: {}
    cx/gpt-5.5-review: {}
    kmc/kimi-for-coding: {}
    kmc/k3: {}
    glm/glm-5.3: {}
    glm/glm-5.3-flash: {}
    glm/glm-5.2: {}
    glm/glm-5.1: {}
    glm/glm-5: {}
    glm/glm-4.7: {}
    glm/glm-4.6v: {}
    gcli/grok-4.7: {}
    gcli/grok-4.7-build-fast: {}
    gcli/grok-4.6: {}
    gcli/grok-4.5: {}
    xai/grok-4.7: {}
    xai/grok-4.6: {}
    xai/grok-4.5: {}
    xai/grok-4.3: {}
    xai/grok-build-0.1: {}
    xai/grok-4.20-0309-reasoning: {}
    xai/grok-4.20-0309-non-reasoning: {}
    xai/grok-4.20-multi-agent-0309: {}
    cc/claude-opus-5: {}
    cc/claude-fable-5: {}
    cc/claude-sonnet-5: {}
    cc/claude-opus-4-8: {}
    cc/claude-opus-4-7: {}
    cc/claude-opus-4-6: {}
    cc/claude-sonnet-4-6: {}
    cc/claude-haiku-4-5-20251001: {}
    cc/claude-opus-4-5-20251101: {}
    cc/claude-sonnet-4-5-20250929: {}
    ds/deepseek-v4-pro: {}
    ds/deepseek-v4-flash: {}
    qwen/qwen3.8-max: {}
    qwen/qwen3.7-max: {}
    qwen/qwen3.7-plus: {}
    flow/nano-banana-pro: {}
    flow/nano-banana: {}
    flow/nano-banana-lite: {}
    am/free: {}
  models_discovered: true
EOF

cat <<EOF > "${HERMES_CONFIG_DIR}/.env"
# Hermes Agent Environment Configuration
TERMINAL_MODAL_IMAGE=nikolaik/python-nodejs:python3.11-nodejs20
TERMINAL_TIMEOUT=60
TERMINAL_LIFETIME_SECONDS=300
BROWSERBASE_PROXIES=true
BROWSERBASE_ADVANCED_STEALTH=false
BROWSER_SESSION_TIMEOUT=300
BROWSER_INACTIVITY_TIMEOUT=120
WEB_TOOLS_DEBUG=false
VISION_TOOLS_DEBUG=false
MOA_TOOLS_DEBUG=false
IMAGE_TOOLS_DEBUG=false

# PEAI Provider Auth (Multi-layer binding)
HERMES_CUSTOM_API_PEAI_SU_API_KEY=${PEAI_API_KEY}
CUSTOM_API_KEY=${PEAI_API_KEY}
OPENAI_API_KEY=${PEAI_API_KEY}
OPENAI_BASE_URL=${PEAI_BASE_URL}
HERMES_API_KEY=${PEAI_API_KEY}
HERMES_BASE_URL=${PEAI_BASE_URL}

# WebUI Automation
HERMES_WEBUI_DEFAULT_MODEL=${DEFAULT_MODEL}
HERMES_WEBUI_PYTHON=${HERMES_PYTHON}
HERMES_WEBUI_AGENT_DIR=${HERMES_AGENT_SRC}
HERMES_WEBUI_SKIP_ONBOARDING=1
HERMES_WEBUI_ONBOARDING_OPEN=1
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

log_success "Конфигурация PEAI сохранена (HERMES_CUSTOM_API_PEAI_SU_API_KEY)."

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
HERMES_CUSTOM_API_PEAI_SU_API_KEY=${PEAI_API_KEY}
CUSTOM_API_KEY=${PEAI_API_KEY}
OPENAI_BASE_URL=${PEAI_BASE_URL}
OPENAI_API_KEY=${PEAI_API_KEY}
HERMES_WEBUI_CTL_ALLOW_SYSTEMD_CONFLICT=1
EOF

chmod +x "${WEBUI_DIR}/ctl.sh"
chown -R "${TARGET_USER}:${TARGET_USER}" "${WEBUI_DIR}"

# Настройка службы Systemd
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
  ufw allow "${WEBUI_PORT}/tcp" >/dev/null 2>&1 || true
fi

sleep 3

# ------------------------------------------------------------------------------
# 7. Проверка работоспособности и возврат результата
# ------------------------------------------------------------------------------
WEBUI_ENABLED=$(systemctl is-enabled hermes-webui.service 2>/dev/null || echo "not-found")
WEBUI_ACTIVE=$(systemctl is-active hermes-webui.service 2>/dev/null || echo "inactive")
SERVER_IP=$(curl -s4 --max-time 3 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
WEBUI_URL="http://${SERVER_IP}:${WEBUI_PORT}"

if [[ "${OUTPUT_JSON}" == "true" ]]; then
  cat <<EOF
{
  "status": "success",
  "webui_url": "${WEBUI_URL}",
  "server_ip": "${SERVER_IP}",
  "port": ${WEBUI_PORT},
  "service_status": "${WEBUI_ACTIVE}",
  "autostart_enabled": "${WEBUI_ENABLED}",
  "provider": "${PEAI_BASE_URL}",
  "default_model": "${DEFAULT_MODEL}",
  "api_key_configured": $( [[ -n "${PEAI_API_KEY}" ]] && echo "true" || echo "false" )
}
EOF
else
  echo ""
  echo "=================================================================="
  echo -e "${GREEN}${BOLD}             УСТАНОВКА УСПЕШНО ЗАВЕРШЕНА!${NC}"
  echo "=================================================================="
  echo -e " • Hermes WebUI в автозапуске:  ${BOLD}${WEBUI_ENABLED}${NC} (Статус: ${WEBUI_ACTIVE})"
  echo -e " • Каталог WebUI:               ${BOLD}${WEBUI_DIR}${NC}"
  echo -e " • Провайдер LLM:               ${CYAN}${PEAI_BASE_URL}${NC}"
  echo -e " • Поле ключа в .env:           ${BOLD}HERMES_CUSTOM_API_PEAI_SU_API_KEY${NC}"
  if [[ -n "${PEAI_API_KEY}" ]]; then
    echo -e " • API-ключ:                    ${GREEN}Задан (${PEAI_API_KEY:0:7}***)${NC}"
  else
    echo -e " • API-ключ:                    ${YELLOW}<Пусто>${NC} (можно задать позже)"
  fi
  echo -e " • Онбординг (мастер настройки): ${GREEN}Автоматически пройден (готово к чату)${NC}"
  echo -e " • Панель WebUI доступна по:    ${BOLD}${WEBUI_URL}${NC}"
  echo "=================================================================="
  echo -e "${BOLD}Команды управления:${NC}"
  echo "  sudo systemctl status hermes-webui     # Статус службы"
  echo "  sudo journalctl -u hermes-webui -f     # Логи в реальном времени"
  echo "  sudo systemctl restart hermes-webui    # Перезапуск службы"
  echo "=================================================================="
fi
