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

# === 1. Очистка кэша и обновление системы ===
log "Очистка кэша и обновление системы..."
apt clean && apt autoremove -y
apt update && apt full-upgrade -y

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

# === 8. Создание .ssh и копирование ключа под пользователем ===
log "Настройка SSH-ключей под $USERNAME"
sudo -i -u "$USERNAME" bash <<EOF
mkdir -p ~/.ssh
cat "$KEY_FILE" > ~/.ssh/authorized_keys
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
EOF

chown -R "$USERNAME:$USERNAME" /home/$USERNAME/.ssh

# === 9. Продолжение установки как раньше ===
# ... (оставшиеся шаги остаются без изменений)
