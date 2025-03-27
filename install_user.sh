#!/bin/bash
set -e
CONFIG_FILE="/usr/local/bin/config.json"
PUBKEY=$(jq -r '.public_key_content' "$CONFIG_FILE")
PORT=$(jq -r '.port' "$CONFIG_FILE")
SSH_DISABLE_ROOT=$(jq -r '.ssh_disable_root' "$CONFIG_FILE")
SSH_PASSWORD_AUTH=$(jq -r '.ssh_password_auth' "$CONFIG_FILE")
USERNAME=$(whoami)

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1"
}

log "📁 Создание ~/.ssh и настройка ключей"
mkdir -p ~/.ssh
chmod 700 ~/.ssh
cd ~/.ssh
touch authorized_keys
chmod 600 authorized_keys

log "🔑 Установка публичного ключа"
echo "$PUBKEY" > authorized_keys

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

log "🔓 Отключение запроса пароля для sudo (если нужно)"
SUDO_NOPASSWD=$(jq -r '.sudo_nopasswd' "$CONFIG_FILE")
if [[ "$SUDO_NOPASSWD" == "true" ]]; then
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/90-$USERNAME" > /dev/null
  sudo chmod 440 "/etc/sudoers.d/90-$USERNAME"
fi

log "✅ Настройка пользователя завершена. Готово к следующему этапу (защита, бот, чеклист)"


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
ExecStart=/usr/bin/rkhunter --cronjob
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reexec
sudo systemctl enable --now rkhunter.service
echo "0 1 * * * root /usr/bin/rkhunter --check --cronjob" | sudo tee /etc/cron.d/rkhunter-daily > /dev/null

if [[ "$(jq -r '.monitoring_enabled' "$CONFIG_FILE")" == "true" ]]; then
  log "📊 Установка Netdata"
  curl -Ss https://my-netdata.io/kickstart.sh -o /tmp/netdata_installer.sh
  sudo bash /tmp/netdata_installer.sh --dont-wait || log "⚠️ Не удалось установить Netdata"
fi

log "🤖 Создание Telegram бота-слушателя"

BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")
LABEL=$(jq -r '.telegram_server_label' "$CONFIG_FILE")

sudo tee /usr/local/bin/telegram_command_listener.sh > /dev/null <<EOF
#!/bin/bash
TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
LABEL="$LABEL"
OFFSET=0

get_updates() {
  curl -s "https://api.telegram.org/bot\$TOKEN/getUpdates?offset=\$OFFSET"
}

send_message() {
  local text="\$1"
  curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \
    -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$text" > /dev/null
}

while true; do
  RESPONSE=\$(get_updates)
  echo "\$RESPONSE" | jq -c '.result[]' | while read -r update; do
    UPDATE_ID=\$(echo "\$update" | jq '.update_id')
    OFFSET=\$((UPDATE_ID + 1))
    MESSAGE=\$(echo "\$update" | jq -r '.message.text')

    case "\$MESSAGE" in
      /help)
        send_message "*Команды:*
/help — помощь
/security — логи psad, rkhunter
/uptime — аптайм сервера"
        ;;
      /security)
        RKHUNTER=\$(rkhunter --check --sk --nocolors --rwo 2>/dev/null || echo "rkhunter не установлен")
        PSAD=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || echo "psad лог пуст")
        send_message "*RKHunter:*
\`\`\`\$RKHUNTER\`\`\`

*PSAD:*
\`\`\`\$PSAD\`\`\`"
        ;;
      /uptime)
        send_message "*Аптайм:* \$(uptime -p)"
        ;;
      *)
        send_message "Неизвестная команда. Напиши /help"
        ;;
    esac
  done
  sleep 3
done
EOF

sudo chmod +x /usr/local/bin/telegram_command_listener.sh

sudo tee /etc/systemd/system/telegram_command_listener.service > /dev/null <<EOF
[Unit]
Description=Telegram Command Listener
After=network.target

[Service]
ExecStart=/usr/local/bin/telegram_command_listener.sh
Restart=always
User=$USERNAME

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable --now telegram_command_listener.service

log "📬 Отправка финального Telegram-чеклиста"

CHECKLIST="/tmp/install_checklist.txt"
{
echo "Чеклист установки:"
echo "Пользователь: $USERNAME"
echo "SSH порт: $PORT"
echo "Службы:"
for SERVICE in ufw fail2ban psad rkhunter; do
  sudo systemctl is-active --quiet "$SERVICE" && echo "  [+] $SERVICE" || echo "  [ ] $SERVICE"
done
echo "Telegram-бот: включён"
echo "Netdata: http://$(hostname -I | awk '{print $1}'):19999"
} > "$CHECKLIST"

CHECK_MSG=$(cat "$CHECKLIST" | sed 's/`/\`/g')
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="\`\`\`$CHECK_MSG\`\`\`" > /dev/null
rm "$CHECKLIST"

log "✅ Установка завершена"
