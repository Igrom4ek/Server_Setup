#!/bin/bash

LOG_FILE="/var/log/security_monitor.log"

# === TELEGRAM ===
BOT_TOKEN="8019987480:AAEJdUAAiGqlTFjOahWNh3RY5hiEwo3-E54"
CHAT_ID="543102005"

send_telegram() {
    MESSAGE="$1"
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d parse_mode="Markdown" \
        -d text="$MESSAGE" > /dev/null
}

# === ЛОГИ ===
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}
echo "$(timestamp) | 🚀 Запуск проверки безопасности" >> "$LOG_FILE"

# === RKHUNTER CHECK ===
RKHUNTER_RESULT=$(sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
if [ -n "$RKHUNTER_RESULT" ]; then
    send_telegram "⚠️ *RKHunter нашёл подозрительные элементы:*\n\`\`\`\n$RKHUNTER_RESULT\n\`\`\`"
    echo "$(timestamp) | ⚠️ RKHunter: найдены подозрения" >> "$LOG_FILE"
else
    send_telegram "✅ *RKHunter*: нарушений не обнаружено"
    echo "$(timestamp) | ✅ RKHunter: всё чисто" >> "$LOG_FILE"
fi

# === PSAD CHECK ===
PSAD_ALERTS=$(sudo grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
if echo "$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "🚨 *PSAD предупреждение:*\n\`\`\`\n$PSAD_ALERTS\n\`\`\`"
    echo "$(timestamp) | 🚨 PSAD: найдены угрозы" >> "$LOG_FILE"
else
    send_telegram "✅ *PSAD*: подозрительной активности не обнаружено"
    echo "$(timestamp) | ✅ PSAD: всё спокойно" >> "$LOG_FILE"
fi

echo "$(timestamp) | ✅ Проверка завершена" >> "$LOG_FILE"
