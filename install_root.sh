#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

CONFIG_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/config.json"
KEY_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/id_ed25519.pub"
CONFIG_FILE="/usr/local/bin/config.json"
KEY_FILE="/usr/local/bin/id_ed25519.pub"
LOG="/var/log/install_root.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log "📦 Обновляем систему (root)"
apt clean all
apt update
apt dist-upgrade -y
apt install -y curl jq sudo

log "⬇️ Скачиваем config.json и публичный ключ"
curl -fsSL "$CONFIG_URL" -o "$CONFIG_FILE"
curl -fsSL "$KEY_URL" -o "$KEY_FILE"
chmod 644 "$CONFIG_FILE" "$KEY_FILE"

USERNAME=$(jq -r '.username' "$CONFIG_FILE")
PASSWORD=$(jq -r '.user_password' "$CONFIG_FILE")

log "👤 Создаём пользователя $USERNAME"
adduser --disabled-password --gecos "" "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
usermod -aG sudo,adm,systemd-journal,syslog,docker "$USERNAME"

log "✅ Пользователь создан. Теперь войдите под $USERNAME и выполните install_user.sh"
echo
echo "  su - $USERNAME"
echo "  bash install_user.sh"