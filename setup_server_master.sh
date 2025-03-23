#!/bin/bash

# === setup_server_master.sh ===
# Мастер-скрипт для загрузки и запуска setup_server.sh с поддержкой config.json

SCRIPT_URL_BASE="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
SETUP_SCRIPT_PATH="/usr/local/bin/setup_server.sh"
CONFIG_FILE="/usr/local/bin/config.json"
LOG_FILE="/var/log/setupv2_master.log"
SCRIPT_DIR="/usr/local/bin"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

log "Установка setup_server через мастер-скрипт"

# Установка jq, если отсутствует
if ! command -v jq &>/dev/null; then
  log "Устанавливаем jq..."
  apt update && apt install jq -y
  if ! command -v jq &>/dev/null; then
    log "Не удалось установить jq"
    exit 1
  fi
fi

# Загрузка config.json, если его нет
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "Загружаем config.json с GitHub..."
  curl -fsSL "$SCRIPT_URL_BASE/bin/config.json" -o "$CONFIG_FILE"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "Не удалось загрузить config.json"
    exit 1
  fi
  chmod 644 "$CONFIG_FILE"
  log "config.json загружен"
fi

# Извлечение параметров из config.json
USERNAME=$(jq -r '.username // "igrom"' "$CONFIG_FILE")
PORT=$(jq -r '.port // 5075' "$CONFIG_FILE")
SSH_KEY_PATH=$(jq -r '.ssh_key_file // "/usr/local/bin/ssh_key.pub"' "$CONFIG_FILE")

# Переопределение параметров через аргументы командной строки
while [[ $# -gt 0 ]]; do
  case $1 in
    --username=*) USERNAME="${1#*=}" ;;
    --port=*) PORT="${1#*=}" ;;
    --key-file=*) SSH_KEY_PATH="${1#*=}" ;;
    *) CONFIG_FILE="$1" ;;
  esac
  shift
done

log "Используем порт из config.json: $PORT"
log "Пользователь: $USERNAME"
log "SSH-ключ: $SSH_KEY_PATH"

# Загрузка необходимых скриптов
for script in setup_server.sh install.sh secure_hardening_master.sh; do
  if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
    log "Загружаем $script..."
    curl -fsSL "$SCRIPT_URL_BASE/bin/$script" -o "$SCRIPT_DIR/$script"
    if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
      log "Не удалось загрузить $script"
      exit 1
    fi
    chmod +x "$SCRIPT_DIR/$script"
    log "$script загружен"
  fi
done

# Настройка SSH: изменение /etc/ssh/sshd_config
log "Настраиваем SSH-параметры в /etc/ssh/sshd_config..."
sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" /etc/ssh/sshd_config
sed -i "s|^#\?AuthorizedKeysFile .*|AuthorizedKeysFile .ssh/authorized_keys|" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config

# Добавление параметров, если они отсутствуют
add_if_missing() {
  grep -q "^$1" /etc/ssh/sshd_config || echo "$1" >> /etc/ssh/sshd_config
}

add_if_missing "Port $PORT"
add_if_missing "PubkeyAuthentication yes"
add_if_missing "AuthorizedKeysFile .ssh/authorized_keys"
add_if_missing "PasswordAuthentication no"
add_if_missing "PermitRootLogin no"

log "Перезапускаем SSH на порту $PORT..."
systemctl restart sshd
if [[ $? -ne 0 ]]; then
  log "Ошибка при перезапуске SSH"
  exit 1
fi

# Установка Docker
log "Устанавливаем Docker через install.sh..."
bash "$SCRIPT_DIR/install.sh"
if [[ $? -ne 0 ]]; then
  log "Ошибка при выполнении install.sh"
  exit 1
fi

# Настройка безопасности
log "Настраиваем безопасность через secure_hardening_master.sh..."
bash "$SCRIPT_DIR/secure_hardening_master.sh"
if [[ $? -ne 0 ]]; then
  log "Ошибка при выполнении secure_hardening_master.sh"
  exit 1
fi

# Запуск основного setup-скрипта
log "Выполняем setup_server.sh..."
bash "$SETUP_SCRIPT_PATH"
if [[ $? -ne 0 ]]; then
  log "Ошибка при выполнении setup_server.sh"
  exit 1
fi

log "Установка завершена"
exit 0