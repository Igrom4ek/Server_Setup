#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then
  echo "❌ Скрипт должен быть запущен с sudo!"
  exit 1
fi

CONFIG_FILE="/usr/local/bin/config.json"
KEY_FILE="/usr/local/bin/id_ed25519.pub"
LOG="$HOME/install_user.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log "🚀 Установка сервисов от пользователя $USER"

# === Подгружаем параметры из config.json ===
BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")
LABEL=$(jq -r '.telegram_server_label' "$CONFIG_FILE")
SECURITY_CHECK_CRON=$(jq -r '.cron_tasks.security_check' "$CONFIG_FILE")
CLEAR_LOG_CRON=$(jq -r '.cron_tasks.clear_logs' "$CONFIG_FILE")
MONITORING_ENABLED=$(jq -r '.monitoring_enabled' "$CONFIG_FILE")

# === Проверка и очистка старых правил ===
log "🔍 Проверка старых файлов и служб"
rm -f /etc/polkit-1/rules.d/49-nopasswd.rules 2>/dev/null || true
rm -f /etc/sudoers.d/90-$USER 2>/dev/null || true

# === Настройка polkit и sudo ===
log "🔒 Настройка polkit и sudo без пароля"
mkdir -p /etc/polkit-1/rules.d
cat <<EOF > /etc/polkit-1/rules.d/49-nopasswd.rules
polkit.addRule(function(action, subject) {
  if (subject.isInGroup("sudo")) {
    return polkit.Result.YES;
  }
});
EOF
systemctl daemon-reexec

echo "$USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$USER
chmod 440 /etc/sudoers.d/90-$USER
log "✅ Политика sudo и polkit настроена"

# === Установка сервисов ===
log "📦 Установка и активация сервисов"
for SERVICE in ufw fail2ban psad rkhunter nmap; do
  if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
    apt install -y "$SERVICE"
    if systemctl list-unit-files | grep -q "^$SERVICE.service"; then
      systemctl enable --now "$SERVICE"
      log "✅ $SERVICE активирован"
    else
      log "ℹ️ $SERVICE не использует systemd — пропущено"
    fi
  else
    log "⚠️ $SERVICE отключён в config.json"
  fi
done

# === Настройка rkhunter + systemd ===
log "🛡 Настройка rkhunter"
rkhunter --propupd || true
cat <<EOF > /etc/systemd/system/rkhunter.service
[Unit]
Description=Rootkit Hunter Service
After=network.target
[Service]
ExecStart=/usr/bin/rkhunter --cronjob
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reexec
systemctl enable --now rkhunter.service
echo "0 1 * * * root /usr/bin/rkhunter --check --cronjob" > /etc/cron.d/rkhunter-daily
log "✅ rkhunter настроен"

# === Установка Netdata ===
if [[ "$MONITORING_ENABLED" == "true" ]]; then
  log "📡 Установка Netdata"
  bash <(curl -Ss https://my-netdata.io/kickstart.sh) || log "❌ Не удалось установить Netdata"
fi

# === Telegram-уведомления при входе ===
log "📲 Настройка Telegram-уведомлений"
cat > /etc/profile.d/notify_login.sh <<EOF
#!/bin/bash
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
LABEL="$LABEL"
USER_NAME=$(whoami)
IP_ADDR=\$(who | awk '{print \$5}' | sed 's/[()]//g')
HOSTNAME=\$(hostname)
LOGIN_TIME=\$(date "+%Y-%m-%d %H:%M:%S")
MESSAGE="👤 SSH вход: *\$USER_NAME*%0A💻 \$HOSTNAME%0A🕒 \$LOGIN_TIME%0A🌐 IP: \\`\$IP_ADDR\\`%0A*Server:* \\`\$LABEL\\`"
curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$MESSAGE" > /dev/null
EOF
chmod +x /etc/profile.d/notify_login.sh

# === Cron-задачи мониторинга ===
log "⏱ Настройка cron-задач"
cat > /usr/local/bin/security_monitor.sh <<EOF
#!/bin/bash
echo "[monitor] $(date)" >> /var/log/security_monitor.log
EOF
chmod +x /usr/local/bin/security_monitor.sh

cat > /usr/local/bin/clear_security_log.sh <<EOF
#!/bin/bash
echo "[clear] $(date)" > /var/log/security_monitor.log
EOF
chmod +x /usr/local/bin/clear_security_log.sh

TEMP_CRON=$(mktemp)
crontab -l 2>/dev/null > "$TEMP_CRON" || true
grep -v 'security_monitor\|clear_security_log' "$TEMP_CRON" > "${TEMP_CRON}.new"
echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> "${TEMP_CRON}.new"
echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> "${TEMP_CRON}.new"
crontab "${TEMP_CRON}.new"
rm -f "$TEMP_CRON" "${TEMP_CRON}.new"
log "✅ Cron-задачи добавлены"

# === Финальный чеклист ===
CHECKLIST="/tmp/install_checklist.txt"
{
echo "🛡️ Чеклист установки:"
echo "Пользователь: $USER"
echo "Активные сервисы:"
for SERVICE in ufw fail2ban psad rkhunter; do
  systemctl is-active --quiet "$SERVICE" && echo "  ✅ $SERVICE" || echo "  ❌ $SERVICE"
done
echo "Telegram уведомления: включены"
echo "rkhunter: проверка доступна /usr/bin/rkhunter --check"
echo "Cron-задачи добавлены"
} > "$CHECKLIST"

cat "$CHECKLIST"
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="\\`\`\`$(cat "$CHECKLIST")\\`\`\`" > /dev/null
rm "$CHECKLIST"

log "✅ Установка завершена"