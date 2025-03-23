#!/bin/bash

# === install.sh ===
# Универсальный установщик: загружает setup_selector.sh и запускает его

SELECTOR_URL="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/setup_selector.sh"

log() {
  echo -e "\033[1;32m[INSTALL]\033[0m $1"
}

log "🔽 Загружаем setup_selector.sh из репозитория..."

if curl --output /dev/null --silent --head --fail "$SELECTOR_URL"; then
  bash <(curl -fsSL "$SELECTOR_URL")
else
  echo "❌ Не удалось загрузить setup_selector.sh по адресу: $SELECTOR_URL"
  exit 1
fi