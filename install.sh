#!/bin/bash

CONFIG_FILE="/usr/local/bin/config.json"
SCRIPT_DIR="/usr/local/bin"
LOG_FILE="/var/log/setup_selector.log"
SCRIPT_URL_BASE="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

# Установка jq, если отсутствует
if ! command -v jq &>/dev/null; then
  log "📦 Устанавливаем jq..."
  apt update && apt install jq -y
fi

# Загрузка config.json, если отсутствует
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "📥 Загружаем config.json с GitHub..."
  curl -fsSL "$SCRIPT_URL_BASE/config.json" -o "$CONFIG_FILE"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "❌ Не удалось загрузить config.json"
    exit 1
  fi
  chmod 644 "$CONFIG_FILE"
  log "✅ config.json успешно загружен"
fi

# Извлечение параметров
USERNAME=$(jq -r '.username // "igrom"' "$CONFIG_FILE")
PORT=$(jq -r '.port // 5075' "$CONFIG_FILE")
KEY_FILE=$(jq -r '.ssh_key_file // "/usr/local/bin/ssh_key.pub"' "$CONFIG_FILE")

# Проверка SSH-ключа (загрузка или ввод вручную)
if [[ ! -f "$KEY_FILE" ]]; then
  log "⚠️ SSH-ключ не найден: $KEY_FILE"
  if curl -fsSL "$SCRIPT_URL_BASE/bin/id_ed25519.pub" -o "$KEY_FILE"; then
    chmod 644 "$KEY_FILE"
    log "✅ SSH-ключ загружен из GitHub в $KEY_FILE"
  else
    read -p "Введите SSH-публичный ключ вручную: " SSH_KEY
    if [[ ! "$SSH_KEY" =~ ^ssh-(rsa|ed25519) ]]; then
      echo "❌ Неверный формат SSH-ключа"
      exit 1
    fi
    echo "$SSH_KEY" > "$KEY_FILE"
    chmod 644 "$KEY_FILE"
    log "✅ SSH-ключ сохранён вручную в $KEY_FILE"
  fi
fi

for script in setup_server_master.sh secure_hardening_master.sh; do
  if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
    log "📥 Загружаем $script из GitHub..."
    curl -fsSL "$SCRIPT_URL_BASE/$script" -o "$SCRIPT_DIR/$script"
    chmod +x "$SCRIPT_DIR/$script"
  fi
done


# Меню выбора установки
PS3="Выберите мастер-скрипт для установки: "
options=(
  "1. Базовая установка сервера (setup_server_master.sh)"
  "2. Установка защиты и мониторинга (secure_hardening_master.sh)"
  "3. Выход"
)

select opt in "${options[@]}"
do
  case $REPLY in
    1)
      log "🚀 Запускаем базовую установку через setup_server_master.sh..."
      bash "$SCRIPT_DIR/setup_server_master.sh" --username="$USERNAME" --port="$PORT" --key-file="$KEY_FILE"
      break
      ;;
    2)
      log "🛡 Запускаем защиту и мониторинг через secure_hardening_master.sh..."
      bash "$SCRIPT_DIR/secure_hardening_master.sh"
      break
      ;;
    3)
      echo "👋 Выход."
      break
      ;;
    *)
      echo "❌ Неверный выбор. Повторите."
      ;;
  esac
done
