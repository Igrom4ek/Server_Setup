#!/bin/bash
set -e

CONFIG_FILE="/usr/local/bin/config.json"
LOG="/var/log/secure-server-setup.log"

# Проверка и установка jq
if ! command -v jq &>/dev/null; then
  echo "[+] Устанавливаем jq..." | tee -a "$LOG"
  apt install jq -y
fi

# Проверка наличия config.json
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ Файл конфигурации не найден: $CONFIG_FILE" | tee -a "$LOG"
  exit 1
fi

# Извлечение параметров из config.json
BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")
UFW_ENABLED=$(jq -r '.services.ufw // true' "$CONFIG_FILE")
FAIL2BAN_ENABLED=$(jq -r '.services.fail2ban // true' "$CONFIG_FILE")
PSAD_ENABLED=$(jq -r '.services.psad // true' "$CONFIG_FILE")
RKHUNTER_ENABLED=$(jq -r '.services.rkhunter // true' "$CONFIG_FILE")

echo "=== Расширенная защита сервера — $(date) ===" | tee -a "$LOG"

# Функция отправки в Telegram
send_telegram() {
  MESSAGE="$1"
  if [[ "$BOT_TOKEN" != "null" && "$CHAT_ID" != "null" ]]; then
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
      -d chat_id="$CHAT_ID" \
      -d parse_mode="Markdown" \
      -d text="$MESSAGE" > /dev/null
  fi
}

# UFW
if [[ "$UFW_ENABLED" == "true" ]]; then
  if ! command -v ufw &>/dev/null; then
    echo "[+] Устанавливаем ufw..." | tee -a "$LOG"
    apt install ufw -y
  fi
  ufw allow ssh
  ufw --force enable
  echo "[✓] ufw активирован" | tee -a "$LOG"
fi

# FAIL2BAN
if [[ "$FAIL2BAN_ENABLED" == "true" ]]; then
  if ! command -v fail2ban-client &>/dev/null; then
    echo "[+] Устанавливаем fail2ban..." | tee -a "$LOG"
    apt install fail2ban -y
  fi
  systemctl enable --now fail2ban
  echo "[✓] fail2ban работает" | tee -a "$LOG"
fi

# RKHUNTER
if [[ "$RKHUNTER_ENABLED" == "true" ]]; then
  if ! command -v rkhunter &>/dev/null; then
    echo "[+] Устанавливаем rkhunter..." | tee -a "$LOG"
    apt install rkhunter -y
  fi
  rkhunter --update
  rkhunter --propupd
  echo "[✓] rkhunter обновлён и проиндексирован" | tee -a "$LOG"
fi

# PSAD
if [[ "$PSAD_ENABLED" == "true" ]]; then
  if ! command -v psad &>/dev/null; then
    echo "[+] Устанавливаем psad..." | tee -a "$LOG"
    apt install psad -y
  fi
  iptables -A INPUT -j LOG
  iptables -A FORWARD -j LOG
  systemctl enable --now psad
  psad --sig-update
  echo "[✓] psad активирован и отслеживает сканирование портов" | tee -a "$LOG"
fi

# Уведомление в Telegram об успешной установке
SERVICES=""
[[ "$UFW_ENABLED" == "true" ]] && SERVICES="$SERVICES- UFW\n"
[[ "$FAIL2BAN_ENABLED" == "true" ]] && SERVICES="$SERVICES- Fail2Ban\n"
[[ "$PSAD_ENABLED" == "true" ]] && SERVICES="$SERVICES- PSAD\n"
[[ "$RKHUNTER_ENABLED" == "true" ]] && SERVICES="$SERVICES- RKHunter\n"
send_telegram "🛡️ Сервер *успешно защищён*! Активированы:\n$SERVICES"
echo "✅ Уведомление отправлено в Telegram." | tee -a "$LOG"

# Уведомление при SSH-входе
echo "[+] Создаём скрипт уведомления о входе по SSH..." | tee -a "$LOG"
tee /etc/profile.d/notify_login.sh > /dev/null <<EOF
#!/bin/bash
BOT_TOKEN="${BOT_TOKEN}"
CHAT_ID="${CHAT_ID}"
USER_NAME=\$(whoami)
IP_ADDR=\$(who | awk '{print \$5}' | sed 's/[()]//g')
HOSTNAME=\$(hostname)
LOGIN_TIME=\$(date "+%Y-%m-%d %H:%M:%S")
MESSAGE="🔐 SSH-вход на сервер *\${HOSTNAME}*\n👤 Пользователь: *\${USER_NAME}*\n🕒 Время: *\${LOGIN_TIME}*\n🌐 IP: \\\`\${IP_ADDR:-unknown}\\\`"
echo "\$LOGIN_TIME | SSH login: \$USER_NAME from \$IP_ADDR" >> /var/log/login_notify.log
curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \
  -d chat_id="\${CHAT_ID}" \
  -d parse_mode="Markdown" \
  -d text="\${MESSAGE}" > /dev/null
EOF
chmod +x /etc/profile.d/notify_login.sh
echo "[✓] Уведомление при SSH-входе настроено" | tee -a "$LOG"

# Создание скрипта очистки лога
echo "[+] Создаём скрипт очистки логов..." | tee -a "$LOG"
tee /usr/local/bin/clear_security_log.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="\$(jq -r '.security_log_file // "/var/log/security_monitor.log"' "$CONFIG_FILE")"
echo "\$(date '+%Y-%m-%d %H:%M:%S') | 🧹 Очистка лога безопасности (еженедельно)" > "\$LOG_FILE"
EOF
chmod +x /usr/local/bin/clear_security_log.sh

# Добавление в crontab
CLEAR_LOGS_CRON=$(jq -r '.clear_logs_cron // "0 5 * * 0"' "$CONFIG_FILE")
SECURITY_CHECK_CRON=$(jq -r '.security_check_cron // "0 6 * * *"' "$CONFIG_FILE")
echo "[+] Настраиваем crontab..." | tee -a "$LOG"
( crontab -l 2>/dev/null; echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" ) | crontab -
( crontab -l 2>/dev/null; echo "$CLEAR_LOGS_CRON /usr/local/bin/clear_security_log.sh" ) | sort -u | crontab -
echo "[✓] Crontab обновлён" | tee -a "$LOG"

# Финальное уведомление
send_telegram "📬 Настроены:\n- Уведомления при входе\n- Очистка логов\n- Cron-задачи активны"
echo "🚀 Всё готово!" | tee -a "$LOG"