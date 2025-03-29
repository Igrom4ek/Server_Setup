#!/bin/bash
set -e

CONFIG_FILE="/usr/local/bin/config.json"
PUBKEY=$(jq -r '.public_key_content' "$CONFIG_FILE")
PORT=$(jq -r '.port' "$CONFIG_FILE")
SSH_DISABLE_ROOT=$(jq -r '.ssh_disable_root' "$CONFIG_FILE")
SSH_PASSWORD_AUTH=$(jq -r '.ssh_password_auth' "$CONFIG_FILE")
SUDO_NOPASSWD=$(jq -r '.sudo_nopasswd' "$CONFIG_FILE")
MONITORING_ENABLED=$(jq -r '.monitoring_enabled' "$CONFIG_FILE")
BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")

USERNAME=$(whoami)
USER_HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)
CACHE_DIR="$USER_HOME_DIR/.local/share/telegram_bot"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1"
}

# Проверка предыдущей установки
if [[ -f "/usr/local/bin/telegram_command_listener.sh" ]]; then
  read -p "Обнаружена предыдущая установка. Обновить? (y/n) " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    log "🔄 Удаление предыдущей версии..."
    sudo systemctl stop telegram_command_listener.service || true
    sudo rm -f /usr/local/bin/telegram_*.sh
    sudo rm -f /etc/systemd/system/telegram_command_listener.service
  else
    exit 1
  fi
fi

# 1. Настройка пользователя и SSH
log "📁 Создание ~/.ssh и настройка ключей"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

log "🔑 Установка публичного SSH-ключа"
echo "$PUBKEY" > ~/.ssh/authorized_keys

log "🛠 Настройка /etc/ssh/sshd_config"
sudo sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config
if [[ "$SSH_DISABLE_ROOT" == "true" ]]; then
  sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
fi
if [[ "$SSH_PASSWORD_AUTH" == "false" ]]; then
  sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
fi

log "🔄 Перезапуск SSH"
sudo service ssh restart

log "🔓 Настройка sudo без пароля (если предусмотрено)"
if [[ "$SUDO_NOPASSWD" == "true" ]]; then
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/90-$USERNAME" > /dev/null
  sudo chmod 440 "/etc/sudoers.d/90-$USERNAME"
fi

# 2. Системная защита
log "🛡 Установка и настройка системной защиты"
for SERVICE in ufw fail2ban psad rkhunter nmap; do
  if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
    sudo apt install -y "$SERVICE"
    if systemctl list-unit-files | grep -q "^$SERVICE.service"; then
      sudo systemctl enable --now "$SERVICE"
      log "$SERVICE активирован"
    else
      log "$SERVICE не использует systemd — пропущено"
    fi
  else
    log "$SERVICE отключён в config.json"
  fi
done

log "📦 Настройка rkhunter"
sudo rkhunter --propupd || true
sudo tee /etc/systemd/system/rkhunter.service > /dev/null <<EOF
[Unit]
Description=Rootkit Hunter Service
After=network.target

[Service]
ExecStart=/usr/bin/rkhunter --cronjob --rwo
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now rkhunter.service
echo "0 1 * * * root /usr/bin/rkhunter --check --cronjob --rwo" | sudo tee /etc/cron.d/rkhunter-daily > /dev/null

# 3. Docker и Portainer
log "🐳 Проверка Docker и Portainer"
if ! command -v docker &> /dev/null; then
  log "Docker не найден, выполняется установка Docker..."
  sudo apt update -y
  sudo apt install -y docker.io || log "⚠️ Не удалось установить Docker"
  sudo systemctl enable --now docker && log "Docker запущен"
fi

if command -v docker &> /dev/null && ! sudo docker container inspect portainer &> /dev/null; then
  log "Portainer не установлен, запускается установка Portainer..."
  sudo docker volume create portainer_data > /dev/null || true
  sudo docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always \
    -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data \
    portainer/portainer-ce:lts || log "⚠️ Не удалось запустить Portainer"
fi

# 4. Netdata
if [[ "$MONITORING_ENABLED" == "true" ]]; then
  log "📊 Установка Netdata"
  if ! command -v netdata &> /dev/null && ! sudo docker container inspect netdata &> /dev/null; then
    sudo docker run -d --name=netdata \
      --hostname="$(hostname)" \
      --pid=host \
      --network=host \
      -v netdataconfig:/etc/netdata \
      -v netdatalib:/var/lib/netdata \
      -v netdatacache:/var/cache/netdata \
      -v /etc/passwd:/host/etc/passwd:ro \
      -v /etc/group:/host/etc/group:ro \
      -v /proc:/host/proc:ro \
      -v /sys:/host/sys:ro \
      -v /var/run/docker.sock:/var/run/docker.sock:ro \
      --restart unless-stopped \
      --cap-add SYS_PTRACE --cap-add SYS_ADMIN \
      --security-opt apparmor=unconfined \
      netdata/netdata || log "⚠️ Не удалось запустить Netdata"
  fi
