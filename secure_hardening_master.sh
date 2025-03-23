#!/bin/bash

# === secure_hardening_master.sh ===
# Мастер-скрипт: создаёт и запускает secure_hardening.sh для настройки безопасности и мониторинга

SECURE_SCRIPT="/usr/local/bin/secure_hardening.sh"
LOG_FILE="/var/log/secure_setup.log"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

log "📦 Создаём $SECURE_SCRIPT..."

install -m 755 /dev/stdin "$SECURE_SCRIPT" <<'EOF'
#!/bin/bash
set -e

LOG_FILE="/var/log/secure_setup.log"
CRON_TMP="/tmp/cron_check.txt"
BOT_TOKEN="8019987480:AAEJdUAAiGqlTFjOahWNh3RY5hiEwo3-E54"
CHAT_ID="543102005"
SERVER_IP="77.73.235.118 (Латвия)"

USE_CRON=true
USE_TELEGRAM=true

for arg in "$@"; do
    case $arg in
        --no-cron) USE_CRON=false ;;
        --telegram-off) USE_TELEGRAM=false ;;
    esac
done

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

send_telegram() {
    [[ "$USE_TELEGRAM" == false ]] && return
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
         -d chat_id="${CHAT_ID}" \
         -d parse_mode="Markdown" \
         -d text="🛡 $1\n🌍 Сервер: \`${SERVER_IP}\`" > /dev/null
}

log "🔐 Начинаем установку модулей безопасности"

log "📦 Установка пакетов: fail2ban, psad, rkhunter"
apt install -y fail2ban psad rkhunter curl wget net-tools ufw > /dev/null

log "🛡 Настройка fail2ban"
cat > /etc/fail2ban/jail.local <<EOL
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOL

systemctl enable fail2ban
systemctl restart fail2ban

log "🔥 Настройка UFW"
ufw allow ssh
ufw enable

log "🔍 Настройка PSAD"
sed -i 's/EMAIL_ADDRESSES             all/EMAIL_ADDRESSES             root/' /etc/psad/psad.conf
psad --sig-update
psad -H
systemctl restart psad
systemctl enable psad

log "🔎 Настройка RKHunter"
rkhunter --update
rkhunter --propupd

log "📊 Установка Netdata"
bash <(curl -Ss https://my-netdata.io/kickstart.sh) >> "$LOG_FILE" 2>&1
log "✅ Установка Netdata завершена. Доступ: http://<ip>:19999"

# === Настройка logrotate для security_monitor.log ===
log "🔁 Настройка logrotate для /var/log/security_monitor.log"
cat > /etc/logrotate.d/security_monitor <<EOL
/var/log/security_monitor.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 640 root adm
}
EOL

# === Мониторинг и очистка логов ===
install -m 755 /dev/stdin "/usr/local/bin/security_monitor.sh" <<'EOM'
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
BOT_TOKEN="8019987480:AAEJdUAAiGqlTFjOahWNh3RY5hiEwo3-E54"
CHAT_ID="543102005"

send_telegram() {
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d parse_mode="Markdown" \
        -d text="$1" > /dev/null
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

echo "$(timestamp) | 🚀 Проверка безопасности" >> "$LOG_FILE"

RKHUNTER_RESULT=$(rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
if [ -n "$RKHUNTER_RESULT" ]; then
    send_telegram "⚠️ *RKHunter нашёл подозрительные элементы:*\n\`\`\`\n$RKHUNTER_RESULT\n\`\`\`\n🌍 Сервер: \`77.73.235.118 (Латвия)\`"
else
    send_telegram "✅ *RKHunter*: нарушений не обнаружено\n🌍 Сервер: \`77.73.235.118 (Латвия)\`"
fi

PSAD_ALERTS=$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
if echo "$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "🚨 *PSAD предупреждение:*\n\`\`\`\n$PSAD_ALERTS\n\`\`\`\n🌍 Сервер: \`77.73.235.118 (Латвия)\`"
else
    send_telegram "✅ *PSAD*: подозрительной активности не обнаружено\n🌍 Сервер: \`77.73.235.118 (Латвия)\`"
fi

echo "$(timestamp) | ✅ Проверка завершена" >> "$LOG_FILE"
EOM

install -m 755 /dev/stdin "/usr/local/bin/clear_security_log.sh" <<'EOM'
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') | 🧹 Очистка лога безопасности" > "$LOG_FILE"
EOM

if \$USE_CRON; then
  log "⏱ Добавляем cron-задачи"
  (crontab -l 2>/dev/null; echo "0 6 * * * /usr/local/bin/security_monitor.sh") | sort -u | crontab -
  (crontab -l 2>/dev/null; echo "0 5 * * 0 /usr/local/bin/clear_security_log.sh") | sort -u | crontab -
fi

log "✅ Все компоненты безопасности установлены"
send_telegram "✅ Защита сервера успешно настроена!"
EOF

log "🚀 Запускаем secure_hardening.sh..."
sudo "$SECURE_SCRIPT" "$@"

log "🏁 Установка завершена."
