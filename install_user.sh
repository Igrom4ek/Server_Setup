#!/bin/bash
set -e

CONFIG_FILE="/usr/local/bin/config.json"
PUBKEY=$(jq -r '.public_key_content' "$CONFIG_FILE")
PORT=$(jq -r '.port' "$CONFIG_FILE")
SSH_DISABLE_ROOT=$(jq -r '.ssh_disable_root' "$CONFIG_FILE")
SSH_PASSWORD_AUTH=$(jq -r '.ssh_password_auth' "$CONFIG_FILE")
SUDO_NOPASSWD=$(jq -r '.sudo_nopasswd' "$CONFIG_FILE")
MONITORING_ENABLED=$(jq -r '.monitoring_enabled' "$CONFIG_FILE")
# Новые переменные для Telegram-бота (токен и чат ID из config.json)
BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")

USERNAME=$(whoami)
USER_HOME_DIR=$(getent passwd "$USERNAME" | cut -d: -f6)

# Функция логгирования
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1"
}

# 1. Настройка пользователя и SSH
log "📁 Создание ~/.ssh и настройка ключей"
mkdir -p ~/.ssh && chmod 700 ~/.ssh
touch ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys

log "🔑 Установка публичного SSH-ключа"
echo "$PUBKEY" > ~/.ssh/authorized_keys

log "🛠 Настройка /etc/ssh/sshd_config"
sudo sed -i "s/^#\?Port .*/Port $PORT/" /etc/ssh/sshd_config
if [[ "$SSH_DISABLE_ROOT" == "true" ]]; then
  sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" /etc/ssh/sshd_config
fi
if [[ "$SSH_PASSWORD_AUTH" == "false" ]]; then
  sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" /etc/ssh/sshd_config
fi

log "🔄 Перезапуск SSH"
sudo service ssh restart

log "🔓 Настройка sudo без пароля (если предусмотрено)"
if [[ "$SUDO_NOPASSWD" == "true" ]]; then
  echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo tee "/etc/sudoers.d/90-$USERNAME" > /dev/null
  sudo chmod 440 "/etc/sudoers.d/90-$USERNAME"
fi

log "✅ Настройка пользователя завершена. Переходим к настройке безопасности и бота"

# 2. Системная защита: установка и активация сервисов
log "🛡 Установка и настройка системной защиты"
for SERVICE in ufw fail2ban psad rkhunter nmap; do
  if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
    sudo apt install -y "$SERVICE"
    if systemctl list-unit-files | grep -q "^$SERVICE.service"; then
      sudo systemctl enable --now "$SERVICE"
      log "$SERVICE активирован"
    else
      log "$SERVICE не использует systemd — пропущено"
    fi
  else
    log "$SERVICE отключён в config.json"
  fi
done

log "📦 Настройка rkhunter"
sudo rkhunter --propupd || true
# Создание и активация сервиса для регулярной проверки rkhunter
sudo tee /etc/systemd/system/rkhunter.service > /dev/null <<EOF
[Unit]
Description=Rootkit Hunter Service
After=network.target

[Service]
ExecStart=/usr/bin/rkhunter --cronjob --rwo
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now rkhunter.service
# Ежедневный запуск rkhunter через cron (1:00 ночи)
echo "0 1 * * * root /usr/bin/rkhunter --check --cronjob --rwo" | sudo tee /etc/cron.d/rkhunter-daily > /dev/null

# 3. Проверка и установка Docker + Portainer
log "🐳 Проверка Docker и Portainer"
if ! command -v docker &> /dev/null; then
  log "Docker не найден, выполняется установка Docker..."
  sudo apt update -y
  sudo apt install -y docker.io || log "⚠️ Не удалось установить Docker"
  sudo systemctl enable --now docker && log "Docker запущен"
else
  log "Docker уже установлен"
fi

