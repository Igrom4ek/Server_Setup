#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

CONFIG_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/config.json"
CONFIG_FILE="/usr/local/bin/config.json"
LOG="/var/log/install_root.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log "📦 Обновляем систему (root)"
apt clean all
apt update
apt dist-upgrade -y
apt install -y curl jq sudo

log "⬇️ Скачиваем config.json"
curl -fsSL "$CONFIG_URL" -o "$CONFIG_FILE"
chmod 644 "$CONFIG_FILE"

USERNAME=$(jq -r '.username' "$CONFIG_FILE")
PASSWORD=$(jq -r '.user_password' "$CONFIG_FILE")
PUBKEY=$(jq -r '.public_key_content' "$CONFIG_FILE")

log "👤 Создаём пользователя $USERNAME"
adduser --disabled-password --gecos "" "$USERNAME"
echo "$USERNAME:$PASSWORD" | chpasswd
usermod -aG sudo,adm,systemd-journal,syslog "$USERNAME"
if getent group docker > /dev/null; then
  usermod -aG docker "$USERNAME"
fi

log "🔒 Отключаем запрос пароля polkit для группы sudo"
if [[ -f /etc/polkit-1/rules.d/49-nopasswd.rules ]]; then
  sudo rm -f /etc/polkit-1/rules.d/49-nopasswd.rules
  log "Удалены старые правила polkit"
fi

sudo mkdir -p /etc/polkit-1/rules.d
cat <<EOF | sudo tee /etc/polkit-1/rules.d/49-nopasswd.rules > /dev/null
polkit.addRule(function(action, subject) {
  if (subject.isInGroup("sudo")) {
    return polkit.Result.YES;
  }
});
EOF
sudo systemctl daemon-reexec
log "✅ Политика polkit обновлена"

echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-$USERNAME > /dev/null
sudo chmod 440 /etc/sudoers.d/90-$USERNAME
log "🔧 Настроено sudo без пароля для пользователя $USERNAME"

log "📁 Установка SSH-ключа в /home/$USERNAME/.ssh"
sudo -u "$USERNAME" mkdir -p "/home/$USERNAME/.ssh"
echo "$PUBKEY" | sudo tee "/home/$USERNAME/.ssh/authorized_keys" > /dev/null
sudo chmod 700 "/home/$USERNAME/.ssh"
sudo chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
sudo chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"

log "✅ Пользователь создан. Теперь войдите под $USERNAME и выполните install_user.sh"
echo
echo "  su - $USERNAME"
echo "  bash install_user.sh"