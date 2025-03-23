#!/bin/bash

CONFIG_FILE="/usr/local/bin/config.json"

# Проверка наличия jq
if ! command -v jq &>/dev/null; then
  echo "Требуется jq. Установите: sudo apt install jq -y"
  exit 1
fi

# Проверка наличия config.json
if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Файл конфигурации не найден: $CONFIG_FILE"
  exit 1
fi

# Получаем путь к лог-файлу и cron-настройку из config.json
LOG_FILE=$(jq -r '.security_log_file // "/var/log/security_monitor.log"' "$CONFIG_FILE")
CLEAR_LOG_CRON=$(jq -r '.clear_logs_cron // "0 5 * * 0"' "$CONFIG_FILE")

# Функция логирования (без вывода в терминал, только в файл)
log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" >> "$LOG_FILE"
}

# Очистка лога
log "Очистка лога безопасности"
echo "$(date '+%Y-%m-%d %H:%M:%S') | Лог очищен" > "$LOG_FILE"

# Настройка cron, если ещё не настроена
setup_cron() {
  local cron_line="$CLEAR_LOG_CRON /bin/bash $0"
  if ! crontab -l 2>/dev/null | grep -q "$0"; then
    # Создаём временный файл для cron
    TEMP_CRON=$(mktemp)
    # Сохраняем текущий crontab или создаём пустой
    crontab -l 2>/dev/null > "$TEMP_CRON" || echo "" > "$TEMP_CRON"
    # Добавляем задачу, если её нет
    echo "$cron_line" >> "$TEMP_CRON"
    # Устанавливаем новый crontab
    crontab "$TEMP_CRON"
    rm -f "$TEMP_CRON"
    log "Cron-задача добавлена: $cron_line"
  else
    log "Cron-задача уже настроена"
  fi
}

# Установка cron-задачи
log "Проверка настройки cron для очистки логов..."
setup_cron

exit 0