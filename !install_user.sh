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

log "🤖 Установка продвинутого Telegram-бота"
sudo tee /usr/local/bin/telegram_command_listener.sh > /dev/null <<EOF
#!/bin/bash

TOKEN="8019987480:AAEJdUAAiGqlTFjOahWNh3RY5hiEwo3-E54"
CHAT_ID="543102005"
OFFSET_FILE="$HOME/.cache/telegram_bot_offset"
LAST_COMMAND_FILE="$HOME/.cache/telegram_last_command"
REBOOT_FLAG_FILE="$HOME/.cache/telegram_confirm_reboot"
LOG_FILE="/tmp/bot_debug.log"

mkdir -p "$(dirname "$OFFSET_FILE")"
exec >>"$LOG_FILE" 2>&1
set -x

OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

send_message() {
  local text="$1"
  curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="$text" > /dev/null
}

get_updates() {
  curl -s "https://api.telegram.org/bot$TOKEN/getUpdates?offset=$OFFSET"
}

while true; do
  RESPONSE=$(get_updates)
  UPDATES=$(echo "$RESPONSE" | jq -c '.result')
  LENGTH=$(echo "$UPDATES" | jq 'length')
  [[ "$LENGTH" -eq 0 ]] && sleep 2 && continue

  for ((i = 0; i < LENGTH; i++)); do
    UPDATE=$(echo "$UPDATES" | jq -c ".[$i]")
    UPDATE_ID=$(echo "$UPDATE" | jq '.update_id')
    MESSAGE=$(echo "$UPDATE" | jq -r '.message.text')
    OFFSET=$((UPDATE_ID + 1))
    echo "$OFFSET" > "$OFFSET_FILE"

    NOW=$(date +%s)
    LAST_CMD=$(cat "$LAST_COMMAND_FILE" 2>/dev/null || echo "0")
    DIFF=$((NOW - LAST_CMD))
    [[ "$DIFF" -lt 3 ]] && continue
    echo "$NOW" > "$LAST_COMMAND_FILE"

    case "$MESSAGE" in
      /help | help)
        send_message "*Команды:*
/uptime — аптайм
/disk — диск
/mem — память
/top — топ процессов
/who — кто в системе + гео
/ip — IP + геолокация
/security — проверка rkhunter + psad
/reboot — перезагрузка сервера
/confirm_reboot — подтвердить перезагрузку
/restart_bot — перезапуск бота
/botlog — последние логи бота"
        ;;
      /uptime)
        send_message "*Аптайм:* $(uptime -p)"
        ;;
      /disk)
        send_message "\`\`\`
$(df -h /)
\`\`\`"
        ;;
      /mem)
        send_message "\`\`\`
$(free -h)
\`\`\`"
        ;;
      /top)
        send_message "\`\`\`
$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 10)
\`\`\`"
        ;;
      /who)
        WHO_WITH_GEO=""
        while read -r user tty date time ip; do
          IP=$(echo "$ip" | tr -d '()')
          GEO=$(curl -s ipinfo.io/$IP | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
          WHO_WITH_GEO+="👤 $user — $IP
🌍 $GEO

"
        done <<< "$(who | awk '{print $1, $2, $3, $4, $5}')"
        send_message "*Сессии пользователей:*

$WHO_WITH_GEO"
        ;;
      /ip)
        IP_INT=$(hostname -I | awk '{print $1}')
        IP_EXT=$(curl -s ifconfig.me)
        GEO=$(curl -s ipinfo.io/$IP_EXT | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
        send_message "*Внутренний IP:* \`$IP_INT\`
*Внешний IP:* \`$IP_EXT\`
🌍 *Геолокация:* $GEO"
        ;;
      /security)
        send_message "⏳ Выполняется проверка безопасности. Это может занять до 30 секунд..."
        RKHUNTER_RESULT=$(sudo rkhunter --check --sk --nocolors | tail -n 100 || echo "Ошибка запуска rkhunter")
        PSAD_RESULT=$(grep "Danger level" /var/log/psad/alert | tail -n 5 || echo "psad лог пуст")
        send_message "*RKHunter (последние строки):*
\`\`\`
$RKHUNTER_RESULT
\`\`\`

*PSAD:*
\`\`\`
$PSAD_RESULT
\`\`\`"
        ;;
      /reboot)
        echo "1" > "$REBOOT_FLAG_FILE"
        send_message "⚠️ Подтвердите перезагрузку сервера командой */confirm_reboot*"
        ;;
      /confirm_reboot)
        if [[ -f "$REBOOT_FLAG_FILE" ]]; then
          send_message "♻️ Перезагрузка сервера..."
          rm -f "$REBOOT_FLAG_FILE"
          sleep 2
          sudo reboot
        else
          send_message "Нет активного запроса на перезагрузку."
        fi
        ;;
      /restart_bot)
        send_message "🔄 Перезапуск Telegram-бота..."
        sleep 1
        sudo systemctl restart telegram_command_listener.service
        exit 0
        ;;
      /botlog)
        LOG=$(tail -n 30 "$LOG_FILE" 2>/dev/null || echo "Лог отсутствует.")
        send_message "*Лог бота:*
\`\`\`
$LOG
\`\`\`"
        ;;
      *)
        send_message "Неизвестная команда. Напиши /help"
        ;;
    esac
  done
  sleep 2
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
log "🔔 Установка уведомлений о входе по SSH"
sudo tee /usr/local/bin/telegram_ssh_notify.sh > /dev/null <<EOF
#!/bin/bash

[[ "$PAM_TYPE" != "open_session" ]] && exit 0
[[ -z "$PAM_USER" || "$PAM_USER" == "sshd" ]] && exit 0

TOKEN="8019987480:AAEJdUAAiGqlTFjOahWNh3RY5hiEwo3-E54"
CHAT_ID="543102005"

USER="$PAM_USER"
IP=$(echo $SSH_CONNECTION | awk '{print $1}')
CACHE_FILE="/tmp/ssh_notify_${USER}_${IP}"

# Если уже отправляли уведомление за последние 10 секунд — пропускаем
if [[ -f "$CACHE_FILE" ]]; then
  LAST_TIME=$(cat "$CACHE_FILE")
  NOW=$(date +%s)
  DIFF=$((NOW - LAST_TIME))
  if [[ "$DIFF" -lt 10 ]]; then
    exit 0
  fi
fi

date +%s > "$CACHE_FILE"

GEO=$(curl -s ipinfo.io/$IP | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
TEXT="🔐 SSH вход: *$USER*
📡 IP: \`$IP\`
🌍 Местоположение: $GEO
🕒 Время: $(date +'%Y-%m-%d %H:%M:%S')"

curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d parse_mode="Markdown" \
  -d text="$TEXT"
EOF
sudo chmod +x /usr/local/bin/telegram_ssh_notify.sh

if ! grep -q telegram_ssh_notify.sh /etc/pam.d/sshd; then
  echo 'session optional pam_exec.so /usr/local/bin/telegram_ssh_notify.sh' | sudo tee -a /etc/pam.d/sshd > /dev/null
fi

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