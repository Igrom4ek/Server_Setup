#!/bin/bash
set -e

# === install.sh ===
# Основной установщик: создаёт пользователя, настраивает SSH, вызывает secure_install.sh, ставит Docker + Netdata

REMOTE_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
CONFIG_FILE="/usr/local/bin/config.json"
KEY_FILE="/usr/local/bin/ssh_key.pub"
SECURE_SCRIPT="/usr/local/bin/secure_install.sh"
LOG="/var/log/server_install.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log "🚀 Запуск основного установочного скрипта"

# === 1. Обновление системы ===
log "Обновляем систему..."
apt update && apt dist-upgrade -y

# === 2. Установка зависимостей ===
log "Установка jq и curl (если не установлены)..."
apt install -y jq curl sudo

# === 3. Загрузка config.json и ssh_key.pub ===
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "Загружаем config.json..."
  curl -fsSL "$REMOTE_URL/config.json" -o "$CONFIG_FILE"
fi
chmod 644 "$CONFIG_FILE"

if [[ ! -f "$KEY_FILE" ]]; then
  log "Загружаем SSH ключ..."
  curl -fsSL "$REMOTE_URL/ssh_key.pub" -o "$KEY_FILE"
fi
chmod 644 "$KEY_FILE"

# === 4. Извлечение данных из config.json ===
USERNAME=$(jq -r '.username' "$CONFIG_FILE")
PORT=$(jq -r '.port' "$CONFIG_FILE")
NOPASSWD=$(jq -r '.sudo_nopasswd' "$CONFIG_FILE")

log "Пользователь: $USERNAME, SSH порт: $PORT"

# === 5. Создание пользователя ===
if id "$USERNAME" &>/dev/null; then
  log "Пользователь $USERNAME уже существует"
else
  log "Создаём пользователя $USERNAME..."
  adduser --disabled-password --gecos "" "$USERNAME"
  echo "$USERNAME:SecureP@ssw0rd" | chpasswd
  usermod -aG sudo "$USERNAME"
  [[ "$NOPASSWD" == "true" ]] && echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers
fi

# === 6. Настройка SSH ===
log "Настраиваем SSH..."
SSHD="/etc/ssh/sshd_config"
sed -i "s/^#\?Port .*/Port $PORT/" "$SSHD"
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSHD"
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$SSHD"
sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSHD"
sed -i "s/^#\?AuthorizedKeysFile .*/AuthorizedKeysFile .ssh/authorized_keys/" "$SSHD"

mkdir -p /home/$USERNAME/.ssh
cp "$KEY_FILE" /home/$USERNAME/.ssh/authorized_keys
chmod 700 /home/$USERNAME/.ssh
chmod 600 /home/$USERNAME/.ssh/authorized_keys
chown -R "$USERNAME:$USERNAME" /home/$USERNAME/.ssh

systemctl restart ssh

# === 7. Открытие порта ===
if command -v ufw &>/dev/null; then
  ufw allow "$PORT"
  ufw --force enable
else
  iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
fi

# === 8. Загрузка и запуск secure_install.sh ===
log "Загружаем secure_install.sh..."
curl -fsSL "$REMOTE_URL/secure_install.sh" -o "$SECURE_SCRIPT"
chmod +x "$SECURE_SCRIPT"
bash "$SECURE_SCRIPT"

# === 9. Установка / обновление Docker ===
if ! command -v docker &>/dev/null; then
  log "Устанавливаем Docker..."
  apt install -y docker.io
  systemctl enable --now docker
else
  log "Docker уже установлен, проверяем обновления..."
  apt install -y --only-upgrade docker.io
fi

# === 10. Запуск Netdata (если не запущен) ===
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
  log "Netdata уже работает."
fi

log "✅ Установка завершена. Подключайтесь по: ssh -p $PORT $USERNAME@YOUR_SERVER"
