#!/bin/bash

TOKEN="8019987480:AAEJdUAAiGqlTFjOahWNh3RY5hiEwo3-E54"
CHAT_ID="543102005"
OFFSET_FILE="$HOME/.cache/telegram_bot_offset"
LAST_COMMAND_FILE="$HOME/.cache/telegram_last_command"
REBOOT_FLAG_FILE="$HOME/.cache/telegram_confirm_reboot"
LOG_FILE="/tmp/bot_debug.log"

mkdir -p "$(dirname "$OFFSET_FILE")"
exec >>"$LOG_FILE" 2>&1
set -x

OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

send_message() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode chat_id="${CHAT_ID}" \
    --data-urlencode parse_mode="HTML" \
    --data-urlencode text="${text}" > /dev/null
}

escape_html() {
  echo "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

get_updates() {
  curl -s "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET"
}

while true; do
  RESPONSE=$(get_updates)
  UPDATES=$(echo "$RESPONSE" | jq -c '.result')
  LENGTH=$(echo "$UPDATES" | jq 'length')
  [[ "$LENGTH" -eq 0 ]] && sleep 2 && continue

  for ((i = 0; i < LENGTH; i++)); do
    UPDATE=$(echo "$UPDATES" | jq -c ".[$i]")
    UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')
    MESSAGE=$(echo "$UPDATE" | jq -r '.message.text')
    OFFSET=$((UPDATE_ID + 1))
    echo "$OFFSET" > "$OFFSET_FILE"

    NOW=$(date +%s)
    LAST_CMD=$(cat "$LAST_COMMAND_FILE" 2>/dev/null || echo "0")
    DIFF=$((NOW - LAST_CMD))
    [[ "$DIFF" -lt 3 ]] && continue
    echo "$NOW" > "$LAST_COMMAND_FILE"

    case "$MESSAGE" in
      /help | help)
        send_message "<b>Команды:</b><pre>/uptime — аптайм
/disk — диск
/mem — память
/top — топ процессов
/who — кто в системе + гео
/ip — IP + геолокация
/security — проверка rkhunter + psad
/reboot — перезагрузка сервера
/confirm_reboot — подтвердить перезагрузку
/restart_bot — перезапуск бота
/botlog — последние логи бота</pre>"
        ;;
      /uptime)
        send_message "<b>Аптайм:</b> $(uptime -p)"
        ;;
      /disk)
        TEXT=$(df -h / | escape_html)
        send_message "<pre>$TEXT</pre>"
        ;;
      /mem)
        TEXT=$(free -h | escape_html)
        send_message "<pre>$TEXT</pre>"
        ;;
      /top)
        TEXT=$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 10 | escape_html)
        send_message "<pre>$TEXT</pre>"
        ;;
      /who)
        WHO_WITH_GEO=""
        while read -r user tty date time ip; do
          IP=$(echo "$ip" | tr -d '()')
          GEO=$(curl -s ipinfo.io/$IP | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
          WHO_WITH_GEO+="👤 $user — $IP\n🌍 $GEO\n\n"
        done <<< "$(who | awk '{print $1, $2, $3, $4, $5}')"
        ESCAPED=$(echo "$WHO_WITH_GEO" | escape_html)
        send_message "<b>Сессии пользователей:</b>\n<pre>$ESCAPED</pre>"
        ;;
      /ip)
        IP_INT=$(hostname -I | awk '{print $1}')
        IP_EXT=$(curl -s ifconfig.me)
        GEO=$(curl -s ipinfo.io/$IP_EXT | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
        send_message "<b>Внутренний IP:</b> $IP_INT\n<b>Внешний IP:</b> $IP_EXT\n<b>Геолокация:</b> $GEO"
        ;;
      /security)
        send_message "⏳ Выполняется проверка безопасности. Это может занять до 30 секунд..."
        OUT=$(timeout 30s sudo rkhunter --check --sk --nocolors)
        EXIT_CODE=$?
        if [[ "$EXIT_CODE" -eq 124 ]]; then
          RKHUNTER_RESULT="⚠️ rkhunter не ответил за 30 секунд"
        else
          RKHUNTER_RESULT=$(echo "$OUT" | tail -n 100)
        fi
        if [[ -f /var/log/psad/alert ]]; then
          PSAD_RESULT=$(grep "Danger level" /var/log/psad/alert | tail -n 5)
          [[ -z "$PSAD_RESULT" ]] && PSAD_RESULT="psad лог пуст"
        else
          PSAD_RESULT="psad лог отсутствует"
        fi
        PSAD_STATUS=$(sudo psad -S | head -n 20 || echo "Ошибка запуска psad -S")
        TOP_IPS=$(sudo grep -i "danger level" /var/log/psad/alert | tail -n 10 || echo "Нет записей")

        send_message "<b>RKHunter (последние строки):</b><pre>$(echo "$RKHUNTER_RESULT" | escape_html)</pre>"
        send_message "<b>PSAD:</b><pre>$(echo "$PSAD_RESULT" | escape_html)</pre>"
        send_message "<b>Статус PSAD:</b><pre>$(echo "$PSAD_STATUS" | escape_html)</pre>"
        send_message "<b>Top IP-адреса с угрозами:</b><pre>$(echo "$TOP_IPS" | escape_html)</pre>"
        ;;
      /reboot)
        echo "1" > "$REBOOT_FLAG_FILE"
        send_message "⚠️ Подтвердите перезагрузку сервера командой <b>/confirm_reboot</b>"
        ;;
      /confirm_reboot)
        if [[ -f "$REBOOT_FLAG_FILE" ]]; then
          send_message "♻️ Перезагрузка сервера..."
          rm -f "$REBOOT_FLAG_FILE"
          sleep 2
          sudo reboot
        else
          send_message "Нет активного запроса на перезагрузку."
        fi
        ;;
      /restart_bot)
        send_message "🔄 Перезапуск Telegram-бота..."
        sleep 1
        sudo systemctl restart telegram_command_listener.service
        exit 0
        ;;
      /botlog)
        LOG=$(tail -n 30 "$LOG_FILE" 2>/dev/null || echo "Лог отсутствует.")
        send_message "<b>Лог бота:</b><pre>$(echo "$LOG" | escape_html)</pre>"
        ;;
      *)
        send_message "Неизвестная команда. Напиши /help"
        ;;
    esac
  done
  sleep 2
done
