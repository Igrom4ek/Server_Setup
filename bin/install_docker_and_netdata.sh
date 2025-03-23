#!/bin/bash

# Проверка и установка Docker
if ! command -v docker &>/dev/null; then
  echo "Docker не найден, устанавливаем..."
  sudo apt update
  sudo apt install -y docker.io
  sudo systemctl enable --now docker
else
  echo "Docker уже установлен."
fi

# Запуск Netdata в Docker контейнере
echo "Запускаем Netdata..."
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

# Проверка успешного запуска контейнера
if docker ps | grep -q "netdata"; then
  echo "Netdata успешно запущен на порту 19999."
else
  echo "Ошибка при запуске Netdata."
  exit 1
fi
