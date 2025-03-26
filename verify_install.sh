#!/bin/bash

echo "=== ✅ Проверка установки сервера ==="
CONFIG="/usr/local/bin/config.json"

# Проверка наличия конфигурации
if [[ ! -f "$CONFIG" ]]; then
  echo "❌ Конфигурационный файл не найден: $CONFIG"
  exit 1
fi

USERNAME=$(jq -r '.username' "$CONFIG")
PORT=$(jq -r '.port' "$CONFIG")
SSH_KEY_FILE=$(jq -r '.ssh_key_file' "$CONFIG")
SECURITY_LOG="/var/log/security_monitor.log"

echo "--- 👤 Пользователь и SSH ---"
id "$USERNAME" &>/dev/null && echo "✅ Пользователь $USERNAME существует" || echo "❌ Пользователь $USERNAME не найден"
[[ -f /home/$USERNAME/.ssh/authorized_keys ]] && echo "✅ SSH-ключ установлен" || echo "❌ Ключ не найден в ~/.ssh/authorized_keys"
ss -tuln | grep ":$PORT" &>/dev/null && echo "✅ Порт $PORT слушает" || echo "❌ Порт $PORT не слушает"

echo "--- 🔒 Безопасность ---"
systemctl is-active fail2ban &>/dev/null && echo "✅ Fail2Ban активен" || echo "❌ Fail2Ban не запущен"
[[ -f /var/log/auth.log ]] && echo "✅ Лог авторизаций есть" || echo "⚠️ Нет auth.log"
[[ -f "$SECURITY_LOG" ]] && echo "✅ Лог безопасности: найден" || echo "❌ Лог безопасности не создан"

echo "--- 🛡 UFW / iptables ---"
if command -v ufw &>/dev/null; then
  ufw status | grep -q "$PORT" && echo "✅ UFW разрешает порт $PORT" || echo "❌ UFW не разрешает порт"
else
  iptables -S | grep -q "$PORT" && echo "✅ iptables пропускает порт $PORT" || echo "❌ iptables не настроен"
fi

echo "--- 🐳 Docker / Netdata ---"
docker ps | grep -q netdata && echo "✅ Netdata работает (docker)" || echo "❌ Netdata не найден в docker"
docker ps | grep -q "netdata/netdata" || echo "⚠️ Образ Netdata может отсутствовать"

echo "--- 🕓 Cron-задачи ---"
crontab -l | grep -q security_monitor && echo "✅ Cron: security_monitor.sh найден" || echo "❌ Нет задачи на security_monitor.sh"
crontab -l | grep -q clear_security_log && echo "✅ Cron: clear_security_log.sh найден" || echo "❌ Нет задачи на очистку логов"

echo "--- 📲 Telegram ---"
BOT=$(jq -r '.telegram_bot_token' "$CONFIG")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG")
[[ "$BOT" != "null" && "$BOT" != "" ]] && echo "✅ Telegram токен задан" || echo "❌ Telegram токен пуст"
[[ "$CHAT_ID" != "null" && "$CHAT_ID" != "" ]] && echo "✅ Telegram chat_id задан" || echo "❌ Telegram chat_id пуст"

echo "--- 🔁 PSAD / RKHUNTER ---"
[[ -f /var/log/psad/alert ]] && echo "✅ psad: лог alert найден" || echo "⚠️ psad лог не найден"
command -v rkhunter &>/dev/null && echo "✅ rkhunter установлен" || echo "❌ rkhunter не установлен"

echo "--- ✅ Проверка завершена ---"
