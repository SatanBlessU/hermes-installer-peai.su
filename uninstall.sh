#!/usr/bin/env bash
# ==============================================================================
# Скрипт полного удаления Hermes Agent и Hermes WebUI (Clean Reset)
# ==============================================================================

set -Eeuo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m'

log_info()    { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[OK]${NC} $1"; }
log_warn()    { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error()   { echo -e "${RED}[ERROR]${NC} $1"; }

if [[ $EUID -ne 0 ]]; then
  log_error "Скрипт должен быть запущен с правами root или через sudo!"
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

echo "=================================================================="
echo -e "${RED}${BOLD}   Полное удаление стека Hermes Agent & Hermes WebUI${NC}"
echo "=================================================================="
log_info "Целевой пользователь: ${TARGET_USER} (${TARGET_HOME})"

# ------------------------------------------------------------------------------
# 1. Остановка и удаление служб Systemd
# ------------------------------------------------------------------------------
log_info "1. Остановка и отключение служб systemd..."

for service in hermes-webui.service hermes-agent.service; do
  systemctl stop "$service" 2>/dev/null || true
  systemctl disable "$service" 2>/dev/null || true
  rm -f "/etc/systemd/system/${service}"
  rm -f "/etc/systemd/system/multi-user.target.wants/${service}"
  rm -f "/etc/systemd/system/${service}.d"/* 2>/dev/null || true
done

systemctl daemon-reload
systemctl reset-failed 2>/dev/null || true
log_success "Службы systemd остановлены и удалены."

# ------------------------------------------------------------------------------
# 2. Завершение оставшихся процессов
# ------------------------------------------------------------------------------
log_info "2. Завершение фоновых процессов..."

pkill -9 -f 'hermes-webui' 2>/dev/null || true
pkill -9 -f 'bootstrap.py' 2>/dev/null || true
pkill -9 -f 'ctl.sh' 2>/dev/null || true
pkill -9 -f 'hermes gateway' 2>/dev/null || true
pkill -9 -f 'hermes setup' 2>/dev/null || true
pkill -9 -f 'hermes_cli' 2>/dev/null || true
pkill -9 -f 'hermes-agent' 2>/dev/null || true
pkill -9 -f 'server.py' 2>/dev/null || true

log_success "Все фоновые процессы завершены."

# ------------------------------------------------------------------------------
# 3. Полное удаление файлов, конфигураций и каталогов .hermes
# ------------------------------------------------------------------------------
log_info "3. Очистка каталогов установки, .hermes и виртуальных окружений..."

# Удаление WebUI
rm -rf /opt/hermes-webui
rm -rf /tmp/check-webui

# Удаление всех каталогов .hermes у всех пользователей и root
rm -rf /root/.hermes
rm -rf /root/.hermes_state 2>/dev/null || true
rm -rf "${TARGET_HOME}/.hermes"
for u_home in /home/*; do
  if [[ -d "$u_home" ]]; then
    rm -rf "${u_home}/.hermes"
  fi
done

# Удаление глобальных каталогов hermes-agent
rm -rf /usr/local/lib/hermes-agent 2>/dev/null || true
rm -rf /usr/lib/hermes-agent 2>/dev/null || true
rm -rf /opt/hermes-agent 2>/dev/null || true

# Удаление бинарников и симлинков
rm -f /usr/local/bin/hermes
rm -f /usr/local/bin/hermes-agent
rm -f /usr/local/bin/hermes-acp
rm -f /usr/bin/hermes
rm -f "${TARGET_HOME}/.local/bin/hermes"
rm -f "${TARGET_HOME}/.local/bin/hermes-agent"
rm -f "${TARGET_HOME}/.local/bin/hermes-acp"
rm -f /root/.local/bin/hermes
rm -f /root/.local/bin/hermes-agent
rm -f /root/.local/bin/hermes-acp

# Удаление uv tool окружений
rm -rf "${TARGET_HOME}/.local/share/uv/tools/hermes-agent" 2>/dev/null || true
rm -rf "/root/.local/share/uv/tools/hermes-agent" 2>/dev/null || true

log_success "Каталоги .hermes и все файлы успешно удалены."

# ------------------------------------------------------------------------------
# 4. Очистка правил фаервола
# ------------------------------------------------------------------------------
if command -v ufw >/dev/null 2>&1; then
  if ufw status 2>/dev/null | grep -qw "active"; then
    log_info "4. Очистка правил UFW (порт 8787)..."
    ufw delete allow 8787/tcp 2>/dev/null || true
  fi
fi

echo "=================================================================="
echo -e "${GREEN}${BOLD}             СИСТЕМА ПОЛНОСТЬЮ ОЧИЩЕНА!${NC}"
echo "=================================================================="
echo "Папки .hermes и все службы удалены. Сервер готов к чистой установке."
echo "=================================================================="
