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

# === SSH: настройка authorized_keys ===
log "🔐 Настраиваем .ssh"
if [[ ! -d "$HOME/.ssh" ]]; then
  log "Создаём .ssh"
  mkdir -p "$HOME/.ssh"
else
  log ".ssh уже существует, пропускаем создание"
fi
sudo chmod 700 "$HOME/.ssh"
if [[ ! -f "$HOME/.ssh/authorized_keys" ]]; then
  log "Создаём authorized_keys"
  touch "$HOME/.ssh/authorized_keys"
else
  log "authorized_keys уже существует, пропускаем создание"
fi
sudo chmod 600 "$HOME/.ssh/authorized_keys"
cat "$KEY_FILE" >> "$HOME/.ssh/authorized_keys"

# === Проверка порта ===
if ! command -v jq &>/dev/null; then echo '❌ Требуется jq. Установите вручную.'; exit 1; fi
PORT=$(jq -r '.port' "$CONFIG_FILE")
if ss -tuln | grep -q ":$PORT"; then
  log "⚠️ Порт $PORT уже используется."
  echo "  [1] Продолжить с этим портом"
  echo "  [2] Ввести другой порт"
  echo "  [3] Пропустить настройку порта"
  read -p "Выберите действие [1-3]: " choice
  case "$choice" in
    1) log "Продолжаем с занятым портом (на свой страх и риск)" ;;
    2) read -p "Введите новый порт: " PORT ;;
    3) log "Пропускаем настройку порта" ; SKIP_PORT=1 ;;
    *) echo "Неверный выбор. Прерывание." ; exit 1 ;;
  esac
fi
if [[ -z "$SKIP_PORT" ]]; then
  log "⚙️ Настраиваем /etc/ssh/sshd_config"
  sudo sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config
  sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
  sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
  sudo sed -i "s|^#\?AuthorizedKeysFile .*|AuthorizedKeysFile .ssh/authorized_keys|" /etc/ssh/sshd_config
  sudo systemctl restart ssh
fi

# === Настройка sudo без пароля ===
log "🔧 Настраиваем sudo без пароля"
echo "$USER ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-$USER > /dev/null
sudo chmod 440 /etc/sudoers.d/90-$USER
log "✅ Настроено sudo без пароля для пользователя $USER"

# === Установка модулей безопасности ===
log "🛡 Настройка модулей безопасности..."

# Устанавливаем ufw, fail2ban, psad, rkhunter через sudo
for SERVICE in ufw fail2ban psad rkhunter; do
  if ! dpkg -s "$SERVICE" &>/dev/null; then
    sudo apt install -y "$SERVICE"
  else
    log "Пакет(ы) уже установлены, пропускаем: sudo apt install -y $SERVICE"
  fi
  sudo systemctl enable --now "$SERVICE"
done

# === Создание security_monitor.sh ===
cat > /usr/local/bin/security_monitor.sh <<EOF
#!/bin/bash
LOG="/var/log/security_monitor.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
LABEL="$LABEL"

send() {
  curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage"     -d chat_id="\$CHAT_ID"     -d parse_mode="Markdown"     -d text="\$1%0A*Server:* \`\$LABEL\`" > /dev/null
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
#!/bin/bash
echo "\$(date '+%F %T') | Очистка лога" > /var/log/security_monitor.log
EOF
sudo chmod +x /usr/local/bin/clear_security_log.sh

# === notify_login.sh (telegram) ===
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

# === Установка systemd сервиса telegram_command_listener ===
cat > /etc/systemd/system/telegram_command_listener.service <<EOF
[Unit]
Description=Telegram Command Listener
After=network.target

[Service]
ExecStart=/usr/local/bin/telegram_command_listener.sh
Restart=always
User=$USER

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reexec
sudo systemctl daemon-reload
sudo systemctl enable --now telegram_command_listener.service

log "🧹 Удаляем install_user.sh (если запущен из файла)"
[[ -f "$0" && "$0" == "$HOME/install_user.sh" ]] && rm -f "$0"