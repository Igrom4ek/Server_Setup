#!/bin/bash
set -e

export DEBIAN_FRONTEND=noninteractive

# === secure_install.sh ===
# : fail2ban, psad, rkhunter, ufw, Telegram, cron

CONFIG_FILE="/usr/local/bin/config.json"
LOG="/var/log/security_setup.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

[[ ! -f "$CONFIG_FILE" ]] && echo " $CONFIG_FILE  " && exit 1

BOT_TOKEN=$(jq -r '.telegram_bot_token' "$CONFIG_FILE")
CHAT_ID=$(jq -r '.telegram_chat_id' "$CONFIG_FILE")
LABEL=$(jq -r '.telegram_server_label' "$CONFIG_FILE")
CLEAR_LOG_CRON=$(jq -r '.clear_logs_cron' "$CONFIG_FILE")
SECURITY_CHECK_CRON=$(jq -r '.security_check_cron' "$CONFIG_FILE")

log "   ..."

#   ( )
for SERVICE in ufw fail2ban psad rkhunter nmap; do
  if [[ "$(jq -r ".services.$SERVICE" "$CONFIG_FILE")" == "true" ]]; then
    log " $SERVICE..."
    apt install -y "$SERVICE"
    [[ "$SERVICE" != "rkhunter" ]] && systemctl enable --now "$SERVICE" || true
  else
    log "$SERVICE   config.json"
  fi
done

# ===  security_monitor.sh ===
cat > /usr/local/bin/security_monitor.sh <<EOF
#!/bin/bash
LOG="/var/log/security_monitor.log"
BOT_TOKEN="$BOT_TOKEN"
CHAT_ID="$CHAT_ID"
LABEL="$LABEL"

send() {
  curl -s -X POST "https://api.telegram.org/bot\$BOT_TOKEN/sendMessage" \
    -d chat_id="\$CHAT_ID" \
    -d parse_mode="Markdown" \
    -d text="\$1%0A*Server:* \\`\$LABEL\\`" > /dev/null
}

echo "\$(date '+%F %T') |   " >> "\$LOG"

if command -v rkhunter &>/dev/null; then
  RKHUNTER_RESULT=\$(rkhunter --configfile /etc/rkhunter.conf --check --sk --nocolors --rwo 2>/dev/null || true)
  [[ -n "\$RKHUNTER_RESULT" ]] && send " *RKHunter  :*%0A\`\`\`\$RKHUNTER_RESULT\`\`\`"
fi

if command -v psad &>/dev/null; then
  PSAD_RESULT=\$(grep "Danger level" /var/log/psad/alert | tail -n 5 || true)
  [[ -n "\$PSAD_RESULT" ]] && send " *PSAD :*%0A\`\`\`\$PSAD_RESULT\`\`\`"
fi

echo "\$(date '+%F %T') |  " >> "\$LOG"
EOF

chmod +x /usr/local/bin/security_monitor.sh

# === clear_security_log.sh ===
cat > /usr/local/bin/clear_security_log.sh <<EOF
#!/bin/bash
echo "\$(date '+%F %T') |  " > /var/log/security_monitor.log
EOF
chmod +x /usr/local/bin/clear_security_log.sh

# === notify_login.sh (telegram) ===
cat > /etc/profile.d/notify_login.sh <<'EOF'
#!/bin/bash
BOT_TOKEN="'"$BOT_TOKEN"'"
CHAT_ID="'"$CHAT_ID"'"
LABEL="'"$LABEL"'"
USER_NAME=$(whoami)
IP_ADDR=$(who | awk '{print $5}' | sed 's/[()]//g')
HOSTNAME=$(hostname)
LOGIN_TIME=$(date "+%Y-%m-%d %H:%M:%S")
MESSAGE=" SSH : *$USER_NAME*%0A $HOSTNAME%0A $LOGIN_TIME%0A IP: \`$IP_ADDR\`%0A*Server:* \`$LABEL\`"
curl -s -X POST "https://api.telegram.org/bot$BOT_TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d parse_mode="Markdown" \
  -d text="$MESSAGE" > /dev/null
EOF
chmod +x /etc/profile.d/notify_login.sh

# ===  systemd  telegram_command_listener ===
cat > /etc/systemd/system/telegram_command_listener.service <<EOF
[Unit]
Description=Telegram Command Listener
After=network.target

[Service]
ExecStart=/usr/local/bin/telegram_command_listener.sh
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reexec
systemctl daemon-reload
systemctl enable --now telegram_command_listener.service

# ===  cron- ===
TEMP_CRON=$(mktemp)
crontab -l 2>/dev/null > "$TEMP_CRON" || true
grep -v 'security_monitor\|clear_security_log' "$TEMP_CRON" > "${TEMP_CRON}.new"
echo "$SECURITY_CHECK_CRON /usr/local/bin/security_monitor.sh" >> "${TEMP_CRON}.new"
echo "$CLEAR_LOG_CRON /usr/local/bin/clear_security_log.sh" >> "${TEMP_CRON}.new"
crontab "${TEMP_CRON}.new"
rm -f "$TEMP_CRON" "${TEMP_CRON}.new"

log "   "

# === Настройка iptables для логирования ===
iptables -C INPUT -j LOG 2>/dev/null || iptables -A INPUT -j LOG
iptables -C FORWARD -j LOG 2>/dev/null || iptables -A FORWARD -j LOG

# === Настройка rsyslog для psad ===
if ! grep -q "psad" /etc/rsyslog.conf; then
  echo ":msg, contains, \"psad\" /var/log/psad/alert" | tee -a /etc/rsyslog.conf
  echo "& stop" | tee -a /etc/rsyslog.conf
fi
systemctl restart rsyslog

# === Настройка psad.conf ===
if grep -q "IPT_SYSLOG_FILE" /etc/psad/psad.conf; then
  sed -i "s|^IPT_SYSLOG_FILE.*|IPT_SYSLOG_FILE             /var/log/kern.log;|" /etc/psad/psad.conf
fi
systemctl restart psad
