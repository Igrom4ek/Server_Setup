#!/bin/bash

# Скрипт установки автоматического обновления n8n
# Создает скрипт обновления и настраивает его в cron

# Настройки
SCRIPT_DIR="/opt/scripts"
SCRIPT_PATH="$SCRIPT_DIR/update-n8n.sh"
LOG_FILE="/var/log/n8n-update.log"
CRON_SCHEDULE="0 3 * * *"  # Каждый день в 3:00 утра

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Создание директории для скриптов, если её нет
if [ ! -d "$SCRIPT_DIR" ]; then
    log "Создание директории для скриптов $SCRIPT_DIR..."
    mkdir -p "$SCRIPT_DIR"
    if [ $? -ne 0 ]; then
        log "Ошибка: Не удалось создать директорию $SCRIPT_DIR"
        exit 1
    fi
fi

# Создание файла скрипта обновления n8n
log "Создание скрипта обновления n8n..."
cat > "$SCRIPT_PATH" << 'EOF'
#!/bin/bash
# Делаем файл исполняемым
[ -x "$0" ] || chmod +x "$0"

# Скрипт для автоматического обновления n8n до последней версии
# Путь к директории n8n
N8N_DIR="/opt/beget/n8n"
# Путь к файлу docker-compose.yml
DOCKER_COMPOSE_FILE="$N8N_DIR/docker-compose.yml"

# Функция логирования
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"
}

# Проверка наличия директории и файла
if [ ! -d "$N8N_DIR" ]; then
    log "Ошибка: Директория $N8N_DIR не существует"
    exit 1
fi

if [ ! -f "$DOCKER_COMPOSE_FILE" ]; then
    log "Ошибка: Файл $DOCKER_COMPOSE_FILE не существует"
    exit 1
fi

# Получение текущей версии из docker-compose.yml
CURRENT_VERSION=$(grep -oP 'image: docker.n8n.io/n8nio/n8n:\K[0-9.]+' "$DOCKER_COMPOSE_FILE")

if [ -z "$CURRENT_VERSION" ]; then
    log "Ошибка: Не удалось определить текущую версию n8n в файле $DOCKER_COMPOSE_FILE"
    exit 1
fi

log "Текущая версия n8n: $CURRENT_VERSION"

