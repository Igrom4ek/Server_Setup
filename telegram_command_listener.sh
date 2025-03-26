#!/bin/bash

# === telegram_command_listener.sh ===
# Telegram-бот для отправки отчёта rkhunter

BOT_TOKEN="__REPLACE_WITH_YOUR_BOT_TOKEN__"
CHAT_ID="__REPLACE_WITH_YOUR_CHAT_ID__"
LOG_FILE="/var/log/telegram_bot.log"
RKHUNTER_LOG="/var/log/rkhunter.log"
TMP_LOG="/tmp/rkhunter_parsed.log"

send_message() {
    local text="$1"
    curl -s -X POST https://api.telegram.org/bot$BOT_TOKEN/sendMessage \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        --data-urlencode text="$text"
}

parse_rkhunter_log() {
    echo "*Отчёт RKHunter (`date +'%Y-%m-%d %H:%M:%S'`)*" > "$TMP_LOG"

    grep -E 'Warning|Possible rootkits|[Ff]iles checked|Rootkits checked|Suspect files|Rootkit checks|Applications checks|System checks summary|Applications checks|File properties checks' "$RKHUNTER_LOG" >> "$TMP_LOG"

    send_message "\`cat $TMP_LOG\`"
}

main_loop() {
    while true; do
        echo "[$(date '+%F %T')] Telegram bot listener запущен" >> "$LOG_FILE"

        UPDATES=$(curl -s https://api.telegram.org/bot$BOT_TOKEN/getUpdates)

        if echo "$UPDATES" | grep -q "/security"; then
            send_message "Запускаю проверку безопасности. Это может занять ~1 минуту."
            echo "[$(date '+%F %T')] Получена команда: /security" >> "$LOG_FILE"

            sudo rkhunter --update > /dev/null
            sudo rkhunter --propupd > /dev/null
            sudo rkhunter --check --sk > /dev/null

            parse_rkhunter_log
        fi

        sleep 10
    done
}

main_loop
