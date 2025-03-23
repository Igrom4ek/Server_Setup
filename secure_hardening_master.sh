#!/bin/bash

# === secure_hardening_master.sh ===
# Мастер-скрипт: создаёт и запускает secure_hardening.sh для настройки безопасности и мониторинга

CONFIG_FILE="/usr/local/bin/config.json"
SECURE_SCRIPT="/usr/local/bin/secure_hardening.sh"
LOG_FILE="/var/log/secure_setup.log"

# Проверка наличия jq
if ! command -v jq &>/dev/null; then
  echo "ERROR: Требуется jq. Установите: sudo apt install jq -y" | tee -a "$LOG_FILE"
  exit 1
fi

# Проверка наличия конфигурационного файла
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "ERROR: Не найден конфигурационный файл: $CONFIG_FILE" | tee -a "$LOG_FILE"
  exit 1
fi

# Извлечение параметров из config.json
BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")
SERVER_IP=$(jq -r '.telegram_server_label' "$CONFIG_FILE")
SECURITY_CRON=$(jq -r '.security_check_cron // "0 6 * * *"' "$CONFIG_FILE")
CLEAR_LOG_CRON=$(jq -r '.clear_logs_cron // "0 5 * * 0"' "$CONFIG_FILE")

# Функция логирования
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

log "Создание $SECURE_SCRIPT..."

# Создание скрипта secure_hardening.sh
cat > "$SECURE_SCRIPT" << 'END_OF_SCRIPT'
#!/bin/bash
set -e

LOG_FILE="/var/log/secure_setup.log"
BOT_TOKEN="BOTTOKEN"
CHAT_ID="CHATID"
SERVER_IP="SERVERIP"

USE_CRON=true
USE_TELEGRAM=true

# Обработка аргументов
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
         -d text="$1
Server: \`${SERVER_IP}\`" > /dev/null
}

log "Установка модулей безопасности"

log "Установка пакетов: fail2ban, psad, rkhunter"
apt update
apt install -y fail2ban psad rkhunter curl wget net-tools ufw > /dev/null 2>&1

log "Настройка SSH"
sed -i 's/^\#PermitRootLogin.*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl restart sshd

log "Настройка fail2ban"
cat > /etc/fail2ban/jail.local <<'EOL'
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

log "Настройка UFW"
ufw allow ssh
ufw --force enable

log "Настройка PSAD"
sed -i 's/EMAIL_ADDRESSES\s\+all/EMAIL_ADDRESSES root/' /etc/psad/psad.conf
psad --sig-update
psad -H
systemctl restart psad
systemctl enable psad

log "Настройка RKHunter"
rkhunter --update
rkhunter --propupd

log "Настройка logrotate для /var/log/security_monitor.log"
cat > /etc/logrotate.d/security_monitor <<'EOL'
/var/log/security_monitor.log {
    weekly
    rotate 4
    compress
    missingok
    notifempty
    create 640 root adm
}
EOL

cat > /usr/local/bin/security_monitor.sh << 'EOM'
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
BOT_TOKEN="BOTTOKEN"
CHAT_ID="CHATID"
SERVER_IP="SERVERIP"

send_telegram() {
    curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
        -d chat_id="${CHAT_ID}" \
        -d parse_mode="Markdown" \
        -d text="$1
Server: \`${SERVER_IP}\`" > /dev/null
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

echo "$(timestamp) | Security check started" >> "$LOG_FILE"

RKHUNTER_RESULT=$(rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
if [ -n "$RKHUNTER_RESULT" ]; then
    send_telegram "RKHunter Warning:
\`\`\`
$RKHUNTER_RESULT
\`\`\`"
else
    send_telegram "RKHunter: OK — no threats found."
fi

PSAD_ALERTS=$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
if echo "$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "PSAD Alert:
\`\`\`
$PSAD_ALERTS
\`\`\`"
else
    send_telegram "PSAD: No suspicious activity."
fi

echo "$(timestamp) | Security check finished" >> "$LOG_FILE"
EOM

cat > /usr/local/bin/clear_security_log.sh << 'EOM'
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') | Log cleared" > "$LOG_FILE"
EOM

chmod +x /usr/local/bin/security_monitor.sh
chmod +x /usr/local/bin/clear_security_log.sh

if $USE_CRON; then
  log "Настройка cron-задач"
  TEMP_CRON=$(mktemp)
  crontab -l > "$TEMP_CRON" 2>/dev/null || echo "" > "$TEMP_CRON"
  grep -v "security_monitor.sh" "$TEMP_CRON" > "${TEMP_CRON}.new"
  grep -v "clear_security_log.sh" "${TEMP_CRON}.new" > "$TEMP_CRON"
  echo "SECURITY_CRON_PLACEHOLDER /usr/local/bin/security_monitor.sh" >> "$TEMP_CRON"
  echo "CLEAR_LOG_CRON_PLACEHOLDER /usr/local/bin/clear_security_log.sh" >> "$TEMP_CRON"
  crontab "$TEMP_CRON"
  rm -f "$TEMP_CRON" "${TEMP_CRON}.new"
fi

log "Установка безопасности завершена"
send_telegram "Сервер успешно защищён."
END_OF_SCRIPT

# Замена плейсхолдеров на реальные значения
sed -i "s/BOTTOKEN/$BOT_TOKEN/g" "$SECURE_SCRIPT"
sed -i "s/CHATID/$CHAT_ID/g" "$SECURE_SCRIPT"
sed -i "s/SERVERIP/$SERVER_IP/g" "$SECURE_SCRIPT"
sed -i "s/SECURITY_CRON_PLACEHOLDER/$SECURITY_CRON/g" "$SECURE_SCRIPT"
sed -i "s/CLEAR_LOG_CRON_PLACEHOLDER/$CLEAR_LOG_CRON/g" "$SECURE_SCRIPT"

# Установка прав доступа
chmod +x "$SECURE_SCRIPT"

log "Установка Netdata..."
bash -c "$(curl -Ss https://my-netdata.io/kickstart.sh)" >> "$LOG_FILE" 2>&1
if [[ $? -eq 0 ]]; then
  log "Netdata установлена. Доступ по порту 19999"
else
  log "Ошибка при установке Netdata"
fi

log "Запуск secure_hardening.sh..."
"$SECURE_SCRIPT" "$@"

log "Готово!"