# Получение последней доступной версии n8n
log "Получение информации о последней доступной версии..."
API_RESPONSE=$(curl -s -L https://hub.docker.com/v2/repositories/n8nio/n8n/tags/)
log "Проверка ответа API..."
echo "$API_RESPONSE" | head -30 > /tmp/n8n_api_response.log

# Попробуем несколько форматов API и источников
if [ -z "$API_RESPONSE" ] || ! echo "$API_RESPONSE" | grep -q '"name"'; then
    log "Пробуем альтернативный источник данных..."
    API_RESPONSE=$(curl -s -L https://registry.hub.docker.com/v2/repositories/n8nio/n8n/tags/)
    echo "$API_RESPONSE" | head -30 >> /tmp/n8n_api_response.log
fi

if [ -z "$API_RESPONSE" ] || ! echo "$API_RESPONSE" | grep -q '"name"'; then
    log "Пробуем официальный Docker Hub API..."
    API_RESPONSE=$(curl -s -L https://hub.docker.com/v2/repositories/n8nio/n8n/tags/?page_size=100)
    echo "$API_RESPONSE" | head -30 >> /tmp/n8n_api_response.log
fi

# Извлекаем версию с использованием разных шаблонов
LATEST_VERSION=""
if echo "$API_RESPONSE" | grep -q '"name"'; then
    LATEST_VERSION=$(echo "$API_RESPONSE" | grep -oP '"name":"\K[0-9.]+(?=")' | sort -V | tail -1)
fi

# Если не удалось получить версию, пробуем другой формат
if [ -z "$LATEST_VERSION" ]; then
    log "Пробуем другой формат извлечения версии..."
    LATEST_VERSION=$(echo "$API_RESPONSE" | grep -o '"name":"[0-9.]*"' | cut -d'"' -f4 | sort -V | tail -1)
fi

# Последняя попытка - использовать другую утилиту jq, если она доступна
if [ -z "$LATEST_VERSION" ] && command -v jq >/dev/null 2>&1; then
    log "Пробуем извлечь версию с помощью jq..."
    LATEST_VERSION=$(echo "$API_RESPONSE" | jq -r '.results[].name' 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+

log "Последняя доступная версия n8n: $LATEST_VERSION"

# Сравнение версий
if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    log "Обновление не требуется. У вас уже установлена последняя версия n8n."
    exit 0
fi

# Проверка, является ли последняя версия более новой
if [ "$(echo "$CURRENT_VERSION $LATEST_VERSION" | tr ' ' '\n' | sort -V | tail -1)" != "$LATEST_VERSION" ]; then
    log "Ошибка: Последняя доступная версия ($LATEST_VERSION) старше текущей ($CURRENT_VERSION). Это необычно."
    exit 1
fi

log "Доступно обновление с версии $CURRENT_VERSION до версии $LATEST_VERSION."

# Обновление файла docker-compose.yml
log "Обновление файла docker-compose.yml..."
sed -i "s/image: docker.n8n.io\/n8nio\/n8n:$CURRENT_VERSION/image: docker.n8n.io\/n8nio\/n8n:$LATEST_VERSION/" "$DOCKER_COMPOSE_FILE"

# Проверка изменения файла
if ! grep -q "image: docker.n8n.io/n8nio/n8n:$LATEST_VERSION" "$DOCKER_COMPOSE_FILE"; then
    log "Ошибка: Не удалось обновить версию в файле $DOCKER_COMPOSE_FILE"
    exit 1
fi

log "Файл docker-compose.yml успешно обновлен до версии $LATEST_VERSION"

# Переход в директорию n8n
cd "$N8N_DIR" || { log "Ошибка: Не удалось перейти в директорию $N8N_DIR"; exit 1; }

# Скачивание образа новой версии
log "Скачивание образа новой версии командой docker compose pull..."
docker compose pull
if [ $? -ne 0 ]; then
    log "Ошибка: Не удалось скачать образ новой версии"
    exit 1
fi

# Остановка текущей версии n8n
log "Остановка текущей версии n8n командой docker compose down..."
docker compose down
if [ $? -ne 0 ]; then
    log "Ошибка: Не удалось остановить текущую версию n8n"
    exit 1
fi

# Запуск новой версии n8n
log "Запуск новой версии n8n командой docker compose up -d..."
docker compose up -d
if [ $? -ne 0 ]; then
    log "Ошибка: Не удалось запустить новую версию n8n"
    exit 1
fi

log "n8n успешно обновлен до версии $LATEST_VERSION"
log "Пожалуйста, подождите 2-5 минут, пока n8n выполнит миграцию на новую версию и запустится"
log "После этого проверьте работу n8n на новой версии"

exit 0
EOF

# Делаем скрипт исполняемым
log "Установка прав на исполнение..."
chmod +x "$SCRIPT_PATH"
if [ $? -ne 0 ]; then
    log "Ошибка: Не удалось установить права на исполнение для $SCRIPT_PATH"
    exit 1
fi

# Создание лог-файла, если его нет
if [ ! -f "$LOG_FILE" ]; then
    log "Создание лог-файла $LOG_FILE..."
    touch "$LOG_FILE"
    if [ $? -ne 0 ]; then
        log "Ошибка: Не удалось создать лог-файл $LOG_FILE"
        exit 1
    fi
    chmod 644 "$LOG_FILE"
fi

# Добавление задания в cron
log "Настройка cron для запуска скрипта по расписанию..."
(crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" || echo "") | { cat; echo "$CRON_SCHEDULE $SCRIPT_PATH >> $LOG_FILE 2>&1"; } | crontab -
if [ $? -ne 0 ]; then
    log "Ошибка: Не удалось настроить cron"
    exit 1
fi

log "Установка завершена успешно."
log "Скрипт обновления: $SCRIPT_PATH"
log "Лог файл: $LOG_FILE"
log "Расписание: $CRON_SCHEDULE (каждый день в 3:00 утра)"
log "Вы можете изменить расписание, отредактировав crontab (команда: crontab -e)"

# Запуск скрипта для проверки обновлений
log "Выполнение первой проверки наличия обновлений..."
$SCRIPT_PATH
 | sort -V | tail -1)
fi

if [ -z "$LATEST_VERSION" ]; then
    log "Ошибка: Не удалось получить информацию о последней версии n8n."
    log "Пожалуйста, проверьте доступность Docker Hub API или интернет-соединение."
    log "Используйте файл /tmp/n8n_api_response.log для отладки ответа API."
    exit 1
fi

log "Последняя доступная версия n8n: $LATEST_VERSION"

# Сравнение версий
if [ "$CURRENT_VERSION" = "$LATEST_VERSION" ]; then
    log "Обновление не требуется. У вас уже установлена последняя версия n8n."
    exit 0
fi

# Проверка, является ли последняя версия более новой
if [ "$(echo "$CURRENT_VERSION $LATEST_VERSION" | tr ' ' '\n' | sort -V | tail -1)" != "$LATEST_VERSION" ]; then
    log "Ошибка: Последняя доступная версия ($LATEST_VERSION) старше текущей ($CURRENT_VERSION). Это необычно."
    exit 1
fi

log "Доступно обновление с версии $CURRENT_VERSION до версии $LATEST_VERSION."

# Обновление файла docker-compose.yml
log "Обновление файла docker-compose.yml..."
sed -i "s/image: docker.n8n.io\/n8nio\/n8n:$CURRENT_VERSION/image: docker.n8n.io\/n8nio\/n8n:$LATEST_VERSION/" "$DOCKER_COMPOSE_FILE"

# Проверка изменения файла
if ! grep -q "image: docker.n8n.io/n8nio/n8n:$LATEST_VERSION" "$DOCKER_COMPOSE_FILE"; then
    log "Ошибка: Не удалось обновить версию в файле $DOCKER_COMPOSE_FILE"
    exit 1
fi

log "Файл docker-compose.yml успешно обновлен до версии $LATEST_VERSION"

# Переход в директорию n8n
cd "$N8N_DIR" || { log "Ошибка: Не удалось перейти в директорию $N8N_DIR"; exit 1; }

# Скачивание образа новой версии
log "Скачивание образа новой версии командой docker compose pull..."
docker compose pull
if [ $? -ne 0 ]; then
    log "Ошибка: Не удалось скачать образ новой версии"
    exit 1
fi

# Остановка текущей версии n8n
log "Остановка текущей версии n8n командой docker compose down..."
docker compose down
if [ $? -ne 0 ]; then
    log "Ошибка: Не удалось остановить текущую версию n8n"
    exit 1
fi

# Запуск новой версии n8n
log "Запуск новой версии n8n командой docker compose up -d..."
docker compose up -d
if [ $? -ne 0 ]; then
    log "Ошибка: Не удалось запустить новую версию n8n"
    exit 1
fi

log "n8n успешно обновлен до версии $LATEST_VERSION"
log "Пожалуйста, подождите 2-5 минут, пока n8n выполнит миграцию на новую версию и запустится"
log "После этого проверьте работу n8n на новой версии"

exit 0
EOF

# Делаем скрипт исполняемым
log "Установка прав на исполнение..."
chmod +x "$SCRIPT_PATH"
if [ $? -ne 0 ]; then
    log "Ошибка: Не удалось установить права на исполнение для $SCRIPT_PATH"
    exit 1
fi

# Создание лог-файла, если его нет
if [ ! -f "$LOG_FILE" ]; then
    log "Создание лог-файла $LOG_FILE..."
    touch "$LOG_FILE"
    if [ $? -ne 0 ]; then
        log "Ошибка: Не удалось создать лог-файл $LOG_FILE"
        exit 1
    fi
    chmod 644 "$LOG_FILE"
fi

# Добавление задания в cron
log "Настройка cron для запуска скрипта по расписанию..."
(crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" || echo "") | { cat; echo "$CRON_SCHEDULE $SCRIPT_PATH >> $LOG_FILE 2>&1"; } | crontab -
if [ $? -ne 0 ]; then
    log "Ошибка: Не удалось настроить cron"
    exit 1
fi

log "Установка завершена успешно."
log "Скрипт обновления: $SCRIPT_PATH"
log "Лог файл: $LOG_FILE"
log "Расписание: $CRON_SCHEDULE (каждый день в 3:00 утра)"
log "Вы можете изменить расписание, отредактировав crontab (команда: crontab -e)"

# Запуск скрипта для проверки обновлений
log "Выполнение первой проверки наличия обновлений..."
$SCRIPT_PATH
