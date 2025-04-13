#!/bin/bash

# ==============================================================================
# Скрипт для управления пользователями (пирами) AmneziaWG
# Автор: @bivlked)
# Версия: 1.8
# Дата: 2025-04-14
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
# set -e # Раскомментируйте для немедленного выхода при любой ошибке
set -o pipefail # Выход, если команда в пайпе завершается с ошибкой

# Директория, где лежат файлы установки и клиентские конфиги
# Используем /root/awg, т.к. скрипт должен запускаться от root
AWG_DIR="/root/awg"
# Конфигурационный файл установки (для проверки существования)
SETUP_CONFIG_FILE="$AWG_DIR/setup.conf"
# Путь к виртуальному окружению Python
PYTHON_VENV_PATH="$AWG_DIR/venv/bin/python"
# Путь к скрипту awgcfg.py
AWGCFG_SCRIPT_PATH="$AWG_DIR/awgcfg.py"
# Лог файл управления
LOG_FILE="$AWG_DIR/manage_amneziawg.log"
# Файл конфигурации сервера
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"


# --- Функции Логирования ---
# Функция для вывода сообщений в лог и на экран
log_msg() {
    local type="$1" # INFO, WARN, ERROR
    local message="$2"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    # Экранируем '%' для printf
    local safe_message
    safe_message=$(echo "$message" | sed 's/%/%%/g')
    local log_entry="[$timestamp] $type: $safe_message"

    # Запись в лог-файл (создаем директорию, если нужно)
    # Проверяем возможность записи перед попыткой
    if ! mkdir -p "$(dirname "$LOG_FILE")" || ! touch "$LOG_FILE"; then
        echo "[$timestamp] ERROR: Не удается создать/записать лог-файл $LOG_FILE" >&2
        # Продолжаем без записи в лог, но сообщаем об ошибке
    else
        printf "%s\n" "$log_entry" >> "$LOG_FILE"
    fi

    # Вывод на экран (stderr для ошибок/предупреждений)
    if [[ "$type" == "ERROR" ]]; then
        printf "%s\n" "$log_entry" >&2
    else
        # Выводим всё, кроме INFO, если не терминал (чтобы не засорять вывод при автоматизации)
        if [[ "$type" != "INFO" || -t 1 ]]; then
            printf "%s\n" "$log_entry"
        fi
    fi
}
log() { log_msg "INFO" "$1"; }
log_warn() { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
# Функция для выхода при ошибке
die() { log_error "$1"; exit 1; }


# --- Функция вывода помощи ---
usage() {
  # Выводим на stderr, так как это информация об ошибке использования
  exec >&2
  echo "Использование: $0 <команда> [аргументы]"
  echo "Команды:"
  echo "  add <имя_клиента>       - Добавить нового клиента (пира)."
  echo "                            Имя: латинские буквы, цифры, дефис, подчеркивание."
  echo "  remove <имя_клиента>    - Удалить существующего клиента."
  echo "  list                    - Показать список текущих клиентов (пиров) из конфигурации."
  echo "  regen [имя_клиента]   - Перегенерировать файл .conf и QR-код для клиента(ов)."
  echo "                            Без имени - для ВСЕХ. ВНИМАНИЕ: Перезаписывает файлы!"
  echo "  show                    - Показать текущий статус AmneziaWG (аналог 'awg show')."
  echo "  help                    - Показать это сообщение."
  exit 1
}

# --- Проверки перед выполнением ---

# Проверка прав root
if [ "$(id -u)" -ne 0 ]; then
  echo "ERROR: Скрипт должен быть запущен с правами root (через sudo)." >&2
  exit 1
fi

# Создаем директорию и файл лога (проверка записи была в log_msg)
mkdir -p "$AWG_DIR" || exit 1
touch "$LOG_FILE" || exit 1

# Проверка, что установка была завершена
log "Проверка наличия необходимых файлов..."
files_ok=1
if [ ! -f "$SETUP_CONFIG_FILE" ]; then log_error " - Отсутствует $SETUP_CONFIG_FILE (файл настроек)"; files_ok=0; fi
if [ ! -d "$AWG_DIR/venv" ]; then log_error " - Отсутствует $AWG_DIR/venv (директория Python venv)"; files_ok=0; fi
if [ ! -f "$AWGCFG_SCRIPT_PATH" ]; then log_error " - Отсутствует $AWGCFG_SCRIPT_PATH (скрипт генерации)"; files_ok=0; fi
if [ ! -f "$SERVER_CONF_FILE" ]; then log_error " - Отсутствует $SERVER_CONF_FILE (конфиг сервера)"; files_ok=0; fi

if [ "$files_ok" -eq 0 ]; then
    die "Не найдены необходимые файлы установки AmneziaWG. Убедитесь, что 'install_amneziawg.sh' был успешно завершен."
fi
log "Все необходимые файлы найдены."

# Проверка наличия команды awg
if ! command -v awg &> /dev/null; then
    die "Команда 'awg' не найдена. Убедитесь, что пакет 'amneziawg-tools' установлен."
fi
log "Команда 'awg' найдена."

# Проверка доступности утилиты awgcfg.py
if [ ! -x "$AWGCFG_SCRIPT_PATH" ]; then
   die "Скрипт $AWGCFG_SCRIPT_PATH не найден или не является исполняемым."
fi
log "Скрипт $AWGCFG_SCRIPT_PATH найден и является исполняемым."

# Проверка доступности Python в venv
if [ ! -x "$PYTHON_VENV_PATH" ]; then
   die "Интерпретатор Python $PYTHON_VENV_PATH не найден или не является исполняемым."
fi
log "Интерпретатор Python $PYTHON_VENV_PATH найден и является исполняемым."


# Переход в рабочую директорию для корректной работы awgcfg.py с путями
cd "$AWG_DIR" || die "Не удалось перейти в рабочую директорию $AWG_DIR"
log "Текущая директория: $(pwd)"

# --- Обработка аргументов командной строки ---
COMMAND=$1
CLIENT_NAME=$2

# Проверяем команду
if [ -z "$COMMAND" ]; then usage; fi

log "Запуск команды '$COMMAND'..."

case $COMMAND in
  add)
    if [ -z "$CLIENT_NAME" ]; then die "Не указано имя клиента для добавления. Используйте: $0 add <имя_клиента>"; fi
    # Валидация имени клиента
    if ! [[ "$CLIENT_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
        die "Имя клиента '$CLIENT_NAME' содержит недопустимые символы. Разрешены: a-z, A-Z, 0-9, _, -."
    fi
    # Проверка, не существует ли уже такой клиент в конфиге сервера (ищем по #_Name = )
    if grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
        die "Клиент с именем '$CLIENT_NAME' уже существует в $SERVER_CONF_FILE."
    fi

    log "Добавление нового клиента '$CLIENT_NAME'..."
    # Выполняем awgcfg.py -a и проверяем код возврата
    if "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -a "$CLIENT_NAME"; then
        log "Клиент '$CLIENT_NAME' успешно добавлен в конфигурацию сервера $SERVER_CONF_FILE."
        log "Генерация/обновление файлов конфигурации и QR-кодов для ВСЕХ клиентов (включая нового)..."
        # Выполняем awgcfg.py -c -q (без -n) и проверяем код возврата
        if "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -c -q; then
             log "Файлы '$CLIENT_NAME.conf' и '$CLIENT_NAME.png' (и файлы других клиентов) созданы/обновлены в $AWG_DIR."
             log "ВАЖНО: Перезапустите сервис AmneziaWG для применения изменений: sudo systemctl restart awg-quick@awg0"
        else
             # Ошибка произошла при генерации файлов, но клиент в конфиг сервера уже добавлен!
             log_error "Ошибка при генерации файлов конфигурации/QR-кодов (awgcfg.py -c -q)."
             log_warn "Клиент '$CLIENT_NAME' был добавлен в $SERVER_CONF_FILE, но его файлы .conf/.png могут быть не актуальны!"
             log_warn "Попробуйте выполнить '$0 regen' для перегенерации файлов."
        fi
    else
        # Ошибка произошла уже при добавлении клиента в конфиг сервера
        log_error "Ошибка при добавлении клиента '$CLIENT_NAME' (awgcfg.py -a). Проверьте вывод команды выше."
    fi
    ;;

  remove)
    if [ -z "$CLIENT_NAME" ]; then die "Не указано имя клиента для удаления. Используйте: $0 remove <имя_клиента>"; fi
     # Проверка, существует ли клиент в конфиге сервера перед удалением (ищем по #_Name = )
    if ! grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
        die "Клиент с именем '$CLIENT_NAME' не найден в $SERVER_CONF_FILE."
    fi

    log "Удаление клиента '$CLIENT_NAME'..."
    # Выполняем awgcfg.py -d и проверяем код возврата
    if "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -d "$CLIENT_NAME"; then
        log "Клиент '$CLIENT_NAME' успешно удален из конфигурации сервера $SERVER_CONF_FILE."
        log "Удаление файлов клиента '$CLIENT_NAME.conf' и '$CLIENT_NAME.png'..."
        # Используем -f чтобы не было ошибки, если файлов нет
        rm -f "$AWG_DIR/$CLIENT_NAME.conf" "$AWG_DIR/$CLIENT_NAME.png"
        log "Файлы '$CLIENT_NAME.conf' и '$CLIENT_NAME.png' удалены из '$AWG_DIR' (если существовали)."
        log "ВАЖНО: Перезапустите сервис AmneziaWG для применения изменений: sudo systemctl restart awg-quick@awg0"
    else
        log_error "Ошибка при удалении клиента '$CLIENT_NAME' (awgcfg.py -d). Проверьте вывод команды выше."
    fi
    ;;

  list)
    # === Версия v1.6 (Исправлена ошибка с 'local' вне функции) ===
    log "Получение списка клиентов из конфигурации $SERVER_CONF_FILE..."
    # Ищем строки, начинающиеся с '#_Name = ' и извлекаем имя после знака равенства
    clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //') || true # Добавляем || true на случай, если grep ничего не найдет

    if [ -z "$clients" ]; then
        log "Клиенты не найдены в конфигурационном файле (не найдены строки вида '#_Name = ...')."
    else
        log "Найденные клиенты:"
        # Выводим каждого клиента на новой строке
        echo "$clients" | while IFS= read -r client_name; do
             # Удаляем возможные пробелы в начале/конце имени (на всякий случай)
             client_name=$(echo "$client_name" | xargs)
             if [ -z "$client_name" ]; then continue; fi # Пропускаем пустые строки, если вдруг будут

             # Переменные для проверки наличия файлов
             conf_exists="-"
             png_exists="-"
             [ -f "$AWG_DIR/${client_name}.conf" ] && conf_exists="✓"
             [ -f "$AWG_DIR/${client_name}.png" ] && png_exists="✓"
             # Используем printf для форматированного вывода
             printf " - %-20s (файлы: conf %s, png %s)\n" "$client_name" "$conf_exists" "$png_exists" | tee -a "$LOG_FILE"
        done
    fi
    # === КОНЕЦ ===
    ;;

  regen)
    if [ -n "$CLIENT_NAME" ]; then
        # Проверка существования клиента перед регенерацией (ищем по #_Name = )
        if ! grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
            die "Клиент с именем '$CLIENT_NAME' не найден в $SERVER_CONF_FILE. Невозможно перегенерировать файлы."
        fi
        log "Перегенерация файлов конфигурации и QR-кодов для ВСЕХ клиентов (включая '$CLIENT_NAME')..."
        # Вызываем awgcfg.py -c -q (без -n) и проверяем код возврата
        if "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -c -q; then
            log "Файлы .conf и .png для всех клиентов перегенерированы в $AWG_DIR."
        else
            log_error "Ошибка при перегенерации файлов (awgcfg.py -c -q)."
        fi
    else
        log "Перегенерация файлов конфигурации и QR-кодов для ВСЕХ клиентов..."
        # Вызываем awgcfg.py -c -q и проверяем код возврата
        if "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -c -q; then
            log "Файлы .conf и .png для всех клиентов перегенерированы в $AWG_DIR."
        else
            log_error "Ошибка при перегенерации файлов для всех клиентов (awgcfg.py -c -q)."
        fi
    fi
    ;;

  show)
    log "Запрос текущего статуса AmneziaWG (awg show)..."
    # Выполняем awg show и проверяем код возврата
    if ! awg show; then
        log_error "Ошибка при выполнении 'awg show'."
    fi
    ;;

  help|--help|-h)
    usage
    ;;
  *)
    log_error "Неизвестная команда: '$COMMAND'"
    usage
    ;;
esac

log "Скрипт управления завершил работу."
exit 0
