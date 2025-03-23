#!/bin/bash
set -e

LOG="/var/log/secure-server-setup.log"
echo "=== Расширенная защита сервера — $(date) ===" | tee -a "$LOG"

# === TELEGRAM ===
BOT_TOKEN="8019987480:AAEJdUAAiGqlTFjOahWNh3RY5hiEwo3-E54"
CHAT_ID="543102005"

send_telegram() {
  MESSAGE="$1"
  curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
    -d chat_id="$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="$MESSAGE" > /dev/null
}

# === UFW ===
if ! command -v ufw &>/dev/null; then
  echo "[+] Устанавливаем ufw..." | tee -a "$LOG"
  apt install ufw -y
fi
ufw allow ssh
ufw --force enable
echo "[✓] ufw активирован" | tee -a "$LOG"

# === FAIL2BAN ===
if ! command -v fail2ban-client &>/dev/null; then
  echo "[+] Устанавливаем fail2ban..." | tee -a "$LOG"
  apt install fail2ban -y
fi
systemctl enable --now fail2ban
echo "[✓] fail2ban работает" | tee -a "$LOG"

# === RKHUNTER ===
if ! command -v rkhunter &>/dev/null; then
  echo "[+] Устанавливаем rkhunter..." | tee -a "$LOG"
  apt install rkhunter -y
fi
rkhunter --update
rkhunter --propupd
echo "[✓] rkhunter обновлён и проиндексирован" | tee -a "$LOG"

# === PSAD ===
if ! command -v psad &>/dev/null; then
  echo "[+] Устанавливаем psad..." | tee -a "$LOG"
  apt install psad -y
fi
iptables -A INPUT -j LOG
iptables -A FORWARD -j LOG
systemctl enable --now psad
psad --sig-update
echo "[✓] psad активирован и отслеживает сканирование портов" | tee -a "$LOG"

# === Уведомление в Telegram об успешной установке ===
send_telegram "🛡️ Сервер *успешно защищён*! Активированы:\n- UFW\n- Fail2Ban\n- PSAD\n- RKHunter"
echo "✅ Уведомление отправлено в Telegram." | tee -a "$LOG"

# === Уведомление при SSH-входе ===
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
curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
  -d chat_id="\${CHAT_ID}" \\
  -d parse_mode="Markdown" \\
  -d text="\${MESSAGE}" > /dev/null
EOF

chmod +x /etc/profile.d/notify_login.sh
echo "[✓] Уведомление при SSH-входе настроено" | tee -a "$LOG"

# === Создание скрипта очистки лога ===
echo "[+] Создаём скрипт очистки логов..." | tee -a "$LOG"

tee /usr/local/bin/clear_security_log.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
echo "\$(date '+%Y-%m-%d %H:%M:%S') | 🧹 Очистка лога безопасности (еженедельно)" > "\$LOG_FILE"
EOF

chmod +x /usr/local/bin/clear_security_log.sh

# === Добавление в root crontab ===
echo "[+] Настраиваем crontab..." | tee -a "$LOG"

( crontab -l 2>/dev/null; echo "0 6 * * * /usr/local/bin/security_monitor.sh" ) | crontab -
( crontab -l 2>/dev/null; echo "0 5 * * 0 /usr/local/bin/clear_security_log.sh" ) | sort -u | crontab -

echo "[✓] Crontab обновлён" | tee -a "$LOG"

# === Финал ===
send_telegram "📬 Настроены:\n- Уведомления при входе\n- Очистка логов\n- Cron-задачи активны"
echo "🚀 Всё готово!" | tee -a "$LOG"
