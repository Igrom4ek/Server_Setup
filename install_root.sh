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
usermod -aG sudo,adm,systemd-journal,syslog "$USERNAME"
if getent group docker > /dev/null; then
  usermod -aG docker "$USERNAME"
fi

log "🔒 Отключаем запрос пароля polkit для группы sudo"
# Удаляем старые polkit-правила
if [[ -f /etc/polkit-1/rules.d/49-nopasswd.rules ]]; then
  sudo rm -f /etc/polkit-1/rules.d/49-nopasswd.rules
  log "Удалены старые правила polkit"
fi

# Создаём новые правила для sudo
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

# Настройка sudo без пароля
echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/90-$USERNAME > /dev/null
sudo chmod 440 /etc/sudoers.d/90-$USERNAME
log "🔧 Настроено sudo без пароля для пользователя $USERNAME"

log "✅ Пользователь создан. Теперь войдите под $USERNAME и выполните install_user.sh"
echo
echo "  su - $USERNAME"
echo "  bash install_user.sh"
