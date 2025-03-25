#!/bin/bash

CONFIG="/usr/local/bin/config.json"
UPDATE_FILE="/tmp/telegram_last_update_id"
LOGFILE="/var/log/telegram_bot.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOGFILE"
}

get_config_value() {
    jq -r "$1" "$CONFIG"
}

send_message() {
    local message="$1"
    curl -s -X POST https://api.telegram.org/bot"$BOT_TOKEN"/sendMessage \
        -d chat_id="$CHAT_ID" \
        -d text="$message" \
        -d parse_mode="Markdown"
}

process_command() {
    local text="$1"
    case "$text" in
        "/status")
            local uptime_msg
            uptime_msg=$(uptime -p)
            send_message "*✅ Статус:* Сервер работает\n_Аптайм:_ \`$uptime_msg\`"
            ;;
        "/help")
            send_message "*📖 Доступные команды:*\n/status – Статус сервера\n/help – Помощь\n/log – Последние строки лога\n/security – Проверка безопасности"
            ;;
        "/log")
            local tail_text
            tail_text=$(tail -n 15 "$LOGFILE" 2>/dev/null)
            send_message "*🪵 Последние строки лога:*\n\`\`\`\n$tail_text\n\`\`\`"
            ;;
        "/security")
            local sec_check
            sec_check=$(sudo rkhunter --check --sk 2>/dev/null | grep -E "Warning|Checking|OK")
            send_message "*🛡 Безопасность:*\n\`\`\`\n$sec_check\n\`\`\`"
            ;;
        *)
            send_message "🤖 Я тебя не понял. Напиши /help"
            ;;
    esac
}

log "Telegram bot listener запущен"

while true; do
    if [[ ! -f "$CONFIG" ]]; then
        log "❌ Не найден config.json"
        sleep 10
        continue
    fi

    BOT_TOKEN=$(get_config_value '.telegram_bot_token')
    CHAT_ID=$(get_config_value '.telegram_chat_id')
    SERVER_LABEL=$(get_config_value '.telegram_server_label')

    LAST_UPDATE_ID=$(cat "$UPDATE_FILE" 2>/dev/null || echo 0)

    RESP=$(curl -s "https://api.telegram.org/bot$BOT_TOKEN/getUpdates?offset=$((LAST_UPDATE_ID + 1))")
    NEW_UPDATE_ID=$(echo "$RESP" | jq -r '.result[-1].update_id // empty')
    MESSAGE_TEXT=$(echo "$RESP" | jq -r '.result[-1].message.text // empty')
    SENDER_ID=$(echo "$RESP" | jq -r '.result[-1].message.chat.id // empty')

    if [[ -n "$NEW_UPDATE_ID" ]]; then
        echo "$NEW_UPDATE_ID" > "$UPDATE_FILE"
    fi

    if [[ -n "$MESSAGE_TEXT" && "$SENDER_ID" == "$CHAT_ID" ]]; then
        log "📩 Получена команда: $MESSAGE_TEXT"
        process_command "$MESSAGE_TEXT"
    fi

    sleep 5
done
