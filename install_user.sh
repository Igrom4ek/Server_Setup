#!/bin/bash
set -e

LOG="/home/$USER/install_user.log"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG"
}

log "👤 [USER] Установка компонентов от имени $USER"

# Здесь ты можешь продолжить установку:
# - Netdata
# - Telegram listener
# - настройка shell окружения
# - anything user-local
