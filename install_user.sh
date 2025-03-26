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

# === SSH: настройка authorized_keys ===
log "🔐 Настраиваем .ssh"
mkdir -p "$HOME/.ssh"
sudo chmod 700 "$HOME/.ssh"
touch "$HOME/.ssh/authorized_keys"
sudo chmod 600 "$HOME/.ssh/authorized_keys"
cat "$KEY_FILE" >> "$HOME/.ssh/authorized_keys"

# === Проверка порта ===
PORT=$(jq -r '.port' "$CONFIG_FILE")
if ss -tuln | grep -q ":$PORT"; then
  log "❌ Порт $PORT уже используется. Укажи другой в config.json"
  exit 1
fi

# === Настройка SSH-конфигурации ===
log "⚙️ Настраиваем /etc/ssh/sshd_config"
sudo sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config
sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
sudo sed -i "s|^#\?AuthorizedKeysFile .*|AuthorizedKeysFile .ssh/authorized_keys|" /etc/ssh/sshd_config
sudo systemctl restart ssh

# === Отключение запроса пароля для sudo ===
log "🔧 Настраиваем sudo без пароля"
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-$USER > /dev/null
sudo chmod 440 /etc/sudoers.d/90-$USER






# === Установка модулей безопасности ===
set -e

export DEBIAN_FRONTEND=noninteractive

# === secure_install.sh ===
# Настройка: fail2ban, psad, rkhunter, ufw, Telegram, cron

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

log "🛡 Настройка модулей безопасности..."

# Установка модулей (если включены)
for SERVICE in ufw fail2ban psad rkhunter; do
  if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
    log "Устанавливаем $SERVICE..."
    sudo apt install -y "$SERVICE"
    [[ "$SERVICE" != "rkhunter" ]] && systemctl enable --now "$SERVICE" || true
  else
    log "$SERVICE отключён в config.json"
  fi
done

# === Создание security_monitor.sh ===
cat > /usr/local/bin/security_monitor.sh <<EOF

LOG="/var/log/security_monitor.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
LABEL="$LABEL"

send() {
  curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" \
    -d chat_id="\$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="\$1%0A*Server:* \\`\$LABEL\\`" > /dev/null
}

echo "\$(date '+%F %T') | Запуск проверки безопасности" >> "\$LOG"

if command -v rkhunter &>/dev/null; then
  RKHUNTER_RESULT=\$(rkhunter --configfile /etc/rkhunter.conf --check --sk --nocolors --rwo 2>/dev/null || true)
  [[ -n "\$RKHUNTER_RESULT" ]] && send "⚠️ *RKHunter нашёл подозрения:*%0A\`\`\`\$RKHUNTER_RESULT\`\`\`"
fi

if command -v psad &>/dev/null; then
  PSAD_RESULT=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
  [[ -n "\$PSAD_RESULT" ]] && send "🚨 *PSAD предупреждение:*%0A\`\`\`\$PSAD_RESULT\`\`\`"
fi

echo "\$(date '+%F %T') | Проверка завершена" >> "\$LOG"
EOF

sudo chmod +x /usr/local/bin/security_monitor.sh

# === clear_security_log.sh ===
cat > /usr/local/bin/clear_security_log.sh <<EOF

echo "\$(date '+%F %T') | Очистка лога" > /var/log/security_monitor.log
EOF
sudo chmod +x /usr/local/bin/clear_security_log.sh

# === notify_login.sh (telegram) ===
cat > /etc/profile.d/notify_login.sh <<'EOF'

BOT_TOKEN="'"$BOT_TOKEN"'"
CHAT_ID="'"$CHAT_ID"'"
LABEL="'"$LABEL"'"
USER_NAME=$(whoami)
IP_ADDR=$(who | awk '{print $5}' | sed 's/[()]//g')
HOSTNAME=$(hostname)
LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")
MESSAGE="👤 SSH вход: *$USER_NAME*%0A💻 $HOSTNAME%0A🕒 $LOGIN_TIME%0A🌐 IP: \`$IP_ADDR\`%0A*Server:* \`$LABEL\`"
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d parse_mode="Markdown" \
  -d text="$MESSAGE" > /dev/null
