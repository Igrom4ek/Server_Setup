#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

REMOTE_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
CONFIG_FILE="/usr/local/bin/config.json"
KEY_FILE="/usr/local/bin/id_ed25519.pub"
INSTALL_USER_SCRIPT="/home/$USERNAME/install_user.sh"
LOG="/var/log/server_install.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log " [ROOT] Запуск установки сервера"

apt clean && apt autoremove -y
apt update && apt full-upgrade -y

log "Установка базовых пакетов"
apt install -y jq curl sudo

log "Загружаем конфиг и ключ"
curl -fsSL "$REMOTE_URL/config.json" -o "$CONFIG_FILE"
curl -fsSL "$REMOTE_URL/id_ed25519.pub" -o "$KEY_FILE"
chmod 644 "$CONFIG_FILE" "$KEY_FILE"

USERNAME=$(jq -r '.username' "$CONFIG_FILE")
PORT=$(jq -r '.port' "$CONFIG_FILE")

if ! id "$USERNAME" &>/dev/null; then
  log "Создание пользователя $USERNAME"
  adduser --disabled-password --gecos "" "$USERNAME"
  echo "$USERNAME:Unguryan@224911" | chpasswd
else
  log "Пользователь $USERNAME уже существует"
fi

log "Добавляем $USERNAME в группы"
usermod -aG sudo,docker,adm,systemd-journal,syslog "$USERNAME"


# === Включаем NOPASSWD для пользователя ===
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$USERNAME
chmod 440 /etc/sudoers.d/90-$USERNAME

# === Настраиваем SSH ===
SSHD="/etc/ssh/sshd_config"
sed -i "s/^#\?Port .*/Port $PORT/" "$SSHD"
sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" "$SSHD"
sed -i "s/^#\?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSHD"
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" "$SSHD"
systemctl restart ssh


log "Создаём .ssh и копируем ключ"
sudo -i -u "$USERNAME" bash <<EOF
mkdir -p ~/.ssh
cat "$KEY_FILE" > ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
EOF
chown -R "$USERNAME:$USERNAME" /home/$USERNAME/.ssh

log "Копируем и запускаем пользовательскую часть"
curl -fsSL "$REMOTE_URL/install_user.sh" -o "$INSTALL_USER_SCRIPT"
chown "$USERNAME:$USERNAME" "$INSTALL_USER_SCRIPT"
chmod +x "$INSTALL_USER_SCRIPT"
sudo -i -u "$USERNAME" bash "$INSTALL_USER_SCRIPT"
