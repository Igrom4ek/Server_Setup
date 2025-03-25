#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

# === secure_install.sh ===
# Настройка: fail2ban, psad, rkhunter, ufw, Telegram, cron

CONFIG_FILE="/usr/local/bin/config.json"
LOG="/var/log/security_setup.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

[[ ! -f "$CONFIG_FILE" ]] && echo "Файл $CONFIG_FILE не найден" && exit 1

BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")
LABEL=$(jq -r '.telegram_server_label' "$CONFIG_FILE")
CLEAR_LOG_CRON=$(jq -r '.clear_logs_cron' "$CONFIG_FILE")
SECURITY_CHECK_CRON=$(jq -r '.security_check_cron' "$CONFIG_FILE")

log "🛡 Настройка модулей безопасности..."

# Установка модулей (если включены)
for SERVICE in ufw fail2ban psad rkhunter; do
  if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
    log "Устанавливаем $SERVICE..."
    apt install -y "$SERVICE"
    [[ "$SERVICE" != "rkhunter" ]] && systemctl enable --now "$SERVICE" || true
  else
    log "$SERVICE отключён в config.json"
  fi
done

# === Создание security_monitor.sh ===
cat > /usr/local/bin/security_monitor.sh <<EOF
#!/bin/bash
LOG="/var/log/security_monitor.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
LABEL="$LABEL"

send() {
  curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" \
    -d chat_id="\$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="\$1%0A*Server:* \\\`\$LABEL\\\`" > /dev/null
}

echo "\$(date '+%F %T') | Запуск проверки безопасности" >> "\$LOG"

if command -v rkhunter &>/dev/null; then
  RKHUNTER_RESULT=\$(rkhunter --configfile /etc/rkhunter.conf --check --sk --nocolors --rwo 2>/dev/null || true)
  [[ -n "\$RKHUNTER_RESULT" ]] && send "⚠️ *RKHunter нашёл подозрения:*%0A\`\`\`\$RKHUNTER_RESULT\`\`\`"
fi

if command -v psad &>/dev/null; then
  PSAD_RESULT=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
  [[ -n "\$PSAD_RESULT" ]] && send "🚨 *PSAD предупреждение:*%0A\`\`\`\$PSAD_RESULT\`\`\`"
fi

echo "\$(date '+%F %T') | Проверка завершена" >> "\$LOG"
EOF

chmod +x /usr/local/bin/security_monitor.sh

# === clear_security_log.sh ===
cat > /usr/local/bin/clear_security_log.sh <<EOF
#!/bin/bash
echo "\$(date '+%F %T') | Очистка лога" > /var/log/security_monitor.log
EOF
chmod +x /usr/local/bin/clear_security_log.sh

# === notify_login.sh (telegram) ===
cat > /etc/profile.d/notify_login.sh <<'EOF'
#!/bin/bash
BOT_TOKEN="'"$BOT_TOKEN"'"
CHAT_ID="'"$CHAT_ID"'"
LABEL="'"$LABEL"'"
USER_NAME=$(whoami)
IP_ADDR=$(who | awk '{print $5}' | sed 's/[()]//g')
HOSTNAME=$(hostname)
LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")
MESSAGE="👤 SSH вход: *$USER_NAME*%0A💻 $HOSTNAME%0A🕒 $LOGIN_TIME%0A🌐 IP: \`$IP_ADDR\`%0A*Server:* \`$LABEL\`"
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d parse_mode="Markdown" \
  -d text="$MESSAGE" > /dev/null
EOF
chmod +x /etc/profile.d/notify_login.sh

# === Установка cron-задач ===
TEMP_CRON=$(mktemp)
crontab -l 2>/dev/null > "$TEMP_CRON" || true
grep -v 'security_monitor\|clear_security_log' "$TEMP_CRON" > "${TEMP_CRON}.new"
echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> "${TEMP_CRON}.new"
echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> "${TEMP_CRON}.new"
crontab "${TEMP_CRON}.new"
rm -f "$TEMP_CRON" "${TEMP_CRON}.new"

log "✅ Безопасность настроена успешно"
