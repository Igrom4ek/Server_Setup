#!/bin/bash

# Пути и переменные
SCRIPT_DIR="/usr/local/bin"
LOG_FILE="/var/log/install_docker_netdata.log"

# Функция логирования
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

# Проверка и создание лог-файла
if [[ ! -f "$LOG_FILE" ]]; then
  touch "$LOG_FILE"
  chmod 644 "$LOG_FILE"
fi

log "🚀 Начало установки Docker и Netdata..."

# Установка Docker, если он отсутствует
if ! command -v docker &>/dev/null; then
  log "📦 Docker не найден, устанавливаем..."
  apt update && apt install -y docker.io
  if [[ $? -eq 0 ]]; then
    systemctl enable --now docker
    log "✅ Docker успешно установлен и запущен"
  else
    log "❌ Ошибка при установке Docker"
    exit 1
  fi
else
  log "✅ Docker уже установлен"
fi

# Проверка, запущен ли Docker
if ! systemctl is-active --quiet docker; then
  log "⚠️ Docker не запущен, запускаем..."
  systemctl start docker
fi

# Установка Netdata через Docker
log "📥 Запускаем Netdata в Docker..."
docker run -d --name netdata \
  -p 19999:19999 \
  -v /etc/netdata:/etc/netdata:ro \
  -v /var/lib/netdata:/var/lib/netdata \
  -v /proc:/host/proc:ro \
  -v /sys:/host/sys:ro \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  --cap-add SYS_PTRACE \
  --security-opt apparmor=unconfined \
  netdata/netdata

if [[ $? -eq 0 ]]; then
  log "✅ Netdata успешно запущен на порту 19999"
else
  log "❌ Ошибка при запуске Netdata"
  # Проверка, существует ли уже контейнер
  if docker ps -a | grep -q netdata; then
    log "⚠️ Контейнер Netdata уже существует, пытаемся перезапустить..."
    docker restart netdata
    if [[ $? -eq 0 ]]; then
      log "✅ Netdata перезапущен успешно"
    else
      log "❌ Не удалось перезапустить Netdata"
      exit 1
    fi
  else
    exit 1
  fi
fi

log "🏁 Установка завершена"