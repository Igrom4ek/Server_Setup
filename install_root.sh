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

log "📦 Начинаем установку базовой системы (root)"

apt clean all
apt update
apt dist-upgrade -y
apt install -y curl jq sudo

log "⬇️ Скачиваем конфигурации"
curl -fsSL "$CONFIG_URL" -o "$CONFIG_FILE"
curl -fsSL "$KEY_URL" -o "$KEY_FILE"
chmod 644 "$CONFIG_FILE" "$KEY_FILE"

USERNAME=$(jq -r '.username' "$CONFIG_FILE")
PORT=$(jq -r '.port' "$CONFIG_FILE")
PASSWORD=$(jq -r '.user_password' "$CONFIG_FILE")

log "🧪 Проверяем порт $PORT на занятость"
if ss -tuln | grep -q ":$PORT"; then
  log "❌ Порт $PORT уже используется. Укажи другой в config.json"
  exit 1
fi

log "👤 Создаём пользователя $USERNAME"
adduser --disabled-password --gecos "" "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
usermod -aG sudo,docker,adm,systemd-journal,syslog "$USERNAME"
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$USERNAME"
chmod 440 "/etc/sudoers.d/90-$USERNAME"

log "🔐 Настраиваем SSH"
mkdir -p /home/$USERNAME/.ssh
cp "$KEY_FILE" /home/$USERNAME/.ssh/authorized_keys
chmod 700 /home/$USERNAME/.ssh
chmod 600 /home/$USERNAME/.ssh/authorized_keys
chown -R "$USERNAME:$USERNAME" /home/$USERNAME/.ssh

SSHD="/etc/ssh/sshd_config"
sed -i "s/^#\?Port .*/Port $PORT/" "$SSHD"
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin yes/" "$SSHD"
sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSHD"
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication yes/" "$SSHD"
sed -i "s/^#\?AuthorizedKeysFile .*/AuthorizedKeysFile .ssh\/authorized_keys/" "$SSHD"

if ! grep -q "Match User $USERNAME" "$SSHD"; then
  echo -e "\nMatch User $USERNAME\n    PasswordAuthentication no" >> "$SSHD"
fi

systemctl restart ssh

log "🛑 Отключаем лишний вывод ядра (quiet boot)"
sed -i 's/GRUB_CMDLINE_LINUX="[^"]*/& quiet loglevel=0 vt.global_cursor_default=0/' /etc/default/grub
update-grub || true

log "✅ Установка завершена"
echo
echo "Теперь войди под пользователем \033[1m$USERNAME\033[0m и выполни:"
echo "  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/install_user.sh)\""
