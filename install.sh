#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

REMOTE_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
CONFIG_FILE="/usr/local/bin/config.json"
KEY_FILE="/usr/local/bin/id_ed25519.pub"
SECURE_SCRIPT="/usr/local/bin/secure_install.sh"
TELEGRAM_SCRIPT="/usr/local/bin/telegram_command_listener.sh"
LOG="/var/log/server_install.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log "🚀 Запуск установки сервера"

# === 1. Обновление системы ===
log "Обновляем систему..."
apt update && apt dist-upgrade -y

# === 2. Установка утилит ===
log "Устанавливаем jq, curl, sudo..."
apt install -y jq curl sudo

# === 3. Исправление прав на sudo (если поломаны) ===
log "Проверка прав на /usr/bin/sudo и polkit..."
chmod 4755 /usr/bin/sudo || true
chown root:root /usr/bin/sudo || true
chmod 4755 /usr/libexec/polkit-agent-helper-1 2>/dev/null || true
chown root:root /usr/libexec/polkit-agent-helper-1 2>/dev/null || true

# === 4. Загрузка config и ключа ===
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "Загружаем config.json..."
  curl -fsSL "$REMOTE_URL/config.json" -o "$CONFIG_FILE"
fi
chmod 644 "$CONFIG_FILE"

if [[ ! -f "$KEY_FILE" ]]; then
  log "Загружаем публичный ключ id_ed25519.pub..."
  curl -fsSL "$REMOTE_URL/id_ed25519.pub" -o "$KEY_FILE"
fi
chmod 644 "$KEY_FILE"

# === 5. Конфигурация из JSON ===
USERNAME=$(jq -r '.username' "$CONFIG_FILE")
PORT=$(jq -r '.port' "$CONFIG_FILE")

log "Пользователь: $USERNAME | SSH-порт: $PORT"

# === 6. Валидация порта ===
if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [[ "$PORT" -lt 1024 ]]; then
  log "❌ Некорректный порт SSH: $PORT"
  exit 1
fi

# === 7. Создание пользователя ===
if id "$USERNAME" &>/dev/null; then
  log "Пользователь $USERNAME уже существует"
else
  adduser --disabled-password --gecos "" "$USERNAME" || { log "❌ Ошибка при создании пользователя"; exit 1; }
  echo "$USERNAME:Unguryan@224911" | chpasswd || { log "❌ Не удалось установить пароль"; exit 1; }
fi

log "Добавляем $USERNAME в группы: sudo docker adm systemd-journal syslog"
usermod -aG sudo,docker,adm,systemd-journal,syslog "$USERNAME"
log "Группы пользователя: $(id $USERNAME)"

# === 8. Установка SSH-ключей ===
log "Установка SSH-ключей для $USERNAME и root"

mkdir -p /home/$USERNAME/.ssh
cp "$KEY_FILE" /home/$USERNAME/.ssh/authorized_keys
chmod 700 /home/$USERNAME/.ssh
chmod 600 /home/$USERNAME/.ssh/authorized_keys
chown -R "$USERNAME:$USERNAME" /home/$USERNAME/.ssh

mkdir -p /root/.ssh
cp "$KEY_FILE" /root/.ssh/authorized_keys
chmod 700 /root/.ssh
chmod 600 /root/.ssh/authorized_keys

# === 9. Настройка SSH ===
# === 9b. Настройка SSH (дополнительные параметры из config.json) ===
DISABLE_ROOT=$(jq -r '.ssh_disable_root' "$CONFIG_FILE")
PASS_AUTH=$(jq -r '.ssh_password_auth' "$CONFIG_FILE")
MAX_AUTH=$(jq -r '.max_auth_tries' "$CONFIG_FILE")
MAX_SESSIONS=$(jq -r '.max_sessions' "$CONFIG_FILE")
LOGIN_GRACE=$(jq -r '.login_grace_time' "$CONFIG_FILE")

[[ "$DISABLE_ROOT" == "true" ]] && sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSHD"
[[ "$DISABLE_ROOT" == "false" ]] && sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" "$SSHD"

[[ "$PASS_AUTH" == "true" ]] && sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" "$SSHD"
[[ "$PASS_AUTH" == "false" ]] && sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$SSHD"

