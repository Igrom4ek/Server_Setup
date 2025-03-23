#!/bin/bash

CONFIG_FILE="/usr/local/bin/config.json"
SCRIPT_DIR="/usr/local/bin"
LOG_FILE="/var/log/setup_selector.log"
SCRIPT_URL_BASE="https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main"
SCRIPTS_PATH="bin"

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

# Установка jq, если отсутствует
if ! command -v jq &>/dev/null; then
  log "Устанавливаем jq..."
  apt update && apt install jq -y
  if [[ $? -ne 0 ]]; then
    log "Ошибка установки jq"
    exit 1
  fi
fi

# Загрузка config.json, если отсутствует
if [[ ! -f "$CONFIG_FILE" ]]; then
  log "Загружаем config.json с GitHub..."
  curl -fsSL "$SCRIPT_URL_BASE/$SCRIPTS_PATH/config.json" -o "$CONFIG_FILE"
  if [[ ! -f "$CONFIG_FILE" ]]; then
    log "Не удалось загрузить config.json"
    exit 1
  fi
  chmod 644 "$CONFIG_FILE"
  log "config.json успешно загружен"
fi

# Извлечение параметров
USERNAME=$(jq -r '.username // "igrom"' "$CONFIG_FILE")
PORT=$(jq -r '.port // 5075' "$CONFIG_FILE")
KEY_FILE=$(jq -r '.ssh_key_file // "/usr/local/bin/ssh_key.pub"' "$CONFIG_FILE")

# Проверка SSH-ключа (загрузка или ввод вручную)
if [[ ! -f "$KEY_FILE" ]]; then
  log "SSH-ключ не найден: $KEY_FILE"
  if curl -fsSL "$SCRIPT_URL_BASE/$SCRIPTS_PATH/id_ed25519.pub" -o "$KEY_FILE"; then
    chmod 644 "$KEY_FILE"
    log "SSH-ключ загружен из GitHub в $KEY_FILE"
  else
    log "Не удалось загрузить SSH-ключ с GitHub, запрашиваем ввод вручную"
    read -p "Введите SSH-публичный ключ вручную: " SSH_KEY
    if [[ ! "$SSH_KEY" =~ ^ssh-(rsa|ed25519) ]]; then
      echo "Неверный формат SSH-ключа"
      log "Ошибка: Неверный формат SSH-ключа"
      exit 1
    fi
    echo "$SSH_KEY" > "$KEY_FILE"
    chmod 644 "$KEY_FILE"
    log "SSH-ключ сохранён вручную в $KEY_FILE"
  fi
fi

# Загрузка необходимых скриптов
for script in setup_server_master.sh secure_hardening_master.sh install.sh; do
  if [[ ! -f "$SCRIPT_DIR/$script" ]]; then
    log "Загружаем $script из GitHub..."
    if curl -fsSL "$SCRIPT_URL_BASE/$SCRIPTS_PATH/$script" -o "$SCRIPT_DIR/$script"; then
      chmod +x "$SCRIPT_DIR/$script"
      log "$script успешно загружен"
    else
      log "Ошибка загрузки $script — проверь путь или наличие файла в репозитории"
      exit 1
    fi
  fi
done

# Меню выбора установки
echo "Выберите опцию установки:"
echo "1. Базовая установка сервера (setup_server_master.sh)"
echo "2. Установка защиты и мониторинга (secure_hardening_master.sh)"
echo "3. Установка Netdata (install.sh)"
echo "4. Выход"
read -p "Выберите номер: " choice

case $choice in
  1)
    log "Запускаем базовую установку через setup_server_master.sh..."
    bash "$SCRIPT_DIR/setup_server_master.sh" --username="$USERNAME" --port="$PORT" --key-file="$KEY_FILE"
    ;;
  2)
    log "Запускаем защиту и мониторинг через secure_hardening_master.sh..."
    bash "$SCRIPT_DIR/secure_hardening_master.sh"
    ;;
  3)
    log "Запускаем установку Netdata через install.sh..."
    bash "$SCRIPT_DIR/install.sh"
    ;;
  4)
    echo "Выход."
    log "Выход из скрипта"
    exit 0
    ;;
  *)
    echo "Неверный выбор."
    log "Ошибка: Неверный выбор в меню"
    ;;
esac

exit 0