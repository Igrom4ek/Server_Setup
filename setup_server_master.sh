#!/bin/bash

SCRIPT_URL_BASE="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
SETUP_SCRIPT_PATH="/usr/local/bin/setup_server.sh"
SSH_KEY_PATH="/usr/local/bin/ssh_key.pub"
LOG_FILE="/var/log/setupv2_master.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

log "🚀 Установка setup_server через мастер-скрипт"

# === Загрузка setup_server.sh ===
curl -fsSL "$SCRIPT_URL_BASE/bin/setup_server.sh" -o "$SETUP_SCRIPT_PATH"
chmod +x "$SETUP_SCRIPT_PATH"
log "✅ setup_server.sh установлен"

# === Загрузка ssh_key.pub ===
curl -fsSL "$SCRIPT_URL_BASE/bin/ssh_key.pub" -o "$SSH_KEY_PATH"
chmod 644 "$SSH_KEY_PATH"
log "✅ SSH ключ установлен"

# === Запуск установки ===
sudo "$SETUP_SCRIPT_PATH" --key-file "$SSH_KEY_PATH" "$@"

log "🏁 Установка завершена"
