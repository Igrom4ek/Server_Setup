#!/bin/bash

# === setup_server_master.sh ===
# Мастер-скрипт для загрузки и запуска setup_server.sh с поддержкой config.json

SCRIPT_URL_BASE="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
SETUP_SCRIPT_PATH="/usr/local/bin/setup_server.sh"
CONFIG_FILE="/usr/local/bin/config.json"
LOG_FILE="/var/log/setupv2_master.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

log "🚀 Установка setup_server через мастер-скрипт"

# Установка jq, если отсутствует
if ! command -v jq &>/dev/null; then
  log "📦 Устанавливаем jq..."
  apt update && apt install jq -y
  if ! command -v jq &>/dev/null; then
    log "❌ Не удалось установить jq"
    exit 1
  fi
fi

# Загрузка config.json, если его нет
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "📥 Загружаем config.json с GitHub..."
  curl -fsSL "$SCRIPT_URL_BASE/bin/config.json" -o "$CONFIG_FILE"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "❌ Не удалось загрузить config.json"
    exit 1
  fi
  chmod 644 "$CONFIG_FILE"
  log "✅ config.json загружен"
fi

# Извлечение параметров из config.json
USERNAME=$(jq -r '.username // "igrom"' "$CONFIG_FILE")
PORT=$(jq -r '.port // 5075' "$CONFIG_FILE")
SSH_KEY_PATH=$(jq -r '.ssh_key_file // "/usr/local/bin/ssh_key.pub"' "$CONFIG_FILE")

# Переопределение параметров через аргументы командной строки
for arg in "$@"; do
  case $arg in
    --username=*) USERNAME="${arg#*=}" ;;
    --port=*) PORT="${arg#*=}" ;;
    --key-file=*) SSH_KEY_PATH="${arg#*=}" ;;
    *) CONFIG_FILE="$arg" ;;
  esac
  shift
end

log "🔧 Используем порт из config.json: $PORT"
log "🔧 Пользователь: $USERNAME"
log "🔧 SSH-ключ: $SSH_KEY_PATH"

# Загрузка setup_server.sh, если отсутствует
if [[ ! -f "$SETUP_SCRIPT_PATH" ]]; then
  log "📦 Загружаем setup_server.sh..."
  curl -fsSL "$SCRIPT_URL_BASE/bin/setup_server.sh" -o "$SETUP_SCRIPT_PATH"
  if [[ ! -f "$SETUP_SCRIPT_PATH" ]]; then
    log "❌ Не удалось загрузить setup_server.sh"
    exit 1
  fi
  chmod +x "$SETUP_SCRIPT_PATH"
  log "✅ setup_server.sh загружен"
fi

# Настройка SSH: изменение /etc/ssh/sshd_config
log "🛠 Настраиваем SSH-параметры в /etc/ssh/sshd_config..."
sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
sed -i "s|^#\?AuthorizedKeysFile .*|AuthorizedKeysFile .ssh/authorized_keys|" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config

# Добавление параметров, если они вообще отсутствуют
add_if_missing() {
  grep -q "^$1" /etc/ssh/sshd_config || echo "$1" >> /etc/ssh/sshd_config
}

add_if_missing "Port $PORT"
add_if_missing "PubkeyAuthentication yes"
add_if_missing "AuthorizedKeysFile .ssh/authorized_keys"
add_if_missing "PasswordAuthentication no"
add_if_missing "PermitRootLogin no"

log "🔄 Перезапускаем SSH на порту $PORT..."
systemctl restart ssh

# Запуск основного setup-скрипта
log "🚀 Выполняем setup_server.sh"
sudo bash "$SETUP_SCRIPT_PATH"
if [[ $? -ne 0 ]]; then
  log "❌ Ошибка при выполнении setup_server.sh"
  exit 1
fi

log "✅ Установка завершена"
exit 0