fi

# 5. Telegram бот с inline-кнопками
log "🤖 Установка улучшенного Telegram-бота"
mkdir -p "$CACHE_DIR"

sudo tee /usr/local/bin/telegram_command_listener.sh > /dev/null <<'EOF'
#!/bin/bash
set -x

TOKEN="BOT_TOKEN_PLACEHOLDER"
CHAT_ID="CHAT_ID_PLACEHOLDER"
CACHE_DIR="CACHE_DIR_PLACEHOLDER"
OFFSET_FILE="$CACHE_DIR/offset"
LAST_COMMAND_FILE="$CACHE_DIR/last_command"
REBOOT_FLAG_FILE="$CACHE_DIR/confirm_reboot"
LOG_FILE="$CACHE_DIR/bot.log"

mkdir -p "$CACHE_DIR"
exec >>"$LOG_FILE" 2>&1

send_message() {
  local text="$1"
  local keyboard="$2"
  local params=("--data-urlencode" "chat_id=${CHAT_ID}" 
                "--data-urlencode" "parse_mode=Markdown"
                "--data-urlencode" "text=${text}")
                
  if [[ -n "$keyboard" ]]; then
    params+=("--data-urlencode" "reply_markup=${keyboard}")
  fi
  
  curl -s -X POST "https://api.telegram.org/bot${TOKEN}/sendMessage" "${params[@]}" > /dev/null
}

show_main_menu() {
  send_message "🔷 *Главное меню* 🔷" '{
    "inline_keyboard": [
      [{"text":"📋 Чек-лист","callback_data":"/checklist"}],
      [{"text":"🛡 Безопасность","callback_data":"/security"}, {"text":"🔄 Перезагрузка","callback_data":"/reboot"}],
      [{"text":"📊 Мониторинг","callback_data":"/monitoring"}, {"text":"❓ Помощь","callback_data":"/help"}]
    ]
  }'
}

process_update() {
  local UPDATE="$1"
  local MESSAGE=$(echo "$UPDATE" | jq -r '.message.text // empty')
  local CALLBACK_QUERY=$(echo "$UPDATE" | jq -r '.callback_query // empty')
  
  if [[ -n "$CALLBACK_QUERY" ]]; then
    local DATA=$(echo "$CALLBACK_QUERY" | jq -r '.data')
    case "$DATA" in
      /help) send_help ;;
      /security) check_security ;;
      /reboot) request_reboot ;;
      /checklist) send_checklist ;;
      /monitoring) send_monitoring ;;
      *) send_message "⚠️ Неизвестная команда" ;;
    esac
  elif [[ -n "$MESSAGE" ]]; then
    case "$MESSAGE" in
      /start) show_main_menu ;;
      *) send_message "Используйте меню кнопок ниже 👇" ;;
    esac
  fi
}

check_security() {
  send_message "⏳ Проверка безопасности..."
  
  RKHUNTER_RESULT=$(timeout 30s sudo rkhunter --check --sk --nocolors --rwo 2>&1 | tail -n 15)
  [[ $? -eq 124 ]] && RKHUNTER_RESULT="Проверка заняла слишком много времени"
  
  PSAD_STATUS=$(sudo psad -S | head -n 15)
  PSAD_ALERTS=$(grep "$(date -d '24 hours ago' '+%b %d')" /var/log/psad/alert | grep "Danger level" | tail -n 5 || echo "Нет событий за 24 часа")
  
  SECURITY_REPORT="*🛡 Отчёт безопасности*\n\n"
  SECURITY_REPORT+="*RKHunter:*\n\`\`\`\n$RKHUNTER_RESULT\n\`\`\`\n\n"
  SECURITY_REPORT+="*PSAD Status:*\n\`\`\`\n$PSAD_STATUS\n\`\`\`\n\n"
  SECURITY_REPORT+="*Топ IP (24ч):*\n\`\`\`\n$PSAD_ALERTS\n\`\`\`"
  
  send_message "$SECURITY_REPORT"
}

send_checklist() {
  CHECKLIST="*📋 Текущий статус системы*\n\n"
  CHECKLIST+="• SSH порт: $(grep -oP '^Port \K\d+' /etc/ssh/sshd_config)\n"
  CHECKLIST+="• UFW: $(sudo ufw status | grep -oP 'Status: \K\w+')\n"
  CHECKLIST+="• Fail2Ban: $(systemctl is-active fail2ban)\n"
  CHECKLIST+="• PSAD: $(sudo psad --status | head -1)\n"
  CHECKLIST+="• Docker: $(command -v docker >/dev/null && echo "Установлен" || echo "Отсутствует")\n"
  CHECKLIST+="• Аптайм: $(uptime -p)"
  
  send_message "$CHECKLIST"
}

while true; do
  OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
  RESPONSE=$(curl -s "https://api.telegram.org/bot${TOKEN}/getUpdates?offset=${OFFSET}&timeout=10")
  UPDATES=$(echo "$RESPONSE" | jq -c '.result[]')
  
  while IFS= read -r UPDATE; do
    process_update "$UPDATE"
    echo "$(( $(echo "$UPDATE" | jq '.update_id') + 1 ))" > "$OFFSET_FILE"
  done <<< "$UPDATES"
  
  sleep 2
done
EOF

# Заменяем плейсхолдеры в скрипте бота
sudo sed -i \
  -e "s|BOT_TOKEN_PLACEHOLDER|$BOT_TOKEN|g" \
  -e "s|CHAT_ID_PLACEHOLDER|$CHAT_ID|g" \
  -e "s|CACHE_DIR_PLACEHOLDER|$CACHE_DIR|g" \
  /usr/local/bin/telegram_command_listener.sh

sudo chmod +x /usr/local/bin/telegram_command_listener.sh

# Systemd сервис для бота
sudo tee /etc/systemd/system/telegram_command_listener.service > /dev/null <<EOF
[Unit]
Description=Telegram Command Listener Bot Service
After=network.target

[Service]
ExecStart=/usr/local/bin/telegram_command_listener.sh
Restart=always
User=$USERNAME
Environment="HOME=$USER_HOME_DIR"

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now telegram_command_listener.service

# Уведомления о SSH входах
log "🔔 Настройка SSH уведомлений"
sudo tee /usr/local/bin/telegram_ssh_notify.sh > /dev/null <<EOF
#!/bin/bash
[[ "\$PAM_TYPE" != "open_session" ]] && exit 0
[[ -z "\$PAM_USER" || "\$PAM_USER" == "root" ]] && exit 0

TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
CACHE_FILE="$CACHE_DIR/ssh_\${PAM_USER}_\${PAM_RHOST}"

# Проверка дублирования уведомлений
if [[ -f "\$CACHE_FILE" ]]; then
  LAST_TIME=\$(cat "\$CACHE_FILE")
  NOW=\$(date +%s)
  [[ \$((NOW - LAST_TIME)) -lt 10 ]] && exit 0
fi

date +%s > "\$CACHE_FILE"

GEO=\$(curl -s ipinfo.io/\$PAM_RHOST | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
TEXT="🔐 *SSH вход*: \`\$PAM_USER\`
📍 *IP*: \`\$PAM_RHOST\`
🌍 *Гео*: \$GEO
🕒 *Время*: \$(date '+%Y-%m-%d %H:%M:%S')"

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \
  -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$TEXT" > /dev/null
EOF

sudo chmod +x /usr/local/bin/telegram_ssh_notify.sh
echo "session optional pam_exec.so /usr/local/bin/telegram_ssh_notify.sh" | sudo tee -a /etc/pam.d/sshd > /dev/null

# Настройка логирования
log "📝 Настройка логирования"
sudo iptables -A INPUT -j LOG
sudo iptables -A FORWARD -j LOG

if ! grep -q "psad" /etc/rsyslog.conf; then
  echo ':msg, contains, "psad" /var/log/psad/alert' | sudo tee -a /etc/rsyslog.conf > /dev/null
  echo '& stop' | sudo tee -a /etc/rsyslog.conf > /dev/null
  sudo systemctl restart rsyslog
fi

# Финальный чек-лист
log "✅ Установка завершена"
CHECKLIST="$CACHE_DIR/install_checklist.txt"
echo "🛠 *Чек-лист установки* 🛠" > "$CHECKLIST"
echo "• Пользователь: $USERNAME" >> "$CHECKLIST"
echo "• SSH порт: $PORT" >> "$CHECKLIST"
echo "• Docker: $(command -v docker >/dev/null && echo "Установлен" || echo "Нет")" >> "$CHECKLIST"
echo "• Portainer: $(docker ps -f name=portainer --format '{{.Status}}' || echo 'Нет')" >> "$CHECKLIST"
echo "• Netdata: $(if [[ "$MONITORING_ENABLED" == "true" ]]; then echo "Включен"; else echo "Выключен"; fi)" >> "$CHECKLIST"
echo "• Telegram бот: $(systemctl is-active telegram_command_listener.service)" >> "$CHECKLIST"

curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" -d parse_mode="Markdown" \
  --data-urlencode text="$(cat "$CHECKLIST")" > /dev/null

log "🎉 Система готова к работе! Используйте кнопки в Telegram для управления."