sed -i "s/^#\?MaxAuthTries .*/MaxAuthTries $MAX_AUTH/" "$SSHD"
sed -i "s/^#\?MaxSessions .*/MaxSessions $MAX_SESSIONS/" "$SSHD"
sed -i "s/^#\?LoginGraceTime .*/LoginGraceTime $LOGIN_GRACE/" "$SSHD"

log "Настройка SSH в /etc/ssh/sshd_config"

SSHD="/etc/ssh/sshd_config"
sed -i "s/^#\?Port .*/Port $PORT/" "$SSHD"
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" "$SSHD"
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" "$SSHD"
sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSHD"
sed -i "s|^#\?AuthorizedKeysFile .*|AuthorizedKeysFile .ssh/authorized_keys|" "$SSHD"

# Отключаем вход по паролю для igrom
if ! grep -q "Match User $USERNAME" "$SSHD"; then
  echo -e "\nMatch User $USERNAME\n    PasswordAuthentication no" >> "$SSHD"
fi

log "Текущие параметры SSH:"
grep -E '^Port|^PermitRootLogin|^PasswordAuthentication|^PubkeyAuthentication' "$SSHD"

systemctl restart ssh

# === 10. Настройка firewall ===
if command -v ufw &>/dev/null; then
  log "Открываем порт $PORT через UFW..."
  ufw allow "$PORT"
  ufw --force enable
else
  iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
  iptables-save > /etc/iptables.rules
fi

# === 11. secure_install.sh ===
log "Загружаем secure_install.sh..."
curl -fsSL "$REMOTE_URL/secure_install.sh" -o "$SECURE_SCRIPT"
chmod +x "$SECURE_SCRIPT"
bash "$SECURE_SCRIPT"

# === 12. Telegram-бот ===
if pgrep -f telegram_command_listener.sh > /dev/null; then
  log "Telegram-бот уже запущен"
else
  log "Устанавливаем Telegram-бота..."
  curl -fsSL "$REMOTE_URL/telegram_command_listener.sh" -o "$TELEGRAM_SCRIPT"
  chmod +x "$TELEGRAM_SCRIPT"
  echo "0" > /tmp/telegram_last_update_id  # Инициализация чтобы избежать спама
  nohup "$TELEGRAM_SCRIPT" > /var/log/telegram_bot.log 2>&1 &
fi

# === 13. Docker ===
if ! command -v docker &>/dev/null; then
  log "Устанавливаем Docker..."
  apt install -y docker.io
  systemctl enable --now docker
else
  log "Docker уже установлен, проверка обновлений..."
  apt install -y --only-upgrade docker.io
fi

log "Добавляем $USERNAME в группу docker..."
usermod -aG docker "$USERNAME"

# === 14. Netdata ===
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


# === 16. Очистка install-лога ===
log "Настраиваем автоочистку /var/log/server_install.log..."
cat > /usr/local/bin/clear_install_log.sh <<EOF
#!/bin/bash
echo "$(date '+%F %T') | Очистка install лога" > /var/log/server_install.log
EOF
chmod +x /usr/local/bin/clear_install_log.sh

# Добавление в cron (суббота 04:00)
(crontab -l 2>/dev/null; echo "0 4 * * 6 /usr/local/bin/clear_install_log.sh") | sort -u | crontab -

# === 17. Автообновление системы через cron ===
AUTO_UPDATE_CRON=$(jq -r '.auto_update_cron' "$CONFIG_FILE")
cat > /usr/local/bin/auto_update.sh <<EOF
#!/bin/bash
echo "$(date '+%F %T') | Обновление системы" >> /var/log/auto_update.log
apt update && apt upgrade -y >> /var/log/auto_update.log 2>&1
EOF
chmod +x /usr/local/bin/auto_update.sh
(crontab -l 2>/dev/null; echo "$AUTO_UPDATE_CRON /usr/local/bin/auto_update.sh") | sort -u | crontab -
# === 15. Финальное резюме ===
log "=== 📋 Сводка установки ==="
log "👤 Пользователь: $USERNAME"
log "🔐 Root-доступ по паролю: включён"
log "🛡 Безопасность: настроена"
log "🤖 Telegram-бот: запущен"
log "📊 Netdata: http://YOUR_SERVER_IP:19999"
log "✅ Установка завершена. Подключение: ssh -p $PORT $USERNAME@YOUR_SERVER_IP"
