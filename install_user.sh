#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

REAL_USER=$(logname)

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

log "== Установка сервисов от пользователя $REAL_USER =="

BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")
LABEL=$(jq -r '.telegram_server_label' "$CONFIG_FILE")
SECURITY_CHECK_CRON=$(jq -r '.cron_tasks.security_check' "$CONFIG_FILE")
CLEAR_LOG_CRON=$(jq -r '.cron_tasks.clear_logs' "$CONFIG_FILE")
MONITORING_ENABLED=$(jq -r '.monitoring_enabled' "$CONFIG_FILE")

log "Очистка старых конфигураций"
rm -f /etc/polkit-1/rules.d/49-nopasswd.rules 2>/dev/null || true
rm -f /etc/sudoers.d/90-$REAL_USER 2>/dev/null || true

log "Настройка polkit и sudo"
mkdir -p /etc/polkit-1/rules.d
cat <<EOF > /etc/polkit-1/rules.d/49-nopasswd.rules
polkit.addRule(function(action, subject) {
  if (subject.isInGroup("sudo")) {
    return polkit.Result.YES;
  }
});
EOF
systemctl daemon-reexec

echo "$REAL_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$REAL_USER
chmod 440 /etc/sudoers.d/90-$REAL_USER
log "Политика sudo и polkit настроена"
log "Настройка SSH для пользователя $REAL_USER"

PORT=$(jq -r '.port' "$CONFIG_FILE")
SSH_DISABLE_ROOT=$(jq -r '.ssh_disable_root' "$CONFIG_FILE")
SSH_PASSWORD_AUTH=$(jq -r '.ssh_password_auth' "$CONFIG_FILE")
MAX_AUTH_TRIES=$(jq -r '.max_auth_tries' "$CONFIG_FILE")
MAX_SESSIONS=$(jq -r '.max_sessions' "$CONFIG_FILE")
LOGIN_GRACE_TIME=$(jq -r '.login_grace_time' "$CONFIG_FILE")

mkdir -p /home/$REAL_USER/.ssh
chmod 700 /home/$REAL_USER/.ssh
cp "$KEY_FILE" /home/$REAL_USER/.ssh/authorized_keys
chmod 600 /home/$REAL_USER/.ssh/authorized_keys
chown -R $REAL_USER:$REAL_USER /home/$REAL_USER/.ssh
log "SSH-ключ установлен"

log "Обновление /etc/ssh/sshd_config"

# Проверка наличия openssh-server и установка при необходимости
if ! systemctl list-unit-files | grep -q ssh.service && ! systemctl list-unit-files | grep -q sshd.service; then
  log "openssh-server не найден, устанавливаю..."
  apt install -y openssh-server
fi
sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin $( [[ "$SSH_DISABLE_ROOT" == "true" ]] && echo "no" || echo "yes" )/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication $( [[ "$SSH_PASSWORD_AUTH" == "true" ]] && echo "yes" || echo "no" )/" /etc/ssh/sshd_config
sed -i "s/^#\?MaxAuthTries .*/MaxAuthTries $MAX_AUTH_TRIES/" /etc/ssh/sshd_config
sed -i "s/^#\?MaxSessions .*/MaxSessions $MAX_SESSIONS/" /etc/ssh/sshd_config
sed -i "s/^#\?LoginGraceTime .*/LoginGraceTime $LOGIN_GRACE_TIME/" /etc/ssh/sshd_config

systemctl restart sshd
log "sshd перезапущен на порту $PORT"

log "Установка и активация сервисов"
for SERVICE in ufw fail2ban psad rkhunter nmap; do
  if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
    apt install -y "$SERVICE"
    if systemctl list-unit-files | grep -q "^$SERVICE.service"; then
      systemctl enable --now "$SERVICE"
      log "$SERVICE активирован"
    else
      log "$SERVICE не использует systemd — пропущено"
    fi
  else
    log "$SERVICE отключён в config.json"
  fi
done

log "Настройка rkhunter"
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
log "rkhunter настроен"

if [[ "$MONITORING_ENABLED" == "true" ]]; then
  log "Установка Netdata"
  curl -SsL https://my-netdata.io/kickstart.sh -o /tmp/netdata_installer.sh
  bash /tmp/netdata_installer.sh --dont-wait || log "Не удалось установить Netdata (проверь соединение или URL)"
fi




log "Настройка Telegram-уведомлений"
cat <<'EOF' > /etc/profile.d/notify_login.sh
#!/bin/bash
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
LABEL="$LABEL"
USER_NAME=\$(whoami)
IP_ADDR=\$(who | awk '{print \$5}' | sed 's/[()]//g')
HOSTNAME=\$(hostname)
LOGIN_TIME=\$(date "+%Y-%m-%d %H:%M:%S")
MESSAGE="SSH вход: *\$REAL_USER_NAME*%0AХост: \$HOSTNAME%0AВремя: \$LOGIN_TIME%0AIP: \\`\$IP_ADDR\\`%0AСервер: \\`\$LABEL\\`"
curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$MESSAGE" > /dev/null
EOF
chmod +x /etc/profile.d/notify_login.sh

log "Настройка cron-задач"
cat <<'EOF' > /usr/local/bin/security_monitor.sh
#!/bin/bash
echo "[monitor] $(date)" >> /var/log/security_monitor.log
EOF
chmod +x /usr/local/bin/security_monitor.sh

cat <<'EOF' > /usr/local/bin/clear_security_log.sh
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

CHECKLIST="/tmp/install_checklist.txt"
{
echo "Чеклист установки:"
echo "Пользователь: $REAL_USER"
echo "Активные сервисы:"
for SERVICE in ufw fail2ban psad rkhunter; do
  systemctl is-active --quiet "$SERVICE" && echo "  [+] $SERVICE" || echo "  [ ] $SERVICE"
done
echo "Telegram уведомления: включены"
echo "rkhunter: доступна проверка /usr/bin/rkhunter --check"
echo "Cron-задачи: настроены"
} > "$CHECKLIST"

CHECK_MSG=$(cat "$CHECKLIST" | sed 's/`/\`/g')
cat "$CHECKLIST"
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" -d parse_mode="Markdown" -d text="\\`\`\`$CHECK_MSG\\`\`\`" > /dev/null
rm "$CHECKLIST"

log "Установка завершена"

log "Создание Telegram бота-слушателя"

cat <<EOF > /usr/local/bin/telegram_command_listener.sh
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
  curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \\
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

chmod +x /usr/local/bin/telegram_command_listener.sh

cat <<EOF > /etc/systemd/system/telegram_command_listener.service
[Unit]
Description=Telegram Command Listener
After=network.target

[Service]
ExecStart=/usr/local/bin/telegram_command_listener.sh
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now telegram_command_listener.service

log "Telegram бот-слушатель активирован"
