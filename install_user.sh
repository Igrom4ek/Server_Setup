#!/bin/bash
set -e
export DEBIAN_FRONTEND=noninteractive

if [[ $EUID -ne 0 ]]; then
  echo "❌ Скрипт должен быть запущен с sudo!"
  exit 1
fi

CONFIG_FILE="/usr/local/bin/config.json"
KEY_FILE="/usr/local/bin/id_ed25519.pub"
LOG="$HOME/install_user.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log "== Установка сервисов от пользователя $USER =="

BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")
LABEL=$(jq -r '.telegram_server_label' "$CONFIG_FILE")
SECURITY_CHECK_CRON=$(jq -r '.cron_tasks.security_check' "$CONFIG_FILE")
CLEAR_LOG_CRON=$(jq -r '.cron_tasks.clear_logs' "$CONFIG_FILE")
MONITORING_ENABLED=$(jq -r '.monitoring_enabled' "$CONFIG_FILE")

PORT=$(jq -r '.port' "$CONFIG_FILE")
SSH_DISABLE_ROOT=$(jq -r '.ssh_disable_root' "$CONFIG_FILE")
SSH_PASSWORD_AUTH=$(jq -r '.ssh_password_auth' "$CONFIG_FILE")
MAX_AUTH_TRIES=$(jq -r '.max_auth_tries' "$CONFIG_FILE")
MAX_SESSIONS=$(jq -r '.max_sessions' "$CONFIG_FILE")
LOGIN_GRACE_TIME=$(jq -r '.login_grace_time' "$CONFIG_FILE")

log "Очистка старых конфигураций"
rm -f /etc/polkit-1/rules.d/49-nopasswd.rules 2>/dev/null || true
rm -f /etc/sudoers.d/90-$USER 2>/dev/null || true

log "Настройка polkit и sudo"
mkdir -p /etc/polkit-1/rules.d
cat <<EOF > /etc/polkit-1/rules.d/49-nopasswd.rules
polkit.addRule(function(action, subject) {
  if (subject.isInGroup("sudo")) {
    return polkit.Result.YES;
  }
});
EOF
systemctl daemon-reexec

echo "$USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/90-$USER
chmod 440 /etc/sudoers.d/90-$USER
log "Политика sudo и polkit настроена"

log "Настройка SSH для пользователя $USER"
mkdir -p /home/$USER/.ssh
chmod 700 /home/$USER/.ssh
cp "$KEY_FILE" /home/$USER/.ssh/authorized_keys
chmod 600 /home/$USER/.ssh/authorized_keys
chown -R $USER:$USER /home/$USER/.ssh
log "SSH-ключ установлен"

log "Обновление /etc/ssh/sshd_config"

# Установка openssh-server при необходимости
if ! systemctl list-unit-files | grep -qE 'ssh\.service|sshd\.service'; then
  log "openssh-server не найден, устанавливаю..."
  apt install -y openssh-server
fi

# Обновление порта
if grep -qE "^#?Port " /etc/ssh/sshd_config; then
  sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config
else
  echo "Port $PORT" >> /etc/ssh/sshd_config
  log "Добавлен Port $PORT в конец sshd_config"
fi

sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin $( [[ "$SSH_DISABLE_ROOT" == "true" ]] && echo "no" || echo "yes" )/" /etc/ssh/sshd_config
sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication $( [[ "$SSH_PASSWORD_AUTH" == "true" ]] && echo "yes" || echo "no" )/" /etc/ssh/sshd_config
sed -i "s/^#\?MaxAuthTries .*/MaxAuthTries $MAX_AUTH_TRIES/" /etc/ssh/sshd_config
sed -i "s/^#\?MaxSessions .*/MaxSessions $MAX_SESSIONS/" /etc/ssh/sshd_config
sed -i "s/^#\?LoginGraceTime .*/LoginGraceTime $LOGIN_GRACE_TIME/" /etc/ssh/sshd_config

systemctl restart ssh || systemctl restart sshd || true

log "sshd перезапущен. Проверка активного порта:"
ss -tulpn | grep ssh | tee -a "$LOG"

if ! ss -tulpn | grep -q ":$PORT"; then
  log "⚠️ Порт $PORT не активен. Проверьте конфигурацию sshd вручную!"
fi
