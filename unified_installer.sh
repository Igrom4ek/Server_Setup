#!/bin/bash
set -e


# === Константы ===
CONFIG_FILE="/usr/local/bin/config.json"
KEY_FILE="/usr/local/bin/id_ed25519.pub"
REMOTE_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
LOG="/var/log/server_install.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log "[ROOT] Старт установки"

# === Обновление и подготовка ===
apt update && apt -o Dpkg::Options::="--force-confold" full-upgrade -y
apt -o Dpkg::Options::="--force-confold" install -y jq curl sudo

# === Загрузка конфигов и ключа ===
curl -fsSL "$REMOTE_URL/config.json" -o "$CONFIG_FILE"
curl -fsSL "$REMOTE_URL/id_ed25519.pub" -o "$KEY_FILE"
chmod 644 "$CONFIG_FILE" "$KEY_FILE"

USERNAME=$(jq -r '.username' "$CONFIG_FILE")
PORT=$(jq -r '.port' "$CONFIG_FILE")

# === Создание пользователя ===
if ! id "$USERNAME" &>/dev/null; then
  log "Создание пользователя $USERNAME"
  adduser --disabled-password --gecos "" "$USERNAME"
  PASSWORD=$(jq -r '.user_password' "$CONFIG_FILE")
if [[ -z "$PASSWORD" || "$PASSWORD" == "null" ]]; then
  log "❌ Пароль для пользователя не задан в config.json"
  exit 1
fi
echo "$USERNAME:$PASSWORD" | chpasswd
else
  log "Пользователь $USERNAME уже существует"
fi

usermod -aG sudo,docker,adm,systemd-journal,syslog "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$USERNAME
chmod 440 /etc/sudoers.d/90-$USERNAME

# === SSH-настройка ===
SSHD="/etc/ssh/sshd_config"
sed -i "s/^#\?Port .*/Port $PORT/" "$SSHD"
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSHD"
sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSHD"
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$SSHD"
systemctl restart ssh

mkdir -p /home/$USERNAME/.ssh
cat "$KEY_FILE" > /home/$USERNAME/.ssh/authorized_keys
chmod 700 /home/$USERNAME/.ssh
chmod 600 /home/$USERNAME/.ssh/authorized_keys
chown -R "$USERNAME:$USERNAME" /home/$USERNAME/.ssh

# === Сохраняем user-часть во временный скрипт и исполняем ===

cat > /home/$USERNAME/install_user.sh <<'EOF'
#!/bin/bash
set -e

LOG="/home/$USER/install_user.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log " [USER] Установка компонентов от имени $USER"

REMOTE_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
CONFIG_FILE="/usr/local/bin/config.json"
SECURE_SCRIPT="/usr/local/bin/# встроенная secure_install
  
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
  
  log " Настройка модулей безопасности..."
  
  # Установка модулей (если включены)
  for SERVICE in ufw fail2ban psad rkhunter; do
    if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
      log "Устанавливаем $SERVICE..."
      apt install -y "$SERVICE"
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
    [[ -n "\$RKHUNTER_RESULT" ]] && send " *RKHunter нашёл подозрения:*%0A\`\`\`\$RKHUNTER_RESULT\`\`\`"
  fi
  
  if command -v psad &>/dev/null; then
    PSAD_RESULT=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
    [[ -n "\$PSAD_RESULT" ]] && send " *PSAD предупреждение:*%0A\`\`\`\$PSAD_RESULT\`\`\`"
  fi
  
  echo "\$(date '+%F %T') | Проверка завершена" >> "\$LOG"
  EOF
  
  chmod +x /usr/local/bin/security_monitor.sh
  
  # === clear_security_log.sh ===
  cat > /usr/local/bin/clear_security_log.sh <<EOF
  echo "\$(date '+%F %T') | Очистка лога" > /var/log/security_monitor.log
  EOF
  chmod +x /usr/local/bin/clear_security_log.sh
  
  # === notify_login.sh (telegram) ===
  cat > /etc/profile.d/notify_login.sh <<'EOF'
  BOT_TOKEN="'"$BOT_TOKEN"'"
  CHAT_ID="'"$CHAT_ID"'"
  LABEL="'"$LABEL"'"
  USER_NAME=$(whoami)
  IP_ADDR=$(who | awk '{print $5}' | sed 's/[()]//g')
  HOSTNAME=$(hostname)
  LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")
  MESSAGE=" SSH вход: *$USER_NAME*%0A $HOSTNAME%0A $LOGIN_TIME%0A IP: \`$IP_ADDR\`%0A*Server:* \`$LABEL\`"
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$MESSAGE" > /dev/null
  EOF
  chmod +x /etc/profile.d/notify_login.sh
  
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
  
  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable --now telegram_command_listener.service
  
  # === Установка cron-задач ===
  TEMP_CRON=$(mktemp)
  crontab -l 2>/dev/null > "$TEMP_CRON" || true
  grep -v 'security_monitor\|clear_security_log' "$TEMP_CRON" > "${TEMP_CRON}.new"
  echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> "${TEMP_CRON}.new"
  echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> "${TEMP_CRON}.new"
  crontab "${TEMP_CRON}.new"
  rm -f "$TEMP_CRON" "${TEMP_CRON}.new"
  
  log " Безопасность настроена успешно"

secure_install
EOF_USER

chmod +x /home/$USERNAME/install_user.sh
chown $USERNAME:$USERNAME /home/$USERNAME/install_user.sh

sudo -i -u "$USERNAME" bash /home/$USERNAME/install_user.sh.sh"
TELEGRAM_SCRIPT="/usr/local/bin/telegram_command_listener.sh"

# === Перезапуск SSH не требуется, т.к. это делает root ===

# === Безопасность ===
# встроенная secure_install
  
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
  
  log " Настройка модулей безопасности..."
  
  # Установка модулей (если включены)
  for SERVICE in ufw fail2ban psad rkhunter; do
    if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
      log "Устанавливаем $SERVICE..."
      apt install -y "$SERVICE"
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
    [[ -n "\$RKHUNTER_RESULT" ]] && send " *RKHunter нашёл подозрения:*%0A\`\`\`\$RKHUNTER_RESULT\`\`\`"
  fi
  
  if command -v psad &>/dev/null; then
    PSAD_RESULT=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
    [[ -n "\$PSAD_RESULT" ]] && send " *PSAD предупреждение:*%0A\`\`\`\$PSAD_RESULT\`\`\`"
  fi
  
  echo "\$(date '+%F %T') | Проверка завершена" >> "\$LOG"
  EOF
  
  chmod +x /usr/local/bin/security_monitor.sh
  
  # === clear_security_log.sh ===
  cat > /usr/local/bin/clear_security_log.sh <<EOF
  echo "\$(date '+%F %T') | Очистка лога" > /var/log/security_monitor.log
  EOF
  chmod +x /usr/local/bin/clear_security_log.sh
  
  # === notify_login.sh (telegram) ===
  cat > /etc/profile.d/notify_login.sh <<'EOF'
  BOT_TOKEN="'"$BOT_TOKEN"'"
  CHAT_ID="'"$CHAT_ID"'"
  LABEL="'"$LABEL"'"
  USER_NAME=$(whoami)
  IP_ADDR=$(who | awk '{print $5}' | sed 's/[()]//g')
  HOSTNAME=$(hostname)
  LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")
  MESSAGE=" SSH вход: *$USER_NAME*%0A $HOSTNAME%0A $LOGIN_TIME%0A IP: \`$IP_ADDR\`%0A*Server:* \`$LABEL\`"
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$MESSAGE" > /dev/null
  EOF
  chmod +x /etc/profile.d/notify_login.sh
  
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
  
  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable --now telegram_command_listener.service
  
  # === Установка cron-задач ===
  TEMP_CRON=$(mktemp)
  crontab -l 2>/dev/null > "$TEMP_CRON" || true
  grep -v 'security_monitor\|clear_security_log' "$TEMP_CRON" > "${TEMP_CRON}.new"
  echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> "${TEMP_CRON}.new"
  echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> "${TEMP_CRON}.new"
  crontab "${TEMP_CRON}.new"
  rm -f "$TEMP_CRON" "${TEMP_CRON}.new"
  
  log " Безопасность настроена успешно"

secure_install
EOF_USER

chmod +x /home/$USERNAME/install_user.sh
chown $USERNAME:$USERNAME /home/$USERNAME/install_user.sh