if command -v docker &> /dev/null; then
  if ! sudo docker container inspect portainer &> /dev/null; then
    log "Portainer не установлен, запускается установка Portainer..."
    sudo docker volume create portainer_data > /dev/null || true
    sudo docker run -d -p 8000:8000 -p 9443:9443 --name portainer --restart=always \
      -v /var/run/docker.sock:/var/run/docker.sock -v portainer_data:/data \
      portainer/portainer-ce:lts || log "⚠️ Не удалось запустить Portainer"
    if sudo docker ps -q -f name=portainer &> /dev/null; then
      log "Portainer установлен (Web UI: https://$(hostname -I | awk '{print $1}'):9443)"
    fi
  else
    # Если контейнер существует, убедимся, что он запущен
    if ! sudo docker ps -q -f name=portainer > /dev/null; then
      sudo docker start portainer && log "Portainer запущен" || log "⚠️ Portainer установлен, но не удалось запустить"
    fi
    log "Portainer уже установлен"
  fi
fi

# 4. Установка Netdata (в Docker, если не установлена нативно)
if [[ "$MONITORING_ENABLED" == "true" ]]; then
  log "📊 Установка системы мониторинга Netdata"
  if command -v netdata &> /dev/null; then
    log "Netdata уже установлена в системе, пропускаем установку Docker-версии"
  elif ! sudo docker container inspect netdata &> /dev/null; then
    log "Netdata не найдена, развёртывание Netdata в Docker..."
    sudo docker run -d --name=netdata \
      --hostname="$(hostname)" \
      --pid=host \
      --network=host \
      -v netdataconfig:/etc/netdata \
      -v netdatalib:/var/lib/netdata \
      -v netdatacache:/var/cache/netdata \
      -v /etc/passwd:/host/etc/passwd:ro \
      -v /etc/group:/host/etc/group:ro \
      -v /etc/os-release:/host/etc/os-release:ro \
      -v /proc:/host/proc:ro \
      -v /sys:/host/sys:ro \
      -v /var/run/docker.sock:/var/run/docker.sock:ro \
      --restart unless-stopped \
      --cap-add SYS_PTRACE --cap-add SYS_ADMIN \
      --security-opt apparmor=unconfined \
      netdata/netdata || log "⚠️ Не удалось запустить Netdata в Docker"
  else
    log "Контейнер Netdata уже существует"
  fi
else
  log "Мониторинг Netdata отключён в config.json"
fi

# 5. Установка и настройка Telegram-бота
log "🤖 Установка и настройка Telegram-бота"
sudo tee /usr/local/bin/telegram_command_listener.sh > /dev/null <<EOF
#!/bin/bash
export HOME="$USER_HOME_DIR"
TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
OFFSET_FILE="\$HOME/.cache/telegram_bot_offset"
LAST_COMMAND_FILE="\$HOME/.cache/telegram_last_command"
REBOOT_FLAG_FILE="\$HOME/.cache/telegram_confirm_reboot"
LOG_FILE="/tmp/bot_debug.log"

mkdir -p "\$(dirname "\$OFFSET_FILE")"
exec >>"\$LOG_FILE" 2>&1
set -x

OFFSET=\$(cat "\$OFFSET_FILE" 2>/dev/null || echo 0)

send_message() {
  local text="\$1"
  curl -s -X POST "https://api.telegram.org/bot\${TOKEN}/sendMessage" \
    --data-urlencode chat_id="\${CHAT_ID}" \
    --data-urlencode parse_mode="Markdown" \
    --data-urlencode text="\${text}" > /dev/null
}

get_updates() {
  curl -s "https://api.telegram.org/bot\$TOKEN/getUpdates?offset=\$OFFSET"
}

while true; do
  RESPONSE=\$(get_updates)
  UPDATES=\$(echo "\$RESPONSE" | jq -c '.result')
  LENGTH=\$(echo "\$UPDATES" | jq 'length')
  [[ "\$LENGTH" -eq 0 ]] && sleep 2 && continue

  for ((i = 0; i < \$LENGTH; i++)); do
    UPDATE=\$(echo "\$UPDATES" | jq -c ".[\$i]")
    UPDATE_ID=\$(echo "\$UPDATE" | jq '.update_id')
    MESSAGE=\$(echo "\$UPDATE" | jq -r '.message.text')
    OFFSET=\$((UPDATE_ID + 1))
    echo "\$OFFSET" > "\$OFFSET_FILE"

    NOW=\$(date +%s)
    LAST_CMD=\$(cat "\$LAST_COMMAND_FILE" 2>/dev/null || echo "0")
    DIFF=\$((NOW - LAST_CMD))
    [[ "\$DIFF" -lt 3 ]] && continue
    echo "\$NOW" > "\$LAST_COMMAND_FILE"

    case "\$MESSAGE" in
      /help | help)
        send_message "*Команды:*
