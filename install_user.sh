#!/bin/bash
set -e

LOG="/home/$USER/install_user.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log " [USER] Установка компонентов от имени $USER"

REMOTE_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
CONFIG_FILE="/usr/local/bin/config.json"
SECURE_SCRIPT="/usr/local/bin/secure_install.sh"
TELEGRAM_SCRIPT="/usr/local/bin/telegram_command_listener.sh"

# === Перезапуск SSH не требуется, т.к. это делает root ===

# === Безопасность ===
log "Загружаем secure_install.sh..."
curl -fsSL "$REMOTE_URL/secure_install.sh" -o "/tmp/secure_install.sh"
sudo mv /tmp/secure_install.sh "$SECURE_SCRIPT"
sudo chmod +x "$SECURE_SCRIPT"
chmod +x "$SECURE_SCRIPT"
sudo bash "$SECURE_SCRIPT"

# === Telegram-бот ===
if pgrep -f telegram_command_listener.sh > /dev/null; then
  log "Telegram-бот уже запущен"
else
  log "Устанавливаем Telegram-бота..."
  curl -fsSL "$REMOTE_URL/telegram_command_listener.sh" -o "$TELEGRAM_SCRIPT"
  chmod +x "$TELEGRAM_SCRIPT"
  echo "0" > /tmp/telegram_last_update_id
  nohup "$TELEGRAM_SCRIPT" > /var/log/telegram_bot.log 2>&1 &
fi

# === Docker (проверка и установка) ===
if ! command -v docker &>/dev/null; then
  log "Устанавливаем Docker..."
  sudo apt install -y docker.io
  sudo systemctl enable --now docker
else
  log "Docker уже установлен, проверка обновлений..."
  sudo apt install -y --only-upgrade docker.io
fi

log "Добавляем пользователя $USER в группу docker..."
sudo usermod -aG docker "$USER"

# === Netdata ===
if ! docker ps | grep -q netdata; then
  log "Запускаем Netdata в контейнере..."
  docker run -d --name netdata \
    -p 19999:19999 \
    -v /etc/netdata:/etc/netdata:ro \
    -v /var/lib/netdata:/var/lib/netdata \
    -v /proc:/host/proc:ro \
    -v /sys:/host/sys:ro \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    --cap-add SYS_PTRACE \
    --security-opt apparmor=unconfined \
    netdata/netdata
else
  log "Netdata уже работает"
fi

# === Очистка лога установки ===
log "Настраиваем автоочистку /var/log/server_install.log..."
cat > /usr/local/bin/clear_install_log.sh <<EOF
#!/bin/bash
echo "$(date '+%F %T') | Очистка install лога" > /var/log/server_install.log
EOF
chmod +x /usr/local/bin/clear_install_log.sh
(crontab -l 2>/dev/null; echo "0 4 * * 6 /usr/local/bin/clear_install_log.sh") | sort -u | crontab -

# === Автообновление системы ===
AUTO_UPDATE_CRON=$(jq -r '.auto_update_cron' "$CONFIG_FILE")
cat > /usr/local/bin/auto_update.sh <<EOF
#!/bin/bash
echo "$(date '+%F %T') | Обновление системы" >> /var/log/auto_update.log
sudo apt update && sudo apt full-upgrade -y >> /var/log/auto_update.log 2>&1
EOF
chmod +x /usr/local/bin/auto_update.sh
(crontab -l 2>/dev/null; echo "$AUTO_UPDATE_CRON /usr/local/bin/auto_update.sh") | sort -u | crontab -

# === Резюме ===
PORT=$(jq -r '.port' "$CONFIG_FILE")
log "===  Установка завершена ==="
log " Root доступ: отключён"
log " Telegram-бот: активен"
log " Netdata: http://YOUR_SERVER_IP:19999"
log " Подключение: ssh -p $PORT $USER@YOUR_SERVER_IP"

# === Финальная проверка установки ===
log " Загружаем и запускаем verify_install.sh..."
curl -fsSL https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/verify_install.sh -o /usr/local/bin/verify_install.sh
chmod +x /usr/local/bin/verify_install.sh
/usr/local/bin/verify_install.sh || true