sudo -i -u "$USERNAME" bash /home/$USERNAME/install_user.sh

# === Telegram-бот ===
if pgrep -f telegram_command_listener.sh > /dev/null; then
  log "Telegram-бот уже запущен"
else
  log "Устанавливаем Telegram-бота..."
  cp /usr/local/bin/telegram_command_listener.sh "$TELEGRAM_SCRIPT"
  chmod +x "$TELEGRAM_SCRIPT"
  echo "0" > /tmp/telegram_last_update_id
  nohup "$TELEGRAM_SCRIPT" > /var/log/telegram_bot.log 2>&1 &
fi

# === Docker (проверка и установка) ===
if ! command -v docker &>/dev/null; then
  log "Устанавливаем Docker..."
  sudo apt -o Dpkg::Options::="--force-confold" install -y docker.io
  sudo systemctl enable --now docker
else
  log "Docker уже установлен, проверка обновлений..."
  sudo apt -o Dpkg::Options::="--force-confold" install -y --only-upgrade docker.io
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
sudo apt update && sudo apt -o Dpkg::Options::="--force-confold" full-upgrade -y >> /var/log/auto_update.log 2>&1
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



# встроенная # встроенная secure_install
  
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
  
  log " Настройка модулей безопасности..."
  
  # Установка модулей (если включены)
  for SERVICE in ufw fail2ban psad rkhunter; do
    if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
      log "Устанавливаем $SERVICE..."
      apt install -y "$SERVICE"
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
    [[ -n "\$RKHUNTER_RESULT" ]] && send " *RKHunter нашёл подозрения:*%0A\`\`\`\$RKHUNTER_RESULT\`\`\`"
  fi
  
  if command -v psad &>/dev/null; then
    PSAD_RESULT=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
    [[ -n "\$PSAD_RESULT" ]] && send " *PSAD предупреждение:*%0A\`\`\`\$PSAD_RESULT\`\`\`"
  fi
  
  echo "\$(date '+%F %T') | Проверка завершена" >> "\$LOG"
  EOF
  
  chmod +x /usr/local/bin/security_monitor.sh
  
  # === clear_security_log.sh ===
  cat > /usr/local/bin/clear_security_log.sh <<EOF
  echo "\$(date '+%F %T') | Очистка лога" > /var/log/security_monitor.log
  EOF
  chmod +x /usr/local/bin/clear_security_log.sh
  
  # === notify_login.sh (telegram) ===
  cat > /etc/profile.d/notify_login.sh <<'EOF'
  BOT_TOKEN="'"$BOT_TOKEN"'"
  CHAT_ID="'"$CHAT_ID"'"
  LABEL="'"$LABEL"'"
  USER_NAME=$(whoami)
  IP_ADDR=$(who | awk '{print $5}' | sed 's/[()]//g')
  HOSTNAME=$(hostname)
  LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")
  MESSAGE=" SSH вход: *$USER_NAME*%0A $HOSTNAME%0A $LOGIN_TIME%0A IP: \`$IP_ADDR\`%0A*Server:* \`$LABEL\`"
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$MESSAGE" > /dev/null
  EOF
  chmod +x /etc/profile.d/notify_login.sh
  
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
  
  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable --now telegram_command_listener.service
  
  # === Установка cron-задач ===
  TEMP_CRON=$(mktemp)
  crontab -l 2>/dev/null > "$TEMP_CRON" || true
  grep -v 'security_monitor\|clear_security_log' "$TEMP_CRON" > "${TEMP_CRON}.new"
  echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> "${TEMP_CRON}.new"
  echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> "${TEMP_CRON}.new"
  crontab "${TEMP_CRON}.new"
  rm -f "$TEMP_CRON" "${TEMP_CRON}.new"
  
  log " Безопасность настроена успешно"

secure_install
EOF_USER

chmod +x /home/$USERNAME/install_user.sh
chown $USERNAME:$USERNAME /home/$USERNAME/install_user.sh

