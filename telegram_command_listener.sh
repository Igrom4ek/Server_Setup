#!/bin/bash

CONFIG_FILE="/usr/local/bin/config.json"
LOG_FILE="/var/log/security_monitor.log"
LAST_UPDATE_FILE="/tmp/telegram_last_update_id"

CONFIG=$(jq -r . "$CONFIG_FILE")
BOT_TOKEN=$(echo "$CONFIG" | jq -r '.telegram_bot_token')
CHAT_ID=$(echo "$CONFIG" | jq -r '.telegram_chat_id')

[[ -z "$BOT_TOKEN" || "$BOT_TOKEN" == "null" ]] && echo "❌ Нет токена бота" && exit 1

# Инициализация offset
LAST_UPDATE_ID=$(cat "$LAST_UPDATE_FILE" 2>/dev/null || echo 0)

# Отправка сообщения
send() {
  local TEXT="$1"
  TEXT=${TEXT//$'\n'/%0A}  # заменяем \n на %0A для корректной отправки
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$TEXT" > /dev/null
}

# 🟢 Уведомление о запуске
send "🟢 *Сервер запущен*%0AIP: $(hostname -I | awk '{print $1}')%0AИмя: $(hostname)%0AВремя: $(date '+%F %T')"

# Основной цикл
while true; do
  RESPONSE=$(curl -s --max-time 10 "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$((LAST_UPDATE_ID + 1))&timeout=10")

  # Проверка на валидный ответ
  if ! echo "$RESPONSE" | jq -e .result > /dev/null 2>&1; then
    echo "⚠️ Невалидный ответ от Telegram, жду 5 секунд..."
    sleep 5
    continue
  fi

  MESSAGES=$(echo "$RESPONSE" | jq -c '.result[]')

  for MSG in $MESSAGES; do
    UPDATE_ID=$(echo "$MSG" | jq -r '.update_id')
    TEXT=$(echo "$MSG" | jq -r '.message.text')
    USER_CHAT_ID=$(echo "$MSG" | jq -r '.message.chat.id')

    # Обрабатываем только команды от нужного пользователя
    if [[ "$USER_CHAT_ID" == "$CHAT_ID" ]]; then
      case "$TEXT" in
        /security)
          send "🛡 *Запущена проверка безопасности...*%0AОжидайте, это может занять до 1 минуты."
          bash /usr/local/bin/security_monitor.sh > /dev/null 2>&1
          sleep 1
          if [[ -f "$LOG_FILE" ]]; then
            CONTENT=$(tail -n 30 "$LOG_FILE" | sed 's/%/%25/g; s/`/%60/g') # экранирование
            send "📋 *Результат проверки:*%0A\`\`\`%0A$CONTENT%0A\`\`\`"
          else
            send "⚠️ Лог безопасности не найден."
          fi
          ;;

        /status)
          STATUS=$( (uptime; echo ""; free -h; echo ""; df -h /) )
          STATUS_ESCAPED=$(echo "$STATUS" | sed 's/%/%25/g; s/`/%60/g')
          send "🖥 *Статус сервера:*%0A\`\`\`%0A$STATUS_ESCAPED%0A\`\`\`"
          ;;

        /reboot)
          send "🔄 Сервер перезагрузится через 5 секунд..."
          sleep 5
          sudo reboot
          ;;

        /help)
          send "*Доступные команды:*%0A/help — помощь%0A/security — проверка%0A/status — статус%0A/reboot — перезагрузка"
          ;;

        *)
          send "🤖 Неизвестная команда. Введите /help"
          ;;
      esac
    fi

    # ✅ Сохраняем offset после обработки
    if [[ "$UPDATE_ID" =~ ^[0-9]+$ ]]; then
      echo "$UPDATE_ID" > "$LAST_UPDATE_FILE"
      LAST_UPDATE_ID="$UPDATE_ID"
    fi
  done

  sleep 5
done
