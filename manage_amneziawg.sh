#!/bin/bash

# ==============================================================================
# Скрипт для управления пользователями (пирами) AmneziaWG
# Автор: @bivlked)
# Версия: 1.2
# Дата: 2025-04-14
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
# set -e
set -o pipefail

# Директория, где лежат файлы установки и клиентские конфиги
# Определяем дом. директорию root, т.к. скрипт должен запускаться от root
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
log_msg() {
    local type="$1"
    local message="$2"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    # Экранируем '%' для printf
    local safe_message
    safe_message=$(echo "$message" | sed 's/%/%%/g')
    local log_entry="[$timestamp] $type: $safe_message"

    # Запись в лог-файл (создаем директорию, если нужно)
    mkdir -p "$(dirname "$LOG_FILE")"
    printf "%s\n" "$log_entry" >> "$LOG_FILE"

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

# Проверка, что установка была завершена
if [ ! -f "$SETUP_CONFIG_FILE" ] || [ ! -d "$AWG_DIR/venv" ] || [ ! -f "$AWGCFG_SCRIPT_PATH" ] || [ ! -f "$SERVER_CONF_FILE" ]; then
    die "Не найдены необходимые файлы установки AmneziaWG ($SETUP_CONFIG_FILE, $AWG_DIR/venv, $AWGCFG_SCRIPT_PATH, $SERVER_CONF_FILE). Убедитесь, что 'install_amneziawg.sh' был успешно завершен."
fi

# Проверка наличия команды awg
if ! command -v awg &> /dev/null; then
    die "Команда 'awg' не найдена. Убедитесь, что пакет 'amneziawg-tools' установлен."
fi

# Проверка доступности утилиты awgcfg.py
if [ ! -x "$AWGCFG_SCRIPT_PATH" ]; then
   die "Скрипт $AWGCFG_SCRIPT_PATH не найден или не является исполняемым."
fi
# Проверка доступности Python в venv
if [ ! -x "$PYTHON_VENV_PATH" ]; then
   die "Интерпретатор Python $PYTHON_VENV_PATH не найден или не является исполняемым."
fi


# Переход в рабочую директорию для корректной работы awgcfg.py с путями
cd "$AWG_DIR" || die "Не удалось перейти в рабочую директорию $AWG_DIR"

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
    # Проверка, не существует ли уже такой клиент в конфиге сервера
    # Добавляем $ для точного совпадения имени в комментарии
    if grep -q "\[Peer\] # ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
        die "Клиент с именем '$CLIENT_NAME' уже существует в $SERVER_CONF_FILE."
    fi

    log "Добавление нового клиента '$CLIENT_NAME'..."
    if "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -a "$CLIENT_NAME"; then
        log "Клиент '$CLIENT_NAME' успешно добавлен в конфигурацию сервера $SERVER_CONF_FILE."
        log "Генерация файла конфигурации и QR-кода для '$CLIENT_NAME'..."
        # Генерируем только для нового клиента
        if "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -c -q -n "$CLIENT_NAME"; then
             log "Файлы '$CLIENT_NAME.conf' и '$CLIENT_NAME.png' созданы/обновлены в $AWG_DIR."
             log "ВАЖНО: Перезапустите сервис AmneziaWG для применения изменений: sudo systemctl restart awg-quick@awg0"
        else
             log_error "Ошибка при генерации файлов для клиента '$CLIENT_NAME'."
        fi
    else
        log_error "Ошибка при добавлении клиента '$CLIENT_NAME'. Проверьте вывод команды выше."
    fi
    ;;

  remove)
    if [ -z "$CLIENT_NAME" ]; then die "Не указано имя клиента для удаления. Используйте: $0 remove <имя_клиента>"; fi
     # Проверка, существует ли клиент в конфиге сервера перед удалением
    if ! grep -q "\[Peer\] # ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
        die "Клиент с именем '$CLIENT_NAME' не найден в $SERVER_CONF_FILE."
    fi

    log "Удаление клиента '$CLIENT_NAME'..."
    if "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -d "$CLIENT_NAME"; then
        log "Клиент '$CLIENT_NAME' успешно удален из конфигурации сервера $SERVER_CONF_FILE."
        log "Удаление файлов клиента '$CLIENT_NAME.conf' и '$CLIENT_NAME.png'..."
        rm -f "$AWG_DIR/$CLIENT_NAME.conf" "$AWG_DIR/$CLIENT_NAME.png"
        log "Файлы удалены (если существовали)."
        log "ВАЖНО: Перезапустите сервис AmneziaWG для применения изменений: sudo systemctl restart awg-quick@awg0"
    else
        log_error "Ошибка при удалении клиента '$CLIENT_NAME'. Проверьте вывод команды выше."
    fi
    ;;

  list)
    log "Получение списка клиентов из конфигурации $SERVER_CONF_FILE..."
    # Используем awgcfg.py для вывода списка
    if ! "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -l; then
       log_error "Ошибка при получении списка клиентов."
    fi
    ;;

  regen)
    if [ -n "$CLIENT_NAME" ]; then
        # Проверка существования клиента перед регенерацией
        if ! grep -q "\[Peer\] # ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then
            die "Клиент с именем '$CLIENT_NAME' не найден в $SERVER_CONF_FILE. Невозможно перегенерировать файлы."
        fi
        log "Перегенерация файлов конфигурации и QR-кода для клиента '$CLIENT_NAME'..."
        if "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -c -q -n "$CLIENT_NAME"; then
            log "Файлы '$CLIENT_NAME.conf' и '$CLIENT_NAME.png' перегенерированы в $AWG_DIR."
        else
            log_error "Ошибка при перегенерации файлов для клиента '$CLIENT_NAME'."
        fi
    else
        log "Перегенерация файлов конфигурации и QR-кодов для ВСЕХ клиентов..."
        if "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" -c -q; then
            log "Файлы .conf и .png для всех клиентов перегенерированы в $AWG_DIR."
        else
            log_error "Ошибка при перегенерации файлов для всех клиентов."
        fi
    fi
    ;;

  show)
    log "Запрос текущего статуса AmneziaWG (awg show)..."
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
