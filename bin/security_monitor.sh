#!/bin/bash

CONFIG_FILE="/usr/local/bin/config.json"

# Проверка и установка jq
if ! command -v jq &>/dev/null; then
  echo "Устанавливаем jq..." >&2
  sudo apt update && sudo apt install jq -y
  if [[ $? -ne 0 ]]; then
    echo "Ошибка установки jq" >&2
    exit 1
  fi
fi

# Проверка config.json
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Файл конфигурации не найден: $CONFIG_FILE" >&2
  exit 1
fi

# Извлечение параметров
LOG_FILE=$(jq -r '.security_log_file // "/var/log/security_monitor.log"' "$CONFIG_FILE")
BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")
SERVER_LABEL=$(jq -r '.telegram_server_label // "Unknown Server"' "$CONFIG_FILE")

# Функция отправки в Telegram
send_telegram() {
  MESSAGE="$1"
  if [[ "$BOT_TOKEN" != "null" && "$CHAT_ID" != "null" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d chat_id="${CHAT_ID}" \
      -d parse_mode="Markdown" \
      -d text="${MESSAGE}\n*Server:* \`${SERVER_LABEL}\`" > /dev/null
    if [[ $? -ne 0 ]]; then
      echo "$(timestamp) | Ошибка отправки уведомления в Telegram" >> "$LOG_FILE"
    fi
  else
    echo "$(timestamp) | Telegram-уведомления отключены (токен или чат не указаны)" >> "$LOG_FILE"
  fi
}

# Функция для временной метки
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}

# Проверка существования лог-файла и его прав
if [[ ! -f "$LOG_FILE" ]]; then
  touch "$LOG_FILE"
  chmod 640 "$LOG_FILE"
fi

# Начало проверки
echo "$(timestamp) | Запуск проверки безопасности" >> "$LOG_FILE"

# RKHUNTER CHECK
if command -v rkhunter &>/dev/null; then
  RKHUNTER_RESULT=$(sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
  if [ -n "$RKHUNTER_RESULT" ]; then
    send_telegram "⚠️ *RKHunter нашёл подозрительные элементы:*\n\`\`\`\n$RKHUNTER_RESULT\n\`\`\`"
    echo "$(timestamp) | RKHunter: найдены подозрения" >> "$LOG_FILE"
  else
    send_telegram "✅ *RKHunter*: нарушений не обнаружено"
    echo "$(timestamp) | RKHunter: всё чисто" >> "$LOG_FILE"
  fi
else
  echo "$(timestamp) | RKHunter не установлен, пропускаем проверку" >> "$LOG_FILE"
fi

# PSAD CHECK
if command -v psad &>/dev/null; then
  PSAD_ALERTS=$(sudo grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
  if echo "$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "🚨 *PSAD предупреждение:*\n\`\`\`\n$PSAD_ALERTS\n\`\`\`"
    echo "$(timestamp) | PSAD: найдены угрозы" >> "$LOG_FILE"
  else
    send_telegram "✅ *PSAD*: подозрительной активности не обнаружено"
    echo "$(timestamp) | PSAD: всё спокойно" >> "$LOG_FILE"
  fi
else
  echo "$(timestamp) | PSAD не установлен, пропускаем проверку" >> "$LOG_FILE"
fi

echo "$(timestamp) | Проверка завершена" >> "$LOG_FILE"
exit 0