sudo -i -u "$USERNAME" bash /home/$USERNAME/install_user.sh
  
  export DEBIAN_FRONTEND=noninteractive
  
  # === # встроенная secure_install
  
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
  
  log " Настройка модулей безопасности..."
  
  # Установка модулей (если включены)
  for SERVICE in ufw fail2ban psad rkhunter; do
    if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
      log "Устанавливаем $SERVICE..."
      apt install -y "$SERVICE"
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
    [[ -n "\$RKHUNTER_RESULT" ]] && send " *RKHunter нашёл подозрения:*%0A\`\`\`\$RKHUNTER_RESULT\`\`\`"
  fi
  
  if command -v psad &>/dev/null; then
    PSAD_RESULT=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
    [[ -n "\$PSAD_RESULT" ]] && send " *PSAD предупреждение:*%0A\`\`\`\$PSAD_RESULT\`\`\`"
  fi
  
  echo "\$(date '+%F %T') | Проверка завершена" >> "\$LOG"
  EOF
  
  chmod +x /usr/local/bin/security_monitor.sh
  
  # === clear_security_log.sh ===
  cat > /usr/local/bin/clear_security_log.sh <<EOF
  echo "\$(date '+%F %T') | Очистка лога" > /var/log/security_monitor.log
  EOF
  chmod +x /usr/local/bin/clear_security_log.sh
  
  # === notify_login.sh (telegram) ===
  cat > /etc/profile.d/notify_login.sh <<'EOF'
  BOT_TOKEN="'"$BOT_TOKEN"'"
  CHAT_ID="'"$CHAT_ID"'"
  LABEL="'"$LABEL"'"
  USER_NAME=$(whoami)
  IP_ADDR=$(who | awk '{print $5}' | sed 's/[()]//g')
  HOSTNAME=$(hostname)
  LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")
  MESSAGE=" SSH вход: *$USER_NAME*%0A $HOSTNAME%0A $LOGIN_TIME%0A IP: \`$IP_ADDR\`%0A*Server:* \`$LABEL\`"
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$MESSAGE" > /dev/null
  EOF
  chmod +x /etc/profile.d/notify_login.sh
  
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
  
  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable --now telegram_command_listener.service
  
  # === Установка cron-задач ===
  TEMP_CRON=$(mktemp)
  crontab -l 2>/dev/null > "$TEMP_CRON" || true
  grep -v 'security_monitor\|clear_security_log' "$TEMP_CRON" > "${TEMP_CRON}.new"
  echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> "${TEMP_CRON}.new"
  echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> "${TEMP_CRON}.new"
  crontab "${TEMP_CRON}.new"
  rm -f "$TEMP_CRON" "${TEMP_CRON}.new"
  
  log " Безопасность настроена успешно"

secure_install
EOF_USER

chmod +x /home/$USERNAME/install_user.sh
chown $USERNAME:$USERNAME /home/$USERNAME/install_user.sh

sudo -i -u "$USERNAME" bash /home/$USERNAME/install_user.sh.sh ===
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
  
  log " Настройка модулей безопасности..."
  
  # Установка модулей (если включены)
  for SERVICE in ufw fail2ban psad rkhunter; do
    if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
      log "Устанавливаем $SERVICE..."
      apt install -y "$SERVICE"
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
    [[ -n "\$RKHUNTER_RESULT" ]] && send " *RKHunter нашёл подозрения:*%0A\`\`\`\$RKHUNTER_RESULT\`\`\`"
  fi
  
  if command -v psad &>/dev/null; then
    PSAD_RESULT=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
    [[ -n "\$PSAD_RESULT" ]] && send " *PSAD предупреждение:*%0A\`\`\`\$PSAD_RESULT\`\`\`"
  fi
  
  echo "\$(date '+%F %T') | Проверка завершена" >> "\$LOG"
  EOF
  
  chmod +x /usr/local/bin/security_monitor.sh
  
  # === clear_security_log.sh ===
  cat > /usr/local/bin/clear_security_log.sh <<EOF
  echo "\$(date '+%F %T') | Очистка лога" > /var/log/security_monitor.log
  EOF
  chmod +x /usr/local/bin/clear_security_log.sh
  
  # === notify_login.sh (telegram) ===
  cat > /etc/profile.d/notify_login.sh <<'EOF'
  BOT_TOKEN="'"$BOT_TOKEN"'"
  CHAT_ID="'"$CHAT_ID"'"
  LABEL="'"$LABEL"'"
  USER_NAME=$(whoami)
  IP_ADDR=$(who | awk '{print $5}' | sed 's/[()]//g')
  HOSTNAME=$(hostname)
  LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")
  MESSAGE=" SSH вход: *$USER_NAME*%0A $HOSTNAME%0A $LOGIN_TIME%0A IP: \`$IP_ADDR\`%0A*Server:* \`$LABEL\`"
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$MESSAGE" > /dev/null
  EOF
  chmod +x /etc/profile.d/notify_login.sh
  
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
  
  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable --now telegram_command_listener.service
  
  # === Установка cron-задач ===
  TEMP_CRON=$(mktemp)
  crontab -l 2>/dev/null > "$TEMP_CRON" || true
  grep -v 'security_monitor\|clear_security_log' "$TEMP_CRON" > "${TEMP_CRON}.new"
  echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> "${TEMP_CRON}.new"
  echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> "${TEMP_CRON}.new"
  crontab "${TEMP_CRON}.new"
  rm -f "$TEMP_CRON" "${TEMP_CRON}.new"
  
  log " Безопасность настроена успешно"

