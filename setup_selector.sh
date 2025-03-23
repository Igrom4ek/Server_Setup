#!/bin/bash

CONFIG_FILE="/usr/local/bin/config.json"
SCRIPT_DIR="/usr/local/bin"
LOG_FILE="/var/log/setup_selector.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ Файл конфигурации не найден: $CONFIG_FILE"
  exit 1
fi

PS3="Выберите режим установки: "
options=("1. Базовая установка сервера" "2. Защита и мониторинг" "3. Выход")
select opt in "${options[@]}"
do
  case $REPLY in
    1)
      log "🚀 Запускаем базовую установку сервера..."
      bash "$SCRIPT_DIR/setup_server.sh"
      break
      ;;
    2)
      log "🛡 Запускаем установку защиты и мониторинга..."
      bash "$SCRIPT_DIR/secure_extended.sh"
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
