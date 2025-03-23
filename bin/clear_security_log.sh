#!/bin/bash

CONFIG_FILE="/usr/local/bin/config.json"

# Проверка наличия jq
if ! command -v jq &>/dev/null; then
  echo "❌ Требуется jq. Установите: sudo apt install jq -y"
  exit 1
fi

# Проверка наличия config.json
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ Файл конфигурации не найден: $CONFIG_FILE"
  exit 1
fi

# Получаем путь к лог-файлу из config.json
LOG_FILE=$(jq -r '.security_log_file // "/var/log/security_monitor.log"' "$CONFIG_FILE")

# Очищаем лог
echo "$(date '+%Y-%m-%d %H:%M:%S') | 🧹 Очистка лога безопасности (еженедельно)" > "$LOG_FILE"