/uptime — аптайм
/disk — информация о диске
/mem — использование памяти
/top — топ процессов
/who — активные сессии пользователей
/ip — внутренний и внешний IP + геолокация
/security — проверка системы (rkhunter, psad)
/reboot — перезагрузка сервера
/confirm_reboot — подтвердить перезагрузку
/restart_bot — перезапуск бота
/botlog — последние логи бота"
        ;;
      /uptime)
        send_message "*Аптайм:* \$(uptime -p)"
        ;;
      /disk)
        send_message "\`\`\`
\$(df -h /)
\`\`\`"
        ;;
      /mem)
        send_message "\`\`\`
\$(free -h)
\`\`\`"
        ;;
      /top)
        send_message "\`\`\`
\$(ps -eo pid,ppid,cmd,%mem,%cpu --sort=-%cpu | head -n 10)
\`\`\`"
        ;;
      /who)
        WHO_WITH_GEO=""
        while read -r user tty date time ip; do
          IP_ADDR=\$(echo "\$ip" | tr -d '()')
          GEO=\$(curl -s ipinfo.io/\$IP_ADDR | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
          WHO_WITH_GEO+="👤 \$user — \$IP_ADDR
🌍 \$GEO

"
        done <<< "\$(who | awk '{print \$1, \$2, \$3, \$4, \$5}')"
        send_message "*Сессии пользователей:*

\$WHO_WITH_GEO"
        ;;
      /ip)
        IP_INT=\$(hostname -I | awk '{print \$1}')
        IP_EXT=\$(curl -s ifconfig.me)
        GEO=\$(curl -s ipinfo.io/\$IP_EXT | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
        send_message "*Внутренний IP:* \`\$IP_INT\`
*Внешний IP:* \`\$IP_EXT\`
🌍 *Геолокация:* \$GEO"
        ;;
      /security)
        send_message "⏳ Выполняется проверка безопасности (rkhunter, psad)..."
        echo "[BOT] Запускается rkhunter..." >> "\$LOG_FILE"
        OUT=\$(timeout 30s sudo rkhunter --check --sk --nocolors --rwo)
        EXIT_CODE=\$?
        if [[ "\$EXIT_CODE" -eq 124 ]]; then
          RKHUNTER_RESULT="⚠️ rkhunter не ответил за 30 секунд"
        else
          RKHUNTER_RESULT=\$(echo "\$OUT" | tail -n 100)
        fi
        if [[ -f /var/log/psad/alert ]]; then
          PSAD_RESULT=\$(grep "Danger level" /var/log/psad/alert | tail -n 5)
          [[ -z "\$PSAD_RESULT" ]] && PSAD_RESULT="psad лог пуст"
        else
          PSAD_RESULT="psad лог отсутствует"
        fi
        PSAD_STATUS=\$(sudo psad -S | head -n 20 || echo "Ошибка запуска psad -S")
        TOP_IPS=\$(sudo grep -i "Danger level" /var/log/psad/alert | tail -n 10 || echo "")
        [[ -z "\$TOP_IPS" ]] && TOP_IPS="Нет записей о сканированиях."

        send_message "*RKHunter (последние строки):*
\`\`\`
\$RKHUNTER_RESULT
\`\`\`

*PSAD:*
\`\`\`
\$PSAD_RESULT
\`\`\`"
        send_message "*Статус PSAD:*
\`\`\`
\$PSAD_STATUS
\`\`\`"
        send_message "*Топ 10 IP-адресов (PSAD):*
\`\`\`
\$TOP_IPS
\`\`\`"
        ;;
      /reboot)
        echo "1" > "\$REBOOT_FLAG_FILE"
        send_message "⚠️ Подтвердите перезагрузку сервера командой */confirm_reboot*"
        ;;
      /confirm_reboot)
        if [[ -f "\$REBOOT_FLAG_FILE" ]]; then
          send_message "♻️ Перезагрузка сервера..."
          rm -f "\$REBOOT_FLAG_FILE"
          sleep 2
          sudo reboot
        else
          send_message "Нет активного запроса на перезагрузку."
        fi
        ;;
      /restart_bot)
        send_message "🔄 Перезапуск Telegram-бота..."
        sleep 1
        sudo systemctl restart telegram_command_listener.service
        exit 0
        ;;
      /botlog)
        LOG=\$(tail -n 30 "\$LOG_FILE" 2>/dev/null || echo "Лог отсутствует.")
        send_message "*Лог бота:*
\`\`\`
\$LOG
\`\`\`"
        ;;
      *)
        send_message "Неизвестная команда. Напишите /help для списка."
        ;;
    esac
  done
  sleep 2
done
EOF

sudo chmod +x /usr/local/bin/telegram_command_listener.sh

# Создание systemd unit для бота
sudo tee /etc/systemd/system/telegram_command_listener.service > /dev/null <<EOF
[Unit]
Description=Telegram Command Listener Bot Service
After=network.target

[Service]
ExecStart=/usr/local/bin/telegram_command_listener.sh
Restart=always
User=$USERNAME

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now telegram_command_listener.service

# Уведомления о SSH-подключениях через PAM
log "🔔 Настройка уведомлений о входе по SSH"
sudo tee /usr/local/bin/telegram_ssh_notify.sh > /dev/null <<EOF
#!/bin/bash
[[ "\$PAM_TYPE" != "open_session" ]] && exit 0
[[ -z "\$PAM_USER" || "\$PAM_USER" == "sshd" ]] && exit 0

TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"

USER="\$PAM_USER"
IP=\$(echo \$SSH_CONNECTION | awk '{print \$1}')
CACHE_FILE="/tmp/ssh_notify_\${USER}_\${IP}"

# Если уже отправляли уведомление за последние 10 секунд — пропускаем
if [[ -f "\$CACHE_FILE" ]]; then
  LAST_TIME=\$(cat "\$CACHE_FILE")
  NOW=\$(date +%s)
  DIFF=\$((NOW - LAST_TIME))
  if [[ "\$DIFF" -lt 10 ]]; then
    exit 0
  fi
fi

date +%s > "\$CACHE_FILE"

GEO=\$(curl -s ipinfo.io/\$IP | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
TEXT="🔐 SSH вход: *\$USER*
📡 IP: \`\$IP\`
🌍 Местоположение: \$GEO
🕒 Время: \$(date +'%Y-%m-%d %H:%M:%S')"

curl -s -X POST "https://api.telegram.org/bot\$TOKEN/sendMessage" \
  -d chat_id="\$CHAT_ID" -d parse_mode="Markdown" -d text="\$TEXT" > /dev/null
EOF

sudo chmod +x /usr/local/bin/telegram_ssh_notify.sh

# Подключение скрипта к PAM
if ! grep -q "telegram_ssh_notify.sh" /etc/pam.d/sshd; then
  echo "session optional pam_exec.so /usr/local/bin/telegram_ssh_notify.sh" | sudo tee -a /etc/pam.d/sshd > /dev/null
fi

# Настройка логирования psad и iptables
log "🧱 Настройка логирования psad и iptables"
sudo iptables -C INPUT -j LOG 2>/dev/null || sudo iptables -A INPUT -j LOG
sudo iptables -C FORWARD -j LOG 2>/dev/null || sudo iptables -A FORWARD -j LOG

if ! grep -q "psad" /etc/rsyslog.conf; then
  echo ':msg, contains, "psad" /var/log/psad/alert' | sudo tee -a /etc/rsyslog.conf > /dev/null
  echo '& stop' | sudo tee -a /etc/rsyslog.conf > /dev/null
  sudo systemctl restart rsyslog
fi

if grep -q "IPT_SYSLOG_FILE" /etc/psad/psad.conf; then
  sudo sed -i "s|^IPT_SYSLOG_FILE.*|IPT_SYSLOG_FILE             /var/log/kern.log;|" /etc/psad/psad.conf
  sudo systemctl restart psad
  log "psad сконфигурирован"
fi

# Настройка sudo для rkhunter (без пароля для вызова ботом)
log "🛡 Настройка sudo для rkhunter (без пароля для бота)"
if ! sudo grep -q "/usr/bin/rkhunter" /etc/sudoers; then
  echo "$USERNAME ALL=(ALL) NOPASSWD: /usr/bin/rkhunter" | sudo tee -a /etc/sudoers > /dev/null
  log "Добавлено правило sudoers для rkhunter"
else
  log "Правило sudoers для rkhunter уже существует — пропущено"
fi

# 6. Финальный чек-лист
log "📬 Финальный чек-лист установки"
CHECKLIST="/tmp/install_checklist.txt"

# Собираем информацию для чек-листа
echo "Чеклист установки:" > "$CHECKLIST"
echo "Пользователь: $USERNAME" >> "$CHECKLIST"
echo "SSH порт: $PORT" >> "$CHECKLIST"
echo "Службы:" >> "$CHECKLIST"
for SERVICE in ufw fail2ban psad rkhunter; do
  sudo systemctl is-active --quiet "$SERVICE" && echo "  [+] $SERVICE" >> "$CHECKLIST" || echo "  [ ] $SERVICE" >> "$CHECKLIST"
done
echo "Telegram-бот: включён" >> "$CHECKLIST"
if command -v docker &> /dev/null; then
  echo "Docker: установлен" >> "$CHECKLIST"
  if sudo docker ps -q -f name=portainer &> /dev/null; then
    echo "Portainer: https://$(hostname -I | awk '{print $1}'):9443" >> "$CHECKLIST"
  else
    echo "Portainer: не запущен" >> "$CHECKLIST"
  fi
else
  echo "Docker: не установлен" >> "$CHECKLIST"
fi
if [[ "$MONITORING_ENABLED" == "true" ]]; then
  if command -v netdata &> /dev/null; then
    echo "Netdata: http://$(hostname -I | awk '{print $1}'):19999 (в системе)" >> "$CHECKLIST"
  elif sudo docker ps -q -f name=netdata &> /dev/null; then
    echo "Netdata: http://$(hostname -I | awk '{print $1}'):19999 (Docker)" >> "$CHECKLIST"
  else
    echo "Netdata: ошибка установки" >> "$CHECKLIST"
  fi
else
  echo "Netdata: отключена" >> "$CHECKLIST"
fi
if [[ "$(jq -r '.services.rkhunter' "$CONFIG_FILE")" == "true" ]]; then
  RKHUNTER_OUTPUT=$(sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
  if [[ -n "$RKHUNTER_OUTPUT" ]]; then
    echo "RKHunter: ОБНАРУЖЕНЫ предупреждения:" >> "$CHECKLIST"
    RKHUNTER_LAST=$(echo "$RKHUNTER_OUTPUT" | tail -n 10)
    echo "$RKHUNTER_LAST" >> "$CHECKLIST"
  else
    echo "RKHunter: OK (нарушений не обнаружено)" >> "$CHECKLIST"
  fi
fi
if [[ "$(jq -r '.services.psad' "$CONFIG_FILE")" == "true" ]]; then
  if [[ -f /var/log/psad/alert ]]; then
    PSAD_ALERTS=$(sudo grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
    if [[ -n "$PSAD_ALERTS" ]]; then
      echo "PSAD: обнаружена подозрительная активность:" >> "$CHECKLIST"
      echo "$PSAD_ALERTS" >> "$CHECKLIST"
    else
      echo "PSAD: OK (подозрительной активности не выявлено)" >> "$CHECKLIST"
    fi
  else
    echo "PSAD: OK (лог пуст)" >> "$CHECKLIST"
  fi
fi

# Выводим чек-лист в терминал
cat "$CHECKLIST"

# Отправляем чек-лист в Telegram
CHECK_MSG=$(sed 's/`/\\`/g' "$CHECKLIST")
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" -d parse_mode="Markdown" \
  --data-urlencode text="\`\`\`$CHECK_MSG\`\`\`" > /dev/null

rm -f "$CHECKLIST"

# 7. Настройка cron-задач (безопасность, обновление, очистка)
log "🕒 Настройка cron-задач: ежедневная проверка, очистка логов, обновления"
# Ежедневная проверка безопасности (rkhunter + psad) с оповещением в Telegram
sudo tee /usr/local/bin/cron_security_check.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"

send_telegram() {
    MESSAGE="\$1"
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" -d chat_id="\${CHAT_ID}" -d parse_mode="Markdown" --data-urlencode text="\${MESSAGE}" > /dev/null
}

timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}
echo "\$(timestamp) | 🚀 Запуск проверки безопасности" >> "\$LOG_FILE"

RKHUNTER_RESULT=\$(sudo rkhunter --check --sk --nocolors --rwo 2>/dev/null || true)
if [ -n "\$RKHUNTER_RESULT" ]; then
    send_telegram "⚠️ *RKHunter обнаружил подозрительные элементы:*\n\`\`\`\n\$RKHUNTER_RESULT\n\`\`\`"
    echo "\$(timestamp) | ⚠️ RKHunter: найдены подозрения" >> "\$LOG_FILE"
else
    send_telegram "✅ *RKHunter*: нарушений не обнаружено"
    echo "\$(timestamp) | ✅ RKHunter: всё чисто" >> "\$LOG_FILE"
fi

PSAD_ALERTS=\$(sudo grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
if echo "\$PSAD_ALERTS" | grep -q "Danger level"; then
    send_telegram "🚨 *PSAD предупреждение:*\n\`\`\`\n\$PSAD_ALERTS\n\`\`\`"
    echo "\$(timestamp) | 🚨 PSAD: найдены угрозы" >> "\$LOG_FILE"
else
    send_telegram "✅ *PSAD*: подозрительной активности не обнаружено"
    echo "\$(timestamp) | ✅ PSAD: всё спокойно" >> "\$LOG_FILE"
fi
echo "\$(timestamp) | ✅ Проверка завершена" >> "\$LOG_FILE"
EOF

sudo chmod +x /usr/local/bin/cron_security_check.sh
echo "0 7 * * * root /usr/local/bin/cron_security_check.sh" | sudo tee /etc/cron.d/cron-security-check > /dev/null

# Еженедельная очистка лога безопасности
sudo tee /usr/local/bin/cron_clear_security_log.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/security_monitor.log"
echo "\$(date '+%Y-%m-%d %H:%M:%S') | Очистка лога безопасности (еженедельно)" > "\$LOG_FILE"
EOF

sudo chmod +x /usr/local/bin/cron_clear_security_log.sh
echo "0 6 * * 1 root /usr/local/bin/cron_clear_security_log.sh" | sudo tee /etc/cron.d/cron-clear-security-log > /dev/null

# Еженедельное обновление системы с отчётом в Telegram
sudo tee /usr/local/bin/cron_weekly_update.sh > /dev/null <<EOF
#!/bin/bash
LOG_FILE="/var/log/weekly_update.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"

send_telegram() {
    local MESSAGE="\$1"
    curl -s -X POST "https://api.telegram.org/bot\${BOT_TOKEN}/sendMessage" \\
         -d chat_id="\${CHAT_ID}" -d parse_mode="Markdown" \\
         --data-urlencode text="\${MESSAGE}" > /dev/null
}

log_and_echo() {
    echo "\$1" | tee -a "\$LOG_FILE"
}

log_and_echo "🕖 ===== \$(date '+%Y-%m-%d %H:%M:%S') | Начало обновления ====="
apt update >> "\$LOG_FILE" 2>&1
apt upgrade -y >> "\$LOG_FILE" 2>&1
apt full-upgrade -y >> "\$LOG_FILE" 2>&1
apt autoremove -y >> "\$LOG_FILE" 2>&1
apt autoclean >> "\$LOG_FILE" 2>&1
log_and_echo "✅ \$(date '+%Y-%m-%d %H:%M:%S') | Обновление завершено"
log_and_echo ""

TAIL_LOG=\$(tail -n 40 "\$LOG_FILE")
send_telegram "🧰 *Еженедельное обновление сервера завершено:*
\`\`\`
\${TAIL_LOG}
\`\`\`"
EOF

sudo chmod +x /usr/local/bin/cron_weekly_update.sh
echo "30 5 * * 1 root /usr/local/bin/cron_weekly_update.sh" | sudo tee /etc/cron.d/cron-weekly-update > /dev/null

log "✅ Установка завершена"
