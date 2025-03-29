#!/bin/bash

[[ "$PAM_TYPE" != "open_session" ]] && exit 0
[[ -z "$PAM_USER" || "$PAM_USER" == "sshd" ]] && exit 0

TOKEN="8019987480:AAEJdUAAiGqlTFjOahWNh3RY5hiEwo3-E54"
CHAT_ID="543102005"

USER="$PAM_USER"
IP=$(echo $SSH_CONNECTION | awk '{print $1}')
CACHE_FILE="/tmp/ssh_notify_${USER}_${IP}"

# Если уже отправляли уведомление за последние 10 секунд — пропускаем
if [[ -f "$CACHE_FILE" ]]; then
  LAST_TIME=$(cat "$CACHE_FILE")
  NOW=$(date +%s)
  DIFF=$((NOW - LAST_TIME))
  if [[ "$DIFF" -lt 10 ]]; then
    exit 0
  fi
fi

date +%s > "$CACHE_FILE"

GEO=$(curl -s ipinfo.io/$IP | jq -r '.city + ", " + .region + ", " + .country + " (" + .org + ")"')
TEXT="🔐 SSH вход: *$USER*
📡 IP: \`$IP\`
🌍 Местоположение: $GEO
🕒 Время: $(date +'%Y-%m-%d %H:%M:%S')"

curl -s -X POST "https://api.telegram.org/bot$TOKEN/sendMessage" \
  -d chat_id="$CHAT_ID" \
  -d parse_mode="Markdown" \
  -d text="$TEXT"
