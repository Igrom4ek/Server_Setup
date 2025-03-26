#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

CONFIG_FILE="/usr/local/bin/config.json"
REMOTE_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
LOG="/home/$USER/install_user.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log "🚀 Установка сервисов от пользователя $USER"

log "⬇️ Скачиваем Telegram listener"
curl -fsSL "$REMOTE_URL/telegram_command_listener.sh" -o /usr/local/bin/telegram_command_listener.sh
chmod +x /usr/local/bin/telegram_command_listener.sh

log "⬇️ Запускаем secure_install.sh"
curl -fsSL "$REMOTE_URL/secure_install.sh" -o /usr/local/bin/secure_install.sh
chmod +x /usr/local/bin/secure_install.sh
sudo bash /usr/local/bin/secure_install.sh

log "🐳 Устанавливаем Docker (если не установлен)"
if ! command -v docker &>/dev/null; then
  sudo apt install -y docker.io
  sudo systemctl enable --now docker
fi
sudo usermod -aG docker "$USER"

log "📊 Устанавливаем Netdata (если не работает)"
if ! docker ps | grep -q netdata; then
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
fi

log "⏱ Настраиваем автообновление"
AUTO_UPDATE_CRON=$(jq -r '.cron_tasks.auto_update' "$CONFIG_FILE")
cat > /usr/local/bin/auto_update.sh <<EOF
#!/bin/bash
echo "\$(date '+%F %T') | Обновление системы" >> /var/log/auto_update.log
sudo apt update && sudo apt -o Dpkg::Options::="--force-confold" full-upgrade -y >> /var/log/auto_update.log 2>&1
EOF
chmod +x /usr/local/bin/auto_update.sh
(crontab -l 2>/dev/null; echo "$AUTO_UPDATE_CRON /usr/local/bin/auto_update.sh") | sort -u | crontab -

log "✅ Проверяем систему"
curl -fsSL "$REMOTE_URL/verify_install.sh" -o /tmp/verify.sh
bash /tmp/verify.sh || true

log "🧹 Удаляем install_user.sh"
rm -- "$0"
