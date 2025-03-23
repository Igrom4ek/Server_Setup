#!/bin/bash

# === setup_server_master.sh ===
# Мастер-скрипт для загрузки и запуска setup_server.sh с поддержкой config.json

SCRIPT_URL_BASE="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
SETUP_SCRIPT_PATH="/usr/local/bin/setup_server.sh"
SSH_KEY_PATH="/usr/local/bin/ssh_key.pub"
CONFIG_FILE="/usr/local/bin/config.json"
LOG_FILE="/var/log/setupv2_master.log"

# Функция логирования
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

# Установка jq, если отсутствует
if ! command -v jq &>/dev/null; then
  log "📦 Устанавливаем jq..."
  sudo apt update && sudo apt install jq -y
  if ! command -v jq &>/dev/null; then
    log "❌ Не удалось установить jq"
    exit 1
  fi
fi

# Загрузка config.json, если его нет
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "📥 Загружаем config.json с GitHub..."
  curl -fsSL "$SCRIPT_URL_BASE/config.json" -o "$CONFIG_FILE"
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
SSH_KEY_FILE_CONFIG=$(jq -r '.ssh_key_file // "/usr/local/bin/ssh_key.pub"' "$CONFIG_FILE")

# Переопределение параметров через аргументы командной строки
for arg in "$@"; do
  case $arg in
    --username=*) USERNAME="${arg#*=}" ;;
    --port=*) PORT="${arg#*=}" ;;
    --key-file=*) SSH_KEY_FILE_CONFIG="${arg#*=}" ;;
    --config=*) CONFIG_FILE="${arg#*=}" ;;
  esac
done

log "🚀 Установка setup_server через мастер-скрипт"

# Загрузка setup_server.sh
log "📦 Загружаем setup_server.sh..."
curl -fsSL "$SCRIPT_URL_BASE/bin/setup_server.sh" -o "$SETUP_SCRIPT_PATH"
if [[ $? -ne 0 ]]; then
  log "❌ Не удалось загрузить setup_server.sh"
  exit 1
fi
chmod +x "$SETUP_SCRIPT_PATH"
log "✅ setup_server.sh установлен"

# Загрузка ssh_key.pub, если указан в config.json
if [[ "$SSH_KEY_FILE_CONFIG" == "$SSH_KEY_PATH" ]] && [[ ! -f "$SSH_KEY_PATH" ]]; then
  log "📥 Загружаем SSH-ключ с GitHub..."
  curl -fsSL "$SCRIPT_URL_BASE/bin/ssh_key.pub" -o "$SSH_KEY_PATH"
  if [[ $? -ne 0 ]]; then
    log "❌ Не удалось загрузить ssh_key.pub"
    exit 1
  fi
  chmod 644 "$SSH_KEY_PATH"
  log "✅ SSH-ключ загружен"
else
  SSH_KEY_PATH="$SSH_KEY_FILE_CONFIG"
  if [[ ! -f "$SSH_KEY_PATH" ]]; then
    log "⚠️ SSH-ключ не найден: $SSH_KEY_PATH. Установка прервана."
    exit 1
  fi
fi

# Запуск setup_server.sh с параметрами
log "🚀 Запускаем установку сервера с параметрами: username=$USERNAME, port=$PORT, key-file=$SSH_KEY_PATH"
sudo "$SETUP_SCRIPT_PATH" --username "$USERNAME" --port "$PORT" --key-file "$SSH_KEY_PATH" "$@"

if [[ $? -eq 0 ]]; then
  log "🏁 Установка успешно завершена"
else
  log "❌ Ошибка при выполнении setup_server.sh"
  exit 1
fi