#!/bin/bash
set -e

# === secure_install.sh ===
# Настройка безопасности: fail2ban, psad, rkhunter, ufw, Telegram, cron

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
SERVICES=$(jq -r '.services' "$CONFIG_FILE")

log "⚙️ Установка безопасности..."

install_if_enabled() {
  local name="$1"
  local cmd="$2"
  if [[ "$(jq -r ".services.$name" "$CONFIG_FILE")" == "true" ]]; then
    log "Устанавливаем $name..."
    apt install -y $cmd
    systemctl enable --now $name || true
  else
    log "$name отключён в конфиге."
  fi
}

install_if_enabled "ufw" "ufw"
install_if_enabled "fail2ban" "fail2ban"
install_if_enabled "psad" "psad"
install_if_enabled "rkhunter" "rkhunter"

# === Создание security_monitor.sh ===
cat > /usr/local/bin/security_monitor.sh <<EOF
#!/bin/bash
LOG="/var/log/security_monitor.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
SERVER_LABEL="$LABEL"

send() {
  curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" \
    -d chat_id="\$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="\$1%0A*Server:* \\\`\$SERVER_LABEL\\\`" > /dev/null
}

echo "\$(date '+%F %T') | Запуск проверки безопасности" >> "\$LOG"

RKHUNTER_RESULT=\$(rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
[[ -n "\$RKHUNTER_RESULT" ]] && send "⚠️ *RKHunter нашёл подозрения:*%0A\`\`\`\$RKHUNTER_RESULT\`\`\`"

PSAD_RESULT=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
[[ -n "\$PSAD_RESULT" ]] && send "🚨 *PSAD предупреждение:*%0A\`\`\`\$PSAD_RESULT\`\`\`"

echo "\$(date '+%F %T') | Проверка завершена" >> "\$LOG"
EOF

chmod +x /usr/local/bin/security_monitor.sh

# === clear_security_log.sh ===
cat > /usr/local/bin/clear_security_log.sh <<EOF
#!/bin/bash
echo "\$(date '+%F %T') | Очистка лога" > /var/log/security_monitor.log
EOF
chmod +x /usr/local/bin/clear_security_log.sh

# === Уведомление о входе ===
cat > /etc/profile.d/notify_login.sh <<EOF
#!/bin/bash
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d parse_mode="Markdown" \
  -d text="👤 SSH вход: \$(whoami) на \$(hostname)%0A\`\$(date)\`" > /dev/null
EOF
chmod +x /etc/profile.d/notify_login.sh

# === Cron задачи ===
TEMP_CRON=\$(mktemp)
crontab -l 2>/dev/null > \$TEMP_CRON || true
grep -v 'security_monitor\|clear_security_log' \$TEMP_CRON > \${TEMP_CRON}.new
echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> \${TEMP_CRON}.new
echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> \${TEMP_CRON}.new
crontab \${TEMP_CRON}.new
rm -f \$TEMP_CRON \${TEMP_CRON}.new

log "✅ Защита установлена и активна!"
