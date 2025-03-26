# 🚀 Server_Setup

Автоматическая настройка Linux-сервера с пользователем, SSH, безопасностью, Telegram-ботом и мониторингом Netdata.

---

## 📦 Установка

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/install_root.sh)
```

Скрипт `install_root.sh` автоматически создаст пользователя, установит ключ, выполнит установку от имени пользователя, настроит Telegram-бота, Netdata и защитные службы (UFW, Fail2Ban, PSAD, RKHunter, nmap). В конце запускается проверка установки.

---

## 🧱 Структура

| Файл                         | Назначение |
|------------------------------|------------|
| `install_root.sh`           | Основной скрипт, запускается от root |
| `install_user.sh`           | Скрипт от имени пользователя, завершает установку |
| `secure_install.sh`         | Настройка UFW, Fail2Ban, PSAD, RKHunter, nmap, Telegram-уведомлений |
| `telegram_command_listener.sh` | Telegram-бот с командой `/security` |
| `verify_install.sh`         | Проверка безопасности и корректности установки |
| `config.json`               | Конфигурация: имя пользователя, порт, расписания cron и службы |
| `id_ed25519.pub`            | Публичный SSH-ключ для доступа к пользователю |

---

## 🔒 Защита

- ✅ `ufw` — файрвол
- ✅ `fail2ban` — защита от перебора паролей
- ✅ `psad` — обнаружение сканирования портов
- ✅ `rkhunter` — проверка на rootkits
- ✅ `nmap` — диагностика сети
- ✅ Telegram-уведомления при входе и при проверке

---

## 📲 Telegram

- Бот реагирует на команду `/security` и отправляет отчёт от `rkhunter` и `psad`
- Отправляет уведомления о входах по SSH

---

## 📊 Мониторинг

- Используется `Netdata` в Docker-контейнере:  
  [http://your_server_ip:19999](http://your_server_ip:19999)

---

## ✅ Проверка установки

После завершения `install_user.sh` запускается:
```bash
/usr/local/bin/verify_install.sh
```

Он проверяет все службы, порты, cron-задачи, Telegram и мониторинг.

---

## 📌 Требования

- Ubuntu 22.04 или совместимая
- root-доступ по SSH
- Telegram-бот и chat_id в `config.json`
