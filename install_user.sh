#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

CONFIG_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/config.json"
KEY_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/id_ed25519.pub"
CONFIG_FILE="/usr/local/bin/config.json"
KEY_FILE="/usr/local/bin/id_ed25519.pub"
LOG="$HOME/install_user.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log "🚀 Установка сервисов от пользователя $USER"

# === Проверка наличия старых файлов и служб ===
log "🔍 Проверка оставшихся файлов и сервисов"

# Проверяем наличие файлов
ls -la /usr/local/bin/security_monitor.sh /usr/local/bin/clear_security_log.sh /etc/profile.d/notify_login.sh 2>/dev/null

# Проверяем статус telegram_command_listener.service
systemctl status telegram_command_listener.service 2>/dev/null

log "🔒 Отключаем запрос пароля polkit для группы sudo"
# Удаляем старые polkit-правила
if [[ -f /etc/polkit-1/rules.d/49-nopasswd.rules ]]; then
  sudo rm -f /etc/polkit-1/rules.d/49-nopasswd.rules
  log "Удалены старые правила polkit"
fi

# Создаём новые правила для sudo
sudo mkdir -p /etc/polkit-1/rules.d
cat <<EOF | sudo tee /etc/polkit-1/rules.d/49-nopasswd.rules > /dev/null
polkit.addRule(function(action, subject) {
  if (subject.isInGroup("sudo")) {
    return polkit.Result.YES;
  }
});
EOF
sudo systemctl daemon-reexec
log "✅ Политика polkit обновлена"

# Настройка sudo без пароля
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-$USER > /dev/null
sudo chmod 440 /etc/sudoers.d/90-$USER
log "✅ Настроено sudo без пароля для пользователя $USER"

# === Установка и настройка rkhunter ===
log "🛡 Настройка rkhunter и проверка на руткиты"

# Настроим параметры rkhunter
sudo nano /etc/rkhunter.conf <<EOF
MAIL-ON-WARNING=your-email@example.com
ALLOW_SSH_ROOT_USER=no
WEB_CMD=""
XINETD_CONF_PATH=/etc/xinetd.d
PKGMGR=DPKG
EOF

log "✅ Настроены параметры rkhunter"

# Обновим файловую базу rkhunter
sudo rkhunter --propupd
log "✅ Обновлена база данных rkhunter"

# === Создание systemd-сервиса для rkhunter ===
log "🔧 Создаём systemd-сервис для rkhunter"
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

# Активируем и запускаем сервис
sudo systemctl daemon-reexec
sudo systemctl enable rkhunter.service
sudo systemctl start rkhunter.service
log "✅ rkhunter systemd сервис создан и активирован"

# === Добавление cron-задачи для ежедневной проверки rkhunter ===
log "⏱ Настроим ежедневную проверку rkhunter"
echo "0 1 * * * root /usr/bin/rkhunter --check --cronjob" | sudo tee /etc/cron.d/rkhunter-daily
log "✅ Задача cron для ежедневной проверки rkhunter добавлена"

# === Настройка Telegram-бота для уведомлений ===
log "📲 Настройка Telegram-бота для уведомлений"
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
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage"   -d chat_id="$CHAT_ID"   -d parse_mode="Markdown"   -d text="$MESSAGE" > /dev/null
EOF
sudo chmod +x /etc/profile.d/notify_login.sh

log "✅ Настройка Telegram-уведомлений завершена"

# === Проверка установки сервисов ===
log "🔍 Проверка установки и активации сервисов"
for SERVICE in ufw fail2ban psad rkhunter; do
  sudo systemctl status "$SERVICE" &>/dev/null
  if [[ $? -eq 0 ]]; then
    log "✅ Сервис $SERVICE установлен и активирован"
  else
    log "❌ Сервис $SERVICE не активен. Пропускаем установку."
  fi
done

# === Очистка старого скрипта (если запущен из файла) ===
log "🧹 Удаляем install_user.sh (если запущен из файла)"
[[ -f "$0" && "$0" == "$HOME/install_user.sh" ]] && rm -f "$0"