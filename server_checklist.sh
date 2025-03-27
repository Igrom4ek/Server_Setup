#!/bin/bash
echo "====== ЧЕК-ЛИСТ УСТАНОВКИ ======"
echo ""
REAL_USER=$(logname)
CONFIG_FILE="/usr/local/bin/config.json"

echo "🧾 Пользователь: $REAL_USER"
echo ""

echo "🔐 SSH:"
PORT=$(grep -Ei '^port' /etc/ssh/sshd_config | awk '{print $2}')
echo " - Порт: ${PORT:-не найден}"
grep -Ei '^passwordauthentication' /etc/ssh/sshd_config
grep -Ei '^permitrootlogin' /etc/ssh/sshd_config
echo ""

echo "🗝  Ключи SSH:"
if [ -f /home/$REAL_USER/.ssh/authorized_keys ]; then
  echo " - authorized_keys найден"
else
  echo " - ❌ authorized_keys отсутствует"
fi
echo ""

echo "📡 Службы:"
for SERVICE in ssh ufw fail2ban psad rkhunter netdata; do
  systemctl is-active --quiet $SERVICE && echo " - $SERVICE: ✅ активен" || echo " - $SERVICE: ❌ НЕ запущен"
done
echo ""

echo "🤖 Telegram бот:"
if systemctl list-units --full -all | grep -q telegram_command_listener.service; then
  echo " - telegram_command_listener.service: найден"
  systemctl is-active --quiet telegram_command_listener.service && echo "   ✅ активен" || echo "   ❌ НЕ запущен"
else
  echo " - ❌ Сервис Telegram бота не найден"
fi
echo ""

echo "🛠  Cron задачи:"
crontab -l | grep -E "security_monitor|clear_security_log" || echo " - ❌ Cron задачи не найдены"
echo ""

echo "📊 Netdata:"
echo " - Проверка доступа: http://$(hostname -I | awk '{print $1}'):19999"
echo ""

echo "📄 notify_login.sh:"
if [ -f /etc/profile.d/notify_login.sh ]; then
  echo " - Существует, проверка на ошибки:"
  grep -n '\$' /etc/profile.d/notify_login.sh
else
  echo " - ❌ /etc/profile.d/notify_login.sh отсутствует"
fi
echo ""

echo "====== КОНЕЦ ЧЕК-ЛИСТА ======"
