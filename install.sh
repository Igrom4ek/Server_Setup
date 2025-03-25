from pathlib import Path

# Подготовим файл с обновленным install.sh
install_sh_path = Path("/mnt/data/install_fixed.sh")
install_sh_content = """#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

REMOTE_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
CONFIG_FILE="/usr/local/bin/config.json"
KEY_FILE="/usr/local/bin/id_ed25519.pub"
SECURE_SCRIPT="/usr/local/bin/secure_install.sh"
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

# === 6. Создание пользователя ===
if id "$USERNAME" &>/dev/null; then
  log "Пользователь $USERNAME уже существует"
else
  adduser --disabled-password --gecos "" "$USERNAME"
  echo "$USERNAME:Unguryan@224911" | chpasswd
  usermod -aG sudo,docker,adm,systemd-journal,syslog "$USERNAME"
fi

# === 7. Установка SSH-ключей ===
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

# === 8. Настройка SSH ===
log "Настройка SSH в /etc/ssh/sshd_config"

SSHD="/etc/ssh/sshd_config"
sed -i "s/^#\\?Port .*/Port $PORT/" "$SSHD"
sed -i "s/^#\\?PermitRootLogin .*/PermitRootLogin yes/" "$SSHD"
sed -i "s/^#\\?PasswordAuthentication .*/PasswordAuthentication yes/" "$SSHD"
sed -i "s/^#\\?PubkeyAuthentication .*/PubkeyAuthentication yes/" "$SSHD"
sed -i "s|^#\\?AuthorizedKeysFile .*|AuthorizedKeysFile .ssh/authorized_keys|" "$SSHD"

# Отключаем пароль для igrom
if ! grep -q "Match User $USERNAME" "$SSHD"; then
  echo -e "\\nMatch User $USERNAME\\n    PasswordAuthentication no" >> "$SSHD"
fi

systemctl restart ssh

# === 9. Настройка firewall ===
if command -v ufw &>/dev/null; then
  log "Открываем порт $PORT через UFW..."
  ufw allow "$PORT"
  ufw --force enable
else
  iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
  iptables-save > /etc/iptables.rules
fi

# === 10. secure_install.sh ===
log "Загружаем secure_install.sh..."
curl -fsSL "$REMOTE_URL/secure_install.sh" -o "$SECURE_SCRIPT"
chmod +x "$SECURE_SCRIPT"
bash "$SECURE_SCRIPT"

# === 11. Установка Docker ===
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

# === 12. Netdata ===
if ! docker ps | grep -q netdata; then
  log "Запускаем Netdata в контейнере..."
  docker run -d --name netdata \\
    -p 19999:19999 \\
    -v /etc/netdata:/etc/netdata:ro \\
    -v /var/lib/netdata:/var/lib/netdata \\
    -v /proc:/host/proc:ro \\
    -v /sys:/host/sys:ro \\
    -v /var/run/docker.sock:/var/run/docker.sock:ro \\
    --cap-add SYS_PTRACE \\
    --security-opt apparmor=unconfined \\
    netdata/netdata
else
  log "Netdata уже работает"
fi

log "✅ Установка завершена. Подключение: ssh -p $PORT $USERNAME@YOUR_SERVER_IP"
log "🔐 Root-доступ включён. Вход по паролю и ключу: ssh -p $PORT root@YOUR_SERVER_IP"
"""

# Сохраняем обновлённый скрипт
install_sh_path.write_text(install_sh_content)
install_sh_path