EOF
sudo chmod +x /etc/profile.d/notify_login.sh

# === Установка systemd сервиса telegram_command_listener ===
cat > /etc/systemd/system/telegram_command_listener.service <<EOF
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

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable --now telegram_command_listener.service

# === Установка cron-задач ===
TEMP_CRON=$(mktemp)
crontab -l 2>/dev/null > "$TEMP_CRON" || true
grep -v 'security_monitor\|clear_security_log' "$TEMP_CRON" > "${TEMP_CRON}.new"
echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> "${TEMP_CRON}.new"
echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> "${TEMP_CRON}.new"
crontab "${TEMP_CRON}.new"
rm -f "$TEMP_CRON" "${TEMP_CRON}.new"

log "✅ Безопасность настроена успешно"

log "📦 Устанавливаем Telegram listener"

BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")

cat > /usr/local/bin/telegram_command_listener.sh <<'EOF'
#!/bin/bash

# === telegram_command_listener.sh ===
# Обновлённый скрипт Telegram-бота, отправляющего подробный отчёт rkhunter

BOT_TOKEN="__REPLACE_WITH_YOUR_BOT_TOKEN__"
CHAT_ID="__REPLACE_WITH_YOUR_CHAT_ID__"
LOG_FILE="/var/log/telegram_bot.log"
RKHUNTER_LOG="/var/log/rkhunter.log"
TMP_LOG="/tmp/rkhunter_parsed.log"

send_message() {
    local text="$1"
    curl -s -X POST https://api.telegram.org/bot$BOT_TOKEN/sendMessage \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        --data-urlencode text="$text"
}

parse_rkhunter_log() {
    echo "📋 *Отчёт RKHunter (`date +'%Y-%m-%d %H:%M:%S'`)*" > "$TMP_LOG"

    grep -E 'Warning|Possible rootkits|[Ff]iles checked|Rootkits checked|Suspect files|Rootkit checks|Applications checks|System checks summary|Applications checks|File properties checks' "$RKHUNTER_LOG" >> "$TMP_LOG"

    # Отправим лог ботом
    send_message "\`cat $TMP_LOG\`"
}

main_loop() {
    while true; do
        echo "[2025-03-25 23:29:59] Telegram bot listener запущен" >> "$LOG_FILE"

        # Получаем обновления от Telegram
        UPDATES=$(curl -s https://api.telegram.org/bot$BOT_TOKEN/getUpdates)

        # Обработка команды /security
        if echo "$UPDATES" | grep -q "/security"; then
            send_message "🔍 Запускаю проверку безопасности... Это может занять ~1 минуту."
            echo "[2025-03-25 23:29:59] 📩 Получена команда: /security" >> "$LOG_FILE"

            sudo rkhunter --update > /dev/null
            sudo rkhunter --propupd > /dev/null
            sudo rkhunter --check --sk > /dev/null

            parse_rkhunter_log
        fi

        sleep 10
    done
}

main_loop

EOF

sudo chmod +x /usr/local/bin/telegram_command_listener.sh

log "🛠️ Настраиваем systemd-сервис для Telegram listener"
cat > /etc/systemd/system/telegram_command_listener.service <<EOF
[Unit]
Description=Telegram Command Listener
After=network.target

[Service]
ExecStart=/usr/local/bin/telegram_command_listener.sh
Restart=always
User=igrom

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable --now telegram_command_listener.service



log "🐳 Устанавливаем Docker"
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
echo "$(date '+%F %T') | Обновление системы" >> /var/log/auto_update.log
sudo apt update && sudo apt -o Dpkg::Options::="--force-confold" full-upgrade -y >> /var/log/auto_update.log 2>&1
EOF
sudo chmod +x /usr/local/bin/auto_update.sh
(crontab -l 2>/dev/null; echo "$AUTO_UPDATE_CRON /usr/local/bin/auto_update.sh") | sort -u | crontab -


log "✅ Проверяем систему"
curl -fsSL https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/verify_install.sh -o /tmp/verify.sh
bash /tmp/verify.sh || true


log "🧹 Удаляем install_user.sh"
rm -- "$0"