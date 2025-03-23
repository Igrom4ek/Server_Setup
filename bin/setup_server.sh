#!/bin/bash

# === setup_server.sh ===
# Установка пользователя, SSH, fail2ban, iptables + поддержка config.json и вызов setup_server_master.sh

CONFIG_FILE="/usr/local/bin/config.json"
SCRIPT_DIR="/usr/local/bin"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Проверка наличия jq
if ! command -v jq &>/dev/null; then
    echo "Требуется jq. Установите: sudo apt install jq -y"
    exit 1
fi

# Проверка наличия файла конфигурации
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Не найден файл конфигурации: $CONFIG_FILE"
    exit 1
fi

# Извлечение параметров из config.json
USERNAME=$(jq -r '.username // "igrom"' "$CONFIG_FILE")
PORT=$(jq -r '.port // 5075' "$CONFIG_FILE")
SSH_KEY_FILE=$(jq -r '.ssh_key_file // "/usr/local/bin/ssh_key.pub"' "$CONFIG_FILE")
LOG_FILE=$(jq -r '.log_file // "/var/log/setup_server.log"' "$CONFIG_FILE")

# Функция логирования
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $1" | tee -a "$LOG_FILE"
}

log "Начинаем настройку сервера..."

# Вызов setup_server_master.sh для предварительной настройки
if [[ -f "$SCRIPT_DIR/setup_server_master.sh" ]]; then
    log "Запускаем предварительную настройку через setup_server_master.sh..."
    bash "$SCRIPT_DIR/setup_server_master.sh" --username="$USERNAME" --port="$PORT" --key-file="$SSH_KEY_FILE"
    if [[ $? -ne 0 ]]; then
        log "Ошибка при выполнении setup_server_master.sh"
        exit 1
    fi
else
    log "Предупреждение: setup_server_master.sh не найден, продолжаем без него"
fi

# === 1. Обновление системы ===
log "Обновляем систему..."
sudo apt clean all && sudo apt update && sudo apt dist-upgrade -y
if [[ $? -ne 0 ]]; then
    log "Ошибка при обновлении системы"
    exit 1
fi

# === 2. Создаём пользователя ===
if id "$USERNAME" &>/dev/null; then
    log "Пользователь $USERNAME уже существует."
else
    log "Создаём пользователя $USERNAME..."
    sudo adduser --disabled-password --gecos "" "$USERNAME"
    echo "$USERNAME:SecureP@ssw0rd" | sudo chpasswd
    sudo usermod -aG sudo "$USERNAME"
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers
fi

# === 3. Отключаем ssh.socket ===
log "Отключаем ssh.socket..."
sudo systemctl stop ssh.socket
sudo systemctl disable ssh.socket

# === 4. Настройка SSH ===
log "Настраиваем SSH..."
sudo sed -i "s/^#\?Port .*/Port $PORT/" $SSHD_CONFIG
sudo sed -i "s/^#\?PermitRootLogin .*/PermitRootLogin no/" $SSHD_CONFIG
sudo sed -i "s/^#\?PasswordAuthentication .*/PasswordAuthentication no/" $SSHD_CONFIG
sudo sed -i "s/^#\?AddressFamily .*/AddressFamily inet/" $SSHD_CONFIG
sudo sed -i "s/^#\?ListenAddress .*/ListenAddress 0.0.0.0/" $SSHD_CONFIG
sudo sed -i "s/^#\?MaxAuthTries .*/MaxAuthTries 3/" $SSHD_CONFIG
sudo sed -i "s/^#\?MaxSessions .*/MaxSessions 2/" $SSHD_CONFIG
echo "LoginGraceTime 30" | sudo tee -a $SSHD_CONFIG

# === 5. Открытие порта ===
log "Открываем порт $PORT..."
if command -v ufw &>/dev/null; then
    sudo ufw allow "$PORT/tcp"
    sudo ufw reload
fi
if command -v iptables &>/dev/null; then
    sudo iptables -A INPUT -p tcp --dport "$PORT" -j ACCEPT
    sudo iptables-save > /etc/iptables.rules
fi

# === 6. SSH-ключ ===
if [[ -f "$SSH_KEY_FILE" ]]; then
    log "Копируем SSH-ключ из файла $SSH_KEY_FILE"
    SSH_KEY=$(cat "$SSH_KEY_FILE")
else
    log "SSH-ключ не найден: $SSH_KEY_FILE"
    read -p "Введите SSH-публичный ключ вручную: " SSH_KEY
fi

sudo -u "$USERNAME" mkdir -p "/home/$USERNAME/.ssh"
sudo chmod 700 "/home/$USERNAME/.ssh"
echo "$SSH_KEY" | sudo -u "$USERNAME" tee "/home/$USERNAME/.ssh/authorized_keys" > /dev/null
sudo chmod 600 "/home/$USERNAME/.ssh/authorized_keys"
sudo chown -R "$USERNAME:$USERNAME" "/home/$USERNAME/.ssh"

# === 7. Fail2ban ===
log "Устанавливаем fail2ban..."
sudo apt install fail2ban -y
sudo tee /etc/fail2ban/jail.local <<EOF
[sshd]
enabled = true
port = $PORT
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 3600
findtime = 600
EOF
sudo systemctl restart fail2ban
sudo systemctl enable fail2ban

# === 8. DoS-защита ===
log "Добавляем iptables-защиту от DoS..."
sudo iptables -A INPUT -p tcp --dport "$PORT" -m conntrack --ctstate NEW -m recent --set
sudo iptables -A INPUT -p tcp --dport "$PORT" -m conntrack --ctstate NEW -m recent --update --seconds 60 --hitcount 10 -j DROP
sudo iptables-save > /etc/iptables.rules

# === 9. Перезапуск SSH ===
log "Перезапускаем SSH..."
sudo systemctl restart ssh
sudo systemctl enable ssh
if [[ $? -ne 0 ]]; then
    log "Ошибка при перезапуске SSH"
    exit 1
fi

log "Настройка завершена. Подключайтесь: ssh -p $PORT $USERNAME@SERVER_IP"
exit 0