# Server_Setup

Автоматическая настройка Linux-сервера в два этапа: создание пользователя, настройка SSH, безопасность, Telegram-бот и мониторинг Netdata.

---

## 🚀 Установка (2 этапа)

### 🔹 Этап 1 — от имени `root`

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/install_root.sh)
```

Скрипт:
- создаёт пользователя (из `config.json`),
- копирует публичный ключ,
- настраивает SSH и `grub quiet mode`,
- оставляет `root`-вход по паролю (если указано),
- выводит инструкцию для запуска второго этапа.

---

### 🔹 Этап 2 — от имени нового пользователя (`igrom`)

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Igrom4ek/Server_Setup/main/install_user.sh)"
```

Скрипт:
- устанавливает Telegram-бота как systemd-сервис,
- запускает `secure_install.sh` (защита),
- настраивает Docker и Netdata,
- cron-задачи,
- запускает проверку (`verify_install.sh`),
- удаляет сам себя.

---

## 🔧 Структура проекта

| Файл                          | Назначение |
|-------------------------------|------------|
| `install_root.sh`             | Скрипт установки, запускаемый от `root` |
| `install_user.sh`             | Скрипт установки, запускаемый от пользователя |
| `secure_install.sh`           | Настройка защиты: fail2ban, psad, rkhunter, ufw, cron |
| `telegram_command_listener.sh`| Telegram-бот с командой `/security` |
| `verify_install.sh`           | Проверка успешной установки |
| `config.json`                 | Конфигурация сервера |
| `id_ed25519.pub`              | Публичный SSH-ключ |

---

## 🔐 Защита

- `ufw` — файрвол
- `fail2ban` — защита от перебора паролей
- `psad` — мониторинг сканирования портов
- `rkhunter` — поиск rootkit
- `nmap` — диагностика сети
- Telegram-уведомления:
  - при входах по SSH
  - при обнаружении подозрений

---

## 📲 Telegram-бот

- Реакция на `/security` — присылает отчёт от `rkhunter` и `psad`
- Автоматические уведомления при логине
- Работает как `systemd`-сервис

---

## 📊 Мониторинг

- `Netdata` запускается в Docker-контейнере
- Доступен по адресу: `http://your_server_ip:19999`

---

## ✅ Проверка установки

Выполняется автоматически:

- состояние служб,
- SSH-доступ и порт,
- cron-задачи,
- Telegram и Netdata,
- rkhunter и psad.

---

## 📎 Требования

- Ubuntu 22.04 или совместимая
- root-доступ по SSH
- `config.json` с параметрами:
  - `username`, `user_password`
  - `port`, `telegram_bot_token`, `telegram_chat_id`
  - `services` и `cron_tasks`
