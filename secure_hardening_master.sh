#!/bin/bash

# === secure_hardening_master.sh ===
# Мастер-скрипт: создаёт и запускает secure_hardening.sh для настройки безопасности и мониторинга

CONFIG_FILE="/usr/local/bin/config.json"
SECURE_SCRIPT="/usr/local/bin/secure_hardening.sh"
LOG_FILE="/var/log/secure_setup.log"

if ! command -v jq &>/dev/null; then
  echo "❌ Требуется jq. Установите: sudo apt install jq -y"
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "❌ Не найден конфигурационный файл: $CONFIG_FILE"
  exit 1
fi

BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")
SERVER_IP=$(jq -r '.telegram_server_label' "$CONFIG_FILE")
SECURITY_CRON=$(jq -r '.security_check_cron // "0 6 * * *"' "$CONFIG_FILE")
CLEAR_LOG_CRON=$(jq -r '.clear_logs_cron // "0 5 * * 0"' "$CONFIG_FILE")

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

log "📦 Создаём $SECURE_SCRIPT..."

install -m 755 /dev/stdin "$SECURE_SCRIPT" <<EOF
#!/bin/bash
set -e

LOG_FILE="/var/log/secure_setup.log"
CRON_TMP="/tmp/cron_check.txt"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
SERVER_IP="$SERVER_IP"

USE_CRON=true
USE_TELEGRAM=true

for arg in "\$@"; do
    case \$arg in
        --no-cron) USE_CRON=false ;;
        --telegram-off) USE_TELEGRAM=false ;;
    esac
done

log() {
    echo "\$(date '+%Y-%m-%d %H:%M:%S') | \$1" | tee -a "\$LOG_FILE"
}

send_telegram() {
    [[ "\$USE_TELEGRAM" == false ]] && return
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \
         -d chat_id="\${CHAT_ID}" \
         -d parse_mode="Markdown" \
         -d text="🛡 \$1\n🌍 Сервер: \\`\${SERVER_IP}\\`" > /dev/null
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
bash <(curl -Ss https://my-netdata.io/kickstart.sh) >> "\$LOG_FILE" 2>&1
log "✅ Установка Netdata завершена. Доступ: http://<ip>:19999"

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

install -m 755 /dev/stdin "/usr/local/bin/security_monitor.sh" <<EOM
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
SERVER_IP="$SERVER_IP"

send_telegram() {
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \
        -d chat_id="\${CHAT_ID}" \
        -d parse_mode="Markdown" \
        -d text="\$1\n🌍 Сервер: \\`\${SERVER_IP}\\`" > /dev/null
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

echo "\$(timestamp) | 🚀 Проверка безопасности" >> "\$LOG_FILE"

RKHUNTER_RESULT=\$(rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
if [ -n "\$RKHUNTER_RESULT" ]; then
    send_telegram "⚠️ *RKHunter нашёл подозрительные элементы:*
\\`\\`\\`
\$RKHUNTER_RESULT
\\`\\`\\`"
else
    send_telegram "✅ *RKHunter*: нарушений не обнаружено"
fi

PSAD_ALERTS=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
if echo "\$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "🚨 *PSAD предупреждение:*
\\`\\`\\`
\$PSAD_ALERTS
\\`\\`\\`"
else
    send_telegram "✅ *PSAD*: подозрительной активности не обнаружено"
fi

echo "\$(timestamp) | ✅ Проверка завершена" >> "\$LOG_FILE"
EOM

install -m 755 /dev/stdin "/usr/local/bin/clear_security_log.sh" <<EOM
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
echo "\$(date '+%Y-%m-%d %H:%M:%S') | 🧹 Очистка лога безопасности" > "\$LOG_FILE"
EOM

if \$USE_CRON; then
  log "⏱ Добавляем cron-задачи"
  (crontab -l 2>/dev/null; echo "$SECURITY_CRON /usr/local/bin/security_monitor.sh") | sort -u | crontab -
  (crontab -l 2>/dev/null; echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh") | sort -u | crontab -
fi

log "✅ Все компоненты безопасности установлены"
send_telegram "✅ Защита сервера успешно настроена!"
EOF

log "🚀 Запускаем secure_hardening.sh..."
sudo "$SECURE_SCRIPT" "$@"

log "🏁 Установка завершена."