# встроенная secure_install
  
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
  
  log " Настройка модулей безопасности..."
  
  # Установка модулей (если включены)
  for SERVICE in ufw fail2ban psad rkhunter; do
    if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
      log "Устанавливаем $SERVICE..."
      apt install -y "$SERVICE"
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
    [[ -n "\$RKHUNTER_RESULT" ]] && send " *RKHunter нашёл подозрения:*%0A\`\`\`\$RKHUNTER_RESULT\`\`\`"
  fi
  
  if command -v psad &>/dev/null; then
    PSAD_RESULT=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
    [[ -n "\$PSAD_RESULT" ]] && send " *PSAD предупреждение:*%0A\`\`\`\$PSAD_RESULT\`\`\`"
  fi
  
  echo "\$(date '+%F %T') | Проверка завершена" >> "\$LOG"
  EOF
  
  chmod +x /usr/local/bin/security_monitor.sh
  
  # === clear_security_log.sh ===
  cat > /usr/local/bin/clear_security_log.sh <<EOF
  echo "\$(date '+%F %T') | Очистка лога" > /var/log/security_monitor.log
  EOF
  chmod +x /usr/local/bin/clear_security_log.sh
  
  # === notify_login.sh (telegram) ===
  cat > /etc/profile.d/notify_login.sh <<'EOF'
  BOT_TOKEN="'"$BOT_TOKEN"'"
  CHAT_ID="'"$CHAT_ID"'"
  LABEL="'"$LABEL"'"
  USER_NAME=$(whoami)
  IP_ADDR=$(who | awk '{print $5}' | sed 's/[()]//g')
  HOSTNAME=$(hostname)
  LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")
  MESSAGE=" SSH вход: *$USER_NAME*%0A $HOSTNAME%0A $LOGIN_TIME%0A IP: \`$IP_ADDR\`%0A*Server:* \`$LABEL\`"
  curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$MESSAGE" > /dev/null
  EOF
  chmod +x /etc/profile.d/notify_login.sh
  
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
  
  systemctl daemon-reexec
  systemctl daemon-reload
  systemctl enable --now telegram_command_listener.service
  
  # === Установка cron-задач ===
  TEMP_CRON=$(mktemp)
  crontab -l 2>/dev/null > "$TEMP_CRON" || true
  grep -v 'security_monitor\|clear_security_log' "$TEMP_CRON" > "${TEMP_CRON}.new"
  echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> "${TEMP_CRON}.new"
  echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> "${TEMP_CRON}.new"
  crontab "${TEMP_CRON}.new"
  rm -f "$TEMP_CRON" "${TEMP_CRON}.new"
  
  log " Безопасность настроена успешно"

secure_install
EOF_USER

chmod +x /home/$USERNAME/install_user.sh
chown $USERNAME:$USERNAME /home/$USERNAME/install_user.sh

sudo -i -u "$USERNAME" bash /home/$USERNAME/install_user.sh
EOF
chmod +x /home/$USERNAME/install_user.sh
chown $USERNAME:$USERNAME /home/$USERNAME/install_user.sh
echo "Теперь войдите как пользователь и выполните: bash ~/install_user.sh"
