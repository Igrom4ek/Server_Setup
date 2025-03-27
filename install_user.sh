#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

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

# === Проверка наличия старых файлов и служб ===
log "🔍 Проверка оставшихся файлов и сервисов"
ls -la /usr/local/bin/security_monitor.sh /usr/local/bin/clear_security_log.sh /etc/profile.d/notify_login.sh 2>/dev/null || true
systemctl status telegram_command_listener.service 2>/dev/null || true

# === Настройка polkit и sudo без пароля ===
log "🔒 Настройка polkit и sudo"
if [[ -f /etc/polkit-1/rules.d/49-nopasswd.rules ]]; then
  sudo rm -f /etc/polkit-1/rules.d/49-nopasswd.rules
  log "🗑 Удалены старые правила polkit"
fi

sudo mkdir -p /etc/polkit-1/rules.d
cat <<EOF | sudo tee /etc/polkit-1/rules.d/49-nopasswd.rules > /dev/null
polkit.addRule(function(action, subject) {
  if (subject.isInGroup("sudo")) {
    return polkit.Result.YES;
  }
});
EOF
sudo systemctl daemon-reexec

echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-$USER > /dev/null
sudo chmod 440 /etc/sudoers.d/90-$USER
log "✅ Политика sudo и polkit настроена"

# === Установка и настройка сервисов ===
log "📦 Установка и активация сервисов"
for SERVICE in ufw fail2ban psad rkhunter nmap; do
  if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
    sudo apt install -y "$SERVICE"
    [[ "$SERVICE" != "rkhunter" ]] && sudo systemctl enable --now "$SERVICE" || true
    log "✅ $SERVICE установлен и активирован"
  else
    log "⚠️ $SERVICE отключён в config.json"
  fi
done

# === Установка и настройка rkhunter ===
log "🛡 Настройка rkhunter"
sudo rkhunter --propupd
cat > /etc/systemd/system/rkhunter.service <<EOF
[Unit]
Description=Rootkit Hunter Service
After=network.target
[Service]
ExecStart=/usr/bin/rkhunter --cronjob
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reexec
sudo systemctl enable rkhunter.service
sudo systemctl start rkhunter.service
echo "0 1 * * * root /usr/bin/rkhunter --check --cronjob" | sudo tee /etc/cron.d/rkhunter-daily > /dev/null
log "✅ rkhunter настроен"

# === Установка Netdata, если включено ===
if [[ "$MONITORING_ENABLED" == "true" ]]; then
  log "📡 Установка Netdata"
  bash <(curl -Ss https://my-netdata.io/kickstart.sh) || log "❌ Не удалось установить Netdata"
fi

# === Telegram уведомления при входе ===
log "📲 Настройка Telegram-уведомлений"
cat > /etc/profile.d/notify_login.sh <<EOF
#!/bin/bash
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
LABEL="$LABEL"
USER_NAME=$(whoami)
IP_ADDR=$(who | awk '{print \$5}' | sed 's/[()]//g')
HOSTNAME=$(hostname)
LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")
MESSAGE="👤 SSH вход: *\$USER_NAME*%0A💻 \$HOSTNAME%0A🕒 \$LOGIN_TIME%0A🌐 IP: \\`\$IP_ADDR\\`%0A*Server:* \\`\$LABEL\\`"
curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$MESSAGE" > /dev/null
EOF
sudo chmod +x /etc/profile.d/notify_login.sh
log "✅ Telegram-уведомления настроены"

# === Cron-задачи ===
log "⏱ Добавляем cron-задачи"
TEMP_CRON=$(mktemp)
crontab -l 2>/dev/null > "$TEMP_CRON" || true
grep -v 'security_monitor\|clear_security_log' "$TEMP_CRON" > "${TEMP_CRON}.new"
echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> "${TEMP_CRON}.new"
echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> "${TEMP_CRON}.new"
crontab "${TEMP_CRON}.new"
rm -f "$TEMP_CRON" "${TEMP_CRON}.new"
log "✅ Cron-задачи добавлены"

# === Финальный чеклист ===
CHECKLIST=$(mktemp)
{
echo "✅ Установка завершена"
echo "👤 Пользователь: $USER"
echo "📦 Сервисы:"
for SERVICE in ufw fail2ban psad rkhunter nmap; do
  systemctl is-active --quiet "$SERVICE" && echo "  - $SERVICE: ✅ активен" || echo "  - $SERVICE: ⚠️ не активен"
done
echo "🕵️ Проверка rkhunter: /usr/bin/rkhunter --check"
echo "🕒 Cron задачи добавлены"
echo "📲 Telegram уведомления настроены"
} > "$CHECKLIST"

cat "$CHECKLIST"
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="\\`\`\`$(cat "$CHECKLIST")\\`\`\`" > /dev/null
rm "$CHECKLIST"

# === Очистка ===
log "🧹 Очистка install_user.sh"
[[ -f "$0" && "$0" == "$HOME/install_user.sh" ]] && rm -f "$0"