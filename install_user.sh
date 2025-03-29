#!/bin/bash
export HOME="$USER_HOME_DIR"
TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"

# Директория для данных бота (доступна пользователю)
DATA_DIR="$HOME/.local/share/telegram_bot"
mkdir -p "$DATA_DIR"
OFFSET_FILE="$DATA_DIR/offset"
LAST_COMMAND_FILE="$DATA_DIR/last_command"
REBOOT_FLAG_FILE="$DATA_DIR/reboot_flag"
LOG_FILE="$DATA_DIR/bot_debug.log"

# Логирование всех действий бота для отладки
exec >>"$LOG_FILE" 2>&1
set -x

# Инициализация смещения для получения обновлений
OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

# Функция отправки обычного текстового сообщения
send_message() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    --data-urlencode chat_id="${CHAT_ID}" \
    --data-urlencode parse_mode="Markdown" \
    --data-urlencode text="${text}" > /dev/null
}

# Функция отправки сообщения с inline-кнопками (клавиатурой)
send_keyboard() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
    -d chat_id="${CHAT_ID}" -d parse_mode="Markdown" \
    --data-urlencode text="${text}" \
    --data-urlencode reply_markup='{
      "inline_keyboard": [
        [ {"text":"🖥 Uptime","callback_data":"uptime"}, {"text":"💾 Disk","callback_data":"disk"} ],
        [ {"text":"🧠 Memory","callback_data":"mem"}, {"text":"📈 Top","callback_data":"top"} ],
        [ {"text":"👥 Who","callback_data":"who"}, {"text":"🌐 IP","callback_data":"ip"} ],
        [ {"text":"🔒 Security Check","callback_data":"security"} ],
        [ {"text":"🧹 Очистить логи PSAD","callback_data":"clear_psad"} ],
        [ {"text":"📋 Чек-лист","callback_data":"checklist"} ],
        [ {"text":"♻️ Reboot","callback_data":"reboot"}, {"text":"🔄 Restart Bot","callback_data":"restart_bot"} ]
      ]
    }' > /dev/null
}

# Функция ответа на callback (для снятия "часиков" Telegram)
answer_callback() {
  local cid="$1"
  local msg="${2:-}"
  local alert="${3:-false}"
  if [[ -z "$msg" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/answerCallbackQuery" \
      -d callback_query_id="$cid" > /dev/null
  else
    curl -s -X POST "https://api.telegram.org/bot${TOKEN}/answerCallbackQuery" \
      -d callback_query_id="$cid" \
      --data-urlencode text="$msg" \
      -d show_alert="$alert" > /dev/null
  fi
}

# Функция получения обновлений от Telegram
get_updates() {
  curl -s "https://api.telegram.org/bot${TOKEN}/getUpdates?offset=${OFFSET}"
}

# Основной цикл обработки обновлений
while true; do
  RESPONSE=$(get_updates)
  UPDATES=$(echo "$RESPONSE" | jq -c ".result")
  LENGTH=$(echo "$UPDATES" | jq "length")
  [[ "$LENGTH" -eq 0 ]] && sleep 2 && continue

  for ((i = 0; i < $LENGTH; i++)); do
    UPDATE=$(echo "$UPDATES" | jq -c ".[$i]")
    UPDATE_ID=$(echo "$UPDATE" | jq ".update_id")
    OFFSET=$((UPDATE_ID + 1))
    echo "$OFFSET" > "$OFFSET_FILE"

    # Извлечение текстовой команды или данных callback
    MESSAGE_TEXT=$(echo "$UPDATE" | jq -r ".message.text // empty")
    CALLBACK_DATA=$(echo "$UPDATE" | jq -r ".callback_query.data // empty")
    CALLBACK_ID=$(echo "$UPDATE" | jq -r ".callback_query.id // empty")

    # Защита от слишком частых повторов (дебаунс 3 секунды)
    NOW=$(date +%s)
    LAST_CMD=$(cat "$LAST_COMMAND_FILE" 2>/dev/null || echo "0")
    DIFF=$((NOW - LAST_CMD))
    [[ "$DIFF" -lt 3 ]] && continue
    echo "$NOW" > "$LAST_COMMAND_FILE"

    # Определение команды (приоритет callback_data)
    if [[ -n "$CALLBACK_DATA" ]]; then
      CMD="$CALLBACK_DATA"
    elif [[ -n "$MESSAGE_TEXT" ]]; then
      CMD="$MESSAGE_TEXT"
    else
      continue
    fi

    case "$CMD" in
      "/start" | "/help" | "help")
        # Отправляем меню с кнопками
        send_keyboard "*Доступные команды:*"
        ;;

      "/uptime" | "uptime")
        send_message "*Аптайм:* $(uptime -p)"
        ;;

      "/disk" | "disk")
        send_message " \`\`\`$(df -h /)\`\`\`"
        ;;

      "/mem" | "mem")
        send_message " \`\`\`$(free -h)\`\`\`"
        ;;

      "/top" | "top")
        send_message " \`\`\`$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 10)\`\`\`"
        ;;

      "/who" | "who")
        # Информация о текущих сессиях пользователей с геолокацией
        WHO_INFO=""
        while read -r user tty date time ip; do
          IP_ADDR=$(echo "$ip" | tr -d "()")
          GEO=$(curl -s ipinfo.io/$IP_ADDR | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
          WHO_INFO+="👤 $user — $IP_ADDR\n🌍 $GEO\n\n"
        done <<< "$(who | awk '{print $1, $2, $3, $4, $5}')"
        send_message "*Сессии пользователей:*\n\n${WHO_INFO}"
        ;;

      "/ip" | "ip")
        # Внутренний и внешний IP + геолокация внешнего IP
        IP_INT=$(hostname -I | awk '{print $1}')
        IP_EXT=$(curl -s ifconfig.me)
        GEO=$(curl -s ipinfo.io/$IP_EXT | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
        send_message "*Внутренний IP:* \`$IP_INT\`\n*Внешний IP:* \`$IP_EXT\`\n🌍 *Геолокация:* $GEO"
        ;;

      "/security" | "security")
        # Подтверждаем получение команды (особенно важно для callback, чтобы убрать индикатор)
        if [[ -n "$CALLBACK_ID" ]]; then
          answer_callback "$CALLBACK_ID" "⏳ Выполняется проверка системы..."
        fi
        # Проверка RKHunter (таймаут 30 сек)
        OUT=$(timeout 30s sudo rkhunter --check --sk --nocolors --rwo || echo "RKHUNTER_TIMEOUT")
        if [[ "$OUT" == "RKHUNTER_TIMEOUT" ]]; then
          RKHUNTER_RESULT="⚠️ rkhunter не завершил проверку за 30 секунд"
        else
          RKHUNTER_RESULT=$(echo "$OUT" | tail -n 100)
        fi
        # Фильтрация логов PSAD за последние 24 часа
        if [[ -f /var/log/psad/alert ]]; then
          TODAY=$(date "+%b %_d")      # формат даты, совпадающий с логом (например, "Sep 30")
          YEST=$(date -d "yesterday" "+%b %_d")
          PSAD_LINES=$(grep -E "$YEST|$TODAY" /var/log/psad/alert)
          PSAD_ALERTS_LASTDAY=$(echo "$PSAD_LINES" | grep "Danger level" | tail -n 20)
          [[ -z "$PSAD_ALERTS_LASTDAY" ]] && PSAD_ALERTS_LASTDAY="Лог PSAD пуст."
          TOP_IPS=$(echo "$PSAD_LINES" | grep -i "Danger level" | tail -n 10)
          [[ -z "$TOP_IPS" ]] && TOP_IPS="Нет записей о сканированиях."
        else
          PSAD_ALERTS_LASTDAY="psad не установлен или лог недоступен."
          TOP_IPS=""
        fi
        # Отправка единого сообщения с отчетом
        send_message "*RKHunter:*\n\`\`\`${RKHUNTER_RESULT}\`\`\`\n\n*PSAD (последние 24ч):*\n\`\`\`${PSAD_ALERTS_LASTDAY}\`\`\`\n\n*Top 10 IP (PSAD):*\n\`\`\`${TOP_IPS}\`\`\`"
        ;;

      "clear_psad")
        # Очистка логов PSAD
        if sudo truncate -s 0 /var/log/psad/alert 2>/dev/null; then
          send_message "🧹 Логи PSAD очищены."
        else
          send_message "❌ Не удалось очистить логи PSAD (недостаточно прав)."
        fi
        ;;

      "checklist")
        # Сбор текущего статуса системы
        CHECKLIST="Чек-лист системы:\n"
        # Статусы служб
        CHECKLIST+="Службы:\n"
        for SERVICE in ufw fail2ban psad rkhunter; do
          if systemctl is-active --quiet "$SERVICE"; then
            CHECKLIST+="  [+] $SERVICE\n"
          else
            CHECKLIST+="  [ ] $SERVICE\n"
          fi
        done
        # Статус Telegram-бота
        if systemctl is-active --quiet telegram_command_listener.service; then
          CHECKLIST+="  [+] Telegram-бот\n"
        else
          CHECKLIST+="  [ ] Telegram-бот\n"
        fi
        # Статус мониторинга (Netdata)
        if pgrep -x "netdata" >/dev/null 2>&1; then
          IP=$(hostname -I | awk '{print $1}')
          CHECKLIST+="Netdata: http://$IP:19999 (активна)\n"
        elif sudo docker ps -q -f name=netdata >/dev/null 2>&1; then
          IP=$(hostname -I | awk '{print $1}')
          CHECKLIST+="Netdata: http://$IP:19999 (Docker)\n"
        else
          CHECKLIST+="Netdata: не запущена\n"
        fi
        # Открытые порты и процессы
        PORTS_INFO=$(sudo ss -tulpnH | awk '/LISTEN/ || /UNCONN/ {
            split($5,a,":"); 
            port=a[length(a)]; 
            proc=$NF; 
            if(proc == "-" || proc == "*") proc="-"; 
            else { sub(/users:\(\(/,"",proc); sub(/\).*/,"",proc); } 
            printf "    %s : %s\n", port, proc 
        }')
        if [[ -n "$PORTS_INFO" ]]; then
          CHECKLIST+="Открытые порты:\n$PORTS_INFO"
        else
          CHECKLIST+="Открытые порты: (не удалось получить список)\n"
        fi
        # Последний статус RKHunter из лога (ежедневная проверка)
        RKH_LAST=$(sudo grep "RKHunter" /var/log/security_monitor.log 2>/dev/null | tail -1)
        if [[ "$RKH_LAST" =~ "⚠️" ]]; then
          CHECKLIST+="RKHunter: ОБНАРУЖЕНЫ предупреждения\n"
        elif [[ "$RKH_LAST" =~ "✅" ]]; then
          CHECKLIST+="RKHunter: OK (чисто)\n"
        else
          CHECKLIST+="RKHunter: нет данных\n"
        fi
        # Последний статус PSAD из лога
        PSAD_LAST=$(sudo grep "PSAD" /var/log/security_monitor.log 2>/dev/null | tail -1)
        if [[ "$PSAD_LAST" =~ "🚨" ]]; then
          CHECKLIST+="PSAD: обнаружена подозрительная активность\n"
        elif [[ "$PSAD_LAST" =~ "✅" ]]; then
          CHECKLIST+="PSAD: OK (спокойно)\n"
        else
          CHECKLIST+="PSAD: нет данных\n"
        fi
        # Отправка чек-листа (как блок кода для сохранения форматирования)
        CHECKLIST_ESC=$(echo "$CHECKLIST" | sed 's/`/\\`/g')
        send_message "\`\`\`${CHECKLIST_ESC}\`\`\`"
        ;;

      "/reboot" | "reboot")
        echo "1" > "$REBOOT_FLAG_FILE"
        if [[ -n "$CALLBACK_ID" ]]; then
          # При нажатии кнопки – отправляем клавиатуру подтверждения
          curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" \
            -d chat_id="${CHAT_ID}" -d parse_mode="Markdown" \
            --data-urlencode text="⚠️ Подтвердите перезагрузку сервера" \
            --data-urlencode reply_markup='{"inline_keyboard":[[{"text":"✔️ Подтвердить","callback_data":"confirm_reboot"},{"text":"❌ Отмена","callback_data":"cancel_reboot"}]]}' > /dev/null
          answer_callback "$CALLBACK_ID"
        else
          send_message "⚠️ Подтвердите перезагрузку командой /confirm_reboot"
        fi
        ;;

      "confirm_reboot" | "/confirm_reboot")
        if [[ -f "$REBOOT_FLAG_FILE" ]]; then
          send_message "♻️ Перезагрузка сервера..."
          rm -f "$REBOOT_FLAG_FILE"
          sleep 2
          sudo reboot
        else
          send_message "Нет активного запроса на перезагрузку."
        fi
        ;;

      "/restart_bot" | "restart_bot")
        send_message "🔄 Перезапуск бота..."
        sleep 1
        sudo systemctl restart telegram_command_listener.service
        exit 0
        ;;

      "/botlog" | "botlog")
        LOG=$(tail -n 30 "$LOG_FILE" 2>/dev/null || echo "Лог отсутствует.")
        send_message "*Лог бота:*\n\`\`\`${LOG}\`\`\`"
        ;;

      "cancel_reboot")
        # Отмена перезагрузки
        rm -f "$REBOOT_FLAG_FILE"
        send_message "Отмена перезагрузки."
        ;;

      *)
        send_message "Неизвестная команда. Напишите /help для списка."
        ;;
    esac

    # Если пришёл callback_query, на который ещё не ответили, убираем индикатор загрузки
    if [[ -n "$CALLBACK_ID" ]]; then
      answer_callback "$CALLBACK_ID"
    fi
  done

  sleep 2
done
