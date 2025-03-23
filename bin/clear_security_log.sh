#!/bin/bash

LOG_FILE="/var/log/security_monitor.log"
echo "$(date '+%Y-%m-%d %H:%M:%S') | Очистка лога безопасности (еженедельно)" > "$LOG_FILE"

