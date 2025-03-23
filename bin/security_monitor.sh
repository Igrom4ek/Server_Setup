#!/bin/bash

CONFIG_FILE="/usr/local/bin/config.json"

# Проверка и установка jq
if ! command -v jq &>/dev/null; then
  sudo apt update && sudo apt install jq -y
fi

# Проверка config.json
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ Файл конфигурации не найден: $CONFIG_FILE"
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
      -d text="${MESSAGE}\n${SERVER_LABEL}" > /dev/null
  fi
}

# Логирование
timestamp() {
  date '+%Y-%m-%d %H:%M:%S'
}
echo "$(timestamp) | 🚀 Запуск проверки безопасности" >> "$LOG_FILE"

# RKHUNTER CHECK
RKHUNTER_RESULT=$(sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
if [ -n "$RKHUNTER_RESULT" ]; then
  send_telegram "⚠️ *RKHunter нашёл подозрительные элементы:*\n\`\`\`\n$RKHUNTER_RESULT\n\`\`\`"
  echo "$(timestamp) | ⚠️ RKHunter: найдены подозрения" >> "$LOG_FILE"
else
  send_telegram "✅ *RKHunter*: нарушений не обнаружено"
  echo "$(timestamp) | ✅ RKHunter: всё чисто" >> "$LOG_FILE"
fi

# PSAD CHECK
PSAD_ALERTS=$(sudo grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
if echo "$PSAD_ALERTS" | grep -q "Danger level"; then
  send_telegram "🚨 *PSAD предупреждение:*\n\`\`\`\n$PSAD_ALERTS\n\`\`\`"
  echo "$(timestamp) | 🚨 PSAD: найдены угрозы" >> "$LOG_FILE"
else
  send_telegram "✅ *PSAD*: подозрительной активности не обнаружено"
  echo "$(timestamp) | ✅ PSAD: всё спокойно" >> "$LOG_FILE"
fi

echo "$(timestamp) | ✅ Проверка завершена" >> "$LOG_FILE"