#!/bin/bash

# ==============================================================================
# Скрипт для управления пользователями (пирами) AmneziaWG
# Автор: @bivlked
# Версия: 2.0
# Дата: 2025-04-16
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
set -o pipefail
# Директория AWG (по умолчанию /root/awg, может быть переопределена --conf-dir)
AWG_DIR="/root/awg"
# Файл конфигурации сервера (по умолчанию, может быть переопределен --server-conf)
SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf"
# Остальные пути формируются относительно AWG_DIR
SETUP_CONFIG_FILE="$AWG_DIR/setup.conf"
PYTHON_VENV_PATH="$AWG_DIR/venv/bin/python"
AWGCFG_SCRIPT_PATH="$AWG_DIR/awgcfg.py"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"

# --- Обработка аргументов командной строки ---
VERBOSE_LIST=0
COMMAND=""
ARGS=() # Массив для остальных аргументов

while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help) COMMAND="help"; shift ;;
        -v|--verbose) VERBOSE_LIST=1; shift ;;
        --conf-dir=*) AWG_DIR="${1#*=}"; shift ;;
        --server-conf=*) SERVER_CONF_FILE="${1#*=}"; shift ;;
        add|remove|list|regen|modify|backup|restore|check|status|show|restart)
            if [ -z "$COMMAND" ]; then COMMAND=$1; else ARGS+=("$1"); fi; shift ;;
        *) # Все остальные аргументы сохраняем
            ARGS+=("$1"); shift ;;
    esac
done

# Переназначаем переменные на основе ARGS
CLIENT_NAME="${ARGS[0]}"
PARAM="${ARGS[1]}"
VALUE="${ARGS[2]}"

# Обновляем пути после возможного изменения AWG_DIR
SETUP_CONFIG_FILE="$AWG_DIR/setup.conf"
PYTHON_VENV_PATH="$AWG_DIR/venv/bin/python"
AWGCFG_SCRIPT_PATH="$AWG_DIR/awgcfg.py"
LOG_FILE="$AWG_DIR/manage_amneziawg.log"

# --- Функции ---
log_msg() {
    local type="$1"; local msg="$2"; local ts; ts=$(date +'%F %T');
    local safe_msg; safe_msg=$(echo "$msg" | sed 's/%/%%/g'); local entry="[$ts] $type: $safe_msg";
    # Цвета
    local color_start=""; local color_end="\033[0m";
    if [[ -t 1 ]]; then case "$type" in INFO) color_start="\033[1;32m";; WARN) color_start="\033[1;33m";; ERROR) color_start="\033[1;31m";; DEBUG) color_start="\033[0;36m";; *) color_start=""; color_end="";; esac; fi
    # Лог
    if ! mkdir -p "$(dirname "$LOG_FILE")" || ! touch "$LOG_FILE"; then echo "[$ts] ERROR: Ошибка лог-файла $LOG_FILE" >&2; else printf "%s\n" "$entry" >> "$LOG_FILE"; fi
    # Экран
    if [[ "$type" == "ERROR" ]]; then printf "${color_start}%s${color_end}\n" "$entry" >&2; else printf "${color_start}%s${color_end}\n" "$entry"; fi
}
log() { log_msg "INFO" "$1"; }; log_warn() { log_msg "WARN" "$1"; }; log_error() { log_msg "ERROR" "$1"; }; die() { log_error "$1"; exit 1; }
is_interactive() { [[ -t 0 && -t 1 ]]; }
confirm_action() { if ! is_interactive; then return 0; fi; local action="$1"; local subject="$2"; read -p "Вы действительно хотите $action $subject? [y/N]: " confirm < /dev/tty; if [[ "$confirm" =~ ^[Yy]$ ]]; then return 0; else log "Действие отменено."; return 1; fi; }
validate_client_name() { local name="$1"; if [[ -z "$name" ]]; then log_error "Имя пустое."; return 1; fi; if [[ ${#name} -gt 63 ]]; then log_error "Имя > 63 симв."; return 1; fi; if ! [[ "$name" =~ ^[a-zA-Z0-9_-]+$ ]]; then log_error "Имя содержит недоп. символы."; return 1; fi; return 0; }
check_dependencies() {
    log "Проверка зависимостей..."; local ok=1;
    if [ ! -f "$SETUP_CONFIG_FILE" ]; then log_error " - $SETUP_CONFIG_FILE"; ok=0; fi
    if [ ! -d "$AWG_DIR/venv" ]; then log_error " - $AWG_DIR/venv"; ok=0; fi
    if [ ! -f "$AWGCFG_SCRIPT_PATH" ]; then log_error " - $AWGCFG_SCRIPT_PATH"; ok=0; fi
    if [ ! -f "$SERVER_CONF_FILE" ]; then log_error " - $SERVER_CONF_FILE"; ok=0; fi
    if [ "$ok" -eq 0 ]; then die "Не найдены файлы установки."; fi
    if ! command -v awg &>/dev/null; then die "'awg' не найден."; fi
    if [ ! -x "$AWGCFG_SCRIPT_PATH" ]; then die "$AWGCFG_SCRIPT_PATH не найден/не исполняемый."; fi
    if [ ! -x "$PYTHON_VENV_PATH" ]; then die "$PYTHON_VENV_PATH не найден/не исполняемый."; fi
    log "Зависимости OK.";
}
run_awgcfg() {
    # Запускаем из AWG_DIR, т.к. awgcfg.py ищет файлы относительно текущей директории
    log_debug "Вызов awgcfg.py из $(pwd): $*"
    if ! (cd "$AWG_DIR" && "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" "$@"); then
        log_error "Ошибка выполнения awgcfg.py $*"; return 1;
    fi
    log_debug "awgcfg.py $* выполнен успешно."; return 0;
}
backup_configs() {
    log "Создание резервной копии..."; local bd="$AWG_DIR/backups"; mkdir -p "$bd" || die "Ошибка mkdir $bd";
    local ts; ts=$(date +%F_%T); local bf="$bd/awg_backup_${ts}.tar.gz"; local td; td=$(mktemp -d);
    mkdir -p "$td/server" "$td/clients"; cp -a "$SERVER_CONF_FILE"* "$td/server/" 2>/dev/null;
    cp -a "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$AWG_DIR"/setup.conf "$td/clients/" 2>/dev/null||true;
    tar -czf "$bf" -C "$td" . || { rm -rf "$td"; die "Ошибка tar $bf"; }; rm -rf "$td";
    chmod 600 "$bf" || log_warn "Ошибка chmod бэкапа";
    find "$bd" -name "awg_backup_*.tar.gz" -printf '%T@ %p\n'|sort -nr|tail -n +11|cut -d' ' -f2-|xargs -r rm -f || log_warn "Ошибка удаления старых бэкапов";
    log "Бэкап создан: $bf";
}
restore_backup() {
    local bf="$1"; local bd="$AWG_DIR/backups";
    if [ -z "$bf" ]; then
        if [ ! -d "$bd" ] || [ -z "$(ls -A "$bd" 2>/dev/null)" ]; then die "Резервные копии не найдены в $bd."; fi
        local backups; backups=$(find "$bd" -maxdepth 1 -name "awg_backup_*.tar.gz" | sort -r);
        if [ -z "$backups" ]; then die "Резервные копии не найдены."; fi
        echo "Доступные бэкапы:"; local i=1; local bl=();
        while IFS= read -r f; do
            local fd; fd=$(basename "$f" | grep -o '[0-9]\{8\}_[0-9]\{6\}' | sed 's/_/ /') # Используем правильный формат даты/времени
            echo "$i) $(basename "$f") ($fd)"; bl[$i]="$f"; ((i++));
        done <<< "$backups"
        read -p "Номер для восстановления (0-отмена): " choice < /dev/tty
        if ! [[ "$choice" =~ ^[0-9]+$ ]] || [ "$choice" -eq 0 ] || [ "$choice" -ge "$i" ]; then log "Отмена."; return 1; fi
        bf="${bl[$choice]}";
    fi
    if [ ! -f "$bf" ]; then die "Файл бэкапа '$bf' не найден."; fi
    log "Восстановление из $bf"; if ! confirm_action "восстановить" "конфигурацию из '$bf'"; then return 1; fi
    log "Создание бэкапа текущей конфигурации..."; backup_configs;
    local td; td=$(mktemp -d); if ! tar -xzf "$bf" -C "$td"; then log_error "Ошибка tar $bf"; rm -rf "$td"; return 1; fi
    log "Остановка сервиса..."; systemctl stop awg-quick@awg0 || log_warn "Сервис не остановлен.";
    if [ -d "$td/server" ]; then log "Восстановление конфига сервера..."; cp -a "$td/server/"* /etc/amnezia/amneziawg/ || log_error "Ошибка копирования server"; chmod 600 /etc/amnezia/amneziawg/*.conf; fi
    if [ -d "$td/clients" ]; then log "Восстановление файлов клиентов..."; cp -a "$td/clients/"* "$AWG_DIR/" || log_error "Ошибка копирования clients"; chmod 600 "$AWG_DIR"/*.conf; fi
    rm -rf "$td";
    log "Запуск сервиса..."; if ! systemctl start awg-quick@awg0; then log_error "Ошибка запуска сервиса!"; systemctl status awg-quick@awg0 --no-pager | log_msg "ERROR"; return 1; fi
    log "Восстановление завершено.";
}
modify_client() {
    local name="$1"; local param="$2"; local value="$3";
    if [ -z "$name" ] || [ -z "$param" ] || [ -z "$value" ]; then log_error "Использование: modify <имя> <параметр> <значение>"; return 1; fi
    if ! grep -q "^#_Name = ${name}$" "$SERVER_CONF_FILE"; then die "Клиент '$name' не найден."; fi
    local cf="$AWG_DIR/$name.conf"; if [ ! -f "$cf" ]; then die "Файл $cf не найден."; fi
    # Проверяем, существует ли параметр в файле
    if ! grep -q -E "^${param}\s*=" "$cf"; then log_error "Параметр '$param' не найден в $cf."; return 1; fi
    log "Изменение '$param' на '$value' для '$name'..."; local bak="${cf}.bak-$(date +%F_%T)";
    cp "$cf" "$bak" || log_warn "Ошибка бэкапа $bak"; log "Создан бэкап $bak";
    # Используем # как разделитель в sed для безопасности, если значение содержит /
    if ! sed -i "s#^${param} = .*#${param} = ${value}#" "$cf"; then log_error "Ошибка sed. Восстановление..."; cp "$bak" "$cf" || log_warn "Ошибка восстановления."; return 1; fi
    log "Параметр '$param' изменен.";
    # Перегенерация QR-кода, если изменен важный параметр
    if [[ "$param" == "AllowedIPs" || "$param" == "Address" || "$param" == "PublicKey" || "$param" == "Endpoint" || "$param" == "PrivateKey" ]]; then
        log "Перегенерация QR-кода...";
        if command -v qrencode &>/dev/null; then
            if qrencode -o "$AWG_DIR/$name.png" < "$cf"; then log "QR-код обновлен."; else log_warn "Ошибка qrencode."; fi
        else log_warn "qrencode не найден (apt install qrencode)."; fi
    fi
    return 0;
}
check_server() {
    log "Проверка состояния сервера AmneziaWG..."; local ok=1;
    log "Статус сервиса:"; if ! systemctl status awg-quick@awg0 --no-pager; then ok=0; fi
    log "Интерфейс awg0:"; if ! ip addr show awg0 &>/dev/null; then log_error " - Интерфейс не найден!"; ok=0; else ip addr show awg0 | log_msg "INFO"; fi
    log "Прослушивание порта:"; source "$SETUP_CONFIG_FILE" &>/dev/null; local port=${AWG_PORT:-0}; if [ "$port" -eq 0 ]; then log_warn " - Не удалось определить порт."; else if ! ss -lunp | grep -q ":${port} "; then log_error " - Порт ${port}/udp НЕ прослушивается!"; ok=0; else log " - Порт ${port}/udp прослушивается."; fi; fi
    log "Настройки ядра:"; local fwd; fwd=$(sysctl -n net.ipv4.ip_forward); if [ "$fwd" != "1" ]; then log_error " - IP Forwarding выключен ($fwd)!"; ok=0; else log " - IP Forwarding включен."; fi
    log "Правила UFW:"; if command -v ufw &>/dev/null; then if ! ufw status | grep -qw "${port}/udp"; then log_warn " - Правило UFW для ${port}/udp не найдено!"; else log " - Правило UFW для ${port}/udp есть."; fi; else log_warn " - UFW не установлен."; fi
    log "Статус AmneziaWG:"; awg show | log_msg "INFO";
    if [ "$ok" -eq 1 ]; then log "Проверка завершена: Состояние OK."; else log_error "Проверка завершена: ОБНАРУЖЕНЫ ПРОБЛЕМЫ!"; fi
    return $ok;
}
list_clients() {
    log "Получение списка клиентов..."; local clients; clients=$(grep '^#_Name = ' "$SERVER_CONF_FILE" | sed 's/^#_Name = //' | sort) || clients="";
    if [ -z "$clients" ]; then log "Клиенты не найдены."; return 0; fi
    local verbose=0; if [[ "$1" == "-v" || "$1" == "--verbose" ]]; then verbose=1; fi
    local awg_stat; awg_stat=$(awg show 2>/dev/null) || awg_stat=""; local act=0; local tot=0;
    # Вывод заголовка таблицы
    if [ $verbose -eq 1 ]; then printf "%-20s | %-7s | %-7s | %-15s | %-15s | %s\n" "Имя клиента" "Conf" "QR" "IP-адрес" "Ключ (нач.)" "Статус"; printf -- "-%.0s" {1..85}; echo; else printf "%-20s | %-7s | %-7s | %s\n" "Имя клиента" "Conf" "QR" "Статус"; printf -- "-%.0s" {1..50}; echo; fi
    echo "$clients" | while IFS= read -r name; do
        name=$(echo "$name" | xargs); if [ -z "$name" ]; then continue; fi; ((tot++));
        local cf="?"; local png="?"; local pk="-"; local ip="-"; local st="Нет данных"; local color_st="\033[0;37m"; # Серый
        if [ -f "$AWG_DIR/${name}.conf" ]; then cf="✓"; fi; if [ -f "$AWG_DIR/${name}.png" ]; then png="✓"; fi
        if [ "$cf" = "✓" ]; then
            # Используем grep -oP для извлечения ключа, если grep поддерживает Perl-совместимые регулярки
            pk=$(grep -oP 'PublicKey = \K.*' "$AWG_DIR/${name}.conf" | head -c 10 2>/dev/null)"..." || pk="ошибка"
            ip=$(grep -oP 'Address = \K[0-9\.]+' "$AWG_DIR/${name}.conf" 2>/dev/null) || ip="ошибка"
            # Проверяем статус в awg show по IP адресу пира (AllowedIPs)
            if echo "$awg_stat" | grep -q "${ip}/32"; then
                 # Ищем строку с этим IP, затем смотрим handshake
                 local handshake_line; handshake_line=$(echo "$awg_stat" | grep -A 2 "${ip}/32" | grep 'latest handshake:')
                 if [[ -n "$handshake_line" && ! "$handshake_line" =~ "never" && ! "$handshake_line" =~ "ago" ]]; then
                     st="Активен"; color_st="\033[1;32m"; ((act++)); # Зеленый
                 elif [[ -n "$handshake_line" ]]; then
                      st="Недавно" # Желтый
                      color_st="\033[1;33m";
                      ((act++)); # Считаем активным, если был хендшейк
                 else
                     st="Не активен"; color_st="\033[0;37m"; # Серый
                 fi
            else
                 st="Не найден"; color_st="\033[0;31m"; # Красный
            fi
        fi
        # Вывод строки таблицы
        if [ $verbose -eq 1 ]; then printf "%-20s | %-7s | %-7s | %-15s | %-15s | ${color_st}%s${COLOR_RESET}\n" "$name" "$cf" "$png" "$ip" "$pk" "$st"; else printf "%-20s | %-7s | %-7s | ${color_st}%s${COLOR_RESET}\n" "$name" "$cf" "$png" "$st"; fi
    done | tee -a "$LOG_FILE" # Логируем вывод таблицы
    echo ""; log "Всего клиентов: $tot, Активных/Недавно: $act";
}
# Функция-обертка для запуска awgcfg.py
run_awgcfg() {
    log_debug "Вызов run_awgcfg из $(pwd): $*";
    if ! (cd "$AWG_DIR" && "$PYTHON_VENV_PATH" "$AWGCFG_SCRIPT_PATH" "$@"); then
        log_error "Ошибка выполнения awgcfg.py $*"; return 1;
    fi
    log_debug "awgcfg.py $* выполнен успешно."; return 0;
}

# --- Основная логика ---
check_dependencies || exit 1 # Проверяем зависимости перед переходом в директорию
cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR" # Переходим в рабочую директорию

# Перепарсиваем аргументы с учетом текущей структуры
COMMAND=""; CLIENT_NAME=""; PARAM=""; VALUE=""; VERBOSE_LIST=0;
i=0; args=("$@"); # Используем переданные аргументы
while [[ $i -lt ${#args[@]} ]]; do
    arg="${args[$i]}"
    case $arg in
        -h|--help) COMMAND="help" ;;
        -v|--verbose) VERBOSE_LIST=1 ;;
        add|remove|list|regen|modify|backup|restore|check|status|show|restart)
            if [ -z "$COMMAND" ]; then COMMAND=$arg; else ARGS+=("$arg"); fi ;;
        *) # Сохраняем остальные аргументы
            ARGS+=("$arg") ;;
    esac
    ((i++))
done
# Назначаем аргументы позиционно (простой вариант)
CLIENT_NAME="${ARGS[0]}"
PARAM="${ARGS[1]}"
VALUE="${ARGS[2]}"

if [ -z "$COMMAND" ]; then usage; fi
log "Запуск команды '$COMMAND'..."

case $COMMAND in
    add)      [ -z "$CLIENT_NAME" ] && die "Не указ. имя."; validate_client_name "$CLIENT_NAME" || exit 1; if grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then die "Клиент '$CLIENT_NAME' уже есть."; fi; log "Добавление '$CLIENT_NAME'..."; if run_awgcfg -a "$CLIENT_NAME"; then log "Клиент '$CLIENT_NAME' добавлен."; log "Генерация файлов..."; if run_awgcfg -c -q; then log "Файлы созданы/обновлены."; log "ВАЖНО: sudo systemctl restart awg-quick@awg0"; else log_error "Ошибка генерации файлов."; log_warn "Клиент добавлен, но файлы не акт-ны!"; fi; else log_error "Ошибка добавления клиента."; fi ;;
    remove)   [ -z "$CLIENT_NAME" ] && die "Не указ. имя."; if ! grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then die "Клиент '$CLIENT_NAME' не найден."; fi; if ! confirm_action "удалить" "клиента '$CLIENT_NAME'"; then exit 1; fi; log "Удаление '$CLIENT_NAME'..."; if run_awgcfg -d "$CLIENT_NAME"; then log "Клиент '$CLIENT_NAME' удален."; log "Удаление файлов..."; rm -f "$AWG_DIR/$CLIENT_NAME.conf" "$AWG_DIR/$CLIENT_NAME.png"; log "Файлы удалены."; log "ВАЖНО: sudo systemctl restart awg-quick@awg0"; else log_error "Ошибка удаления."; fi ;;
    list)     list_clients "$CLIENT_NAME" ;; # Передаем первый аргумент как возможный флаг verbose
    regen)    log "Перегенерация файлов..."; if [ -n "$CLIENT_NAME" ]; then if ! grep -q "^#_Name = ${CLIENT_NAME}$" "$SERVER_CONF_FILE"; then die "Клиент '$CLIENT_NAME' не найден."; fi; log "Перегенерация ВСЕХ (включая '$CLIENT_NAME')..."; else log "Перегенерация ВСЕХ..."; fi; if run_awgcfg -c -q; then log "Файлы перегенерированы."; else log_error "Ошибка перегенерации."; fi ;;
    modify)   modify_client "$CLIENT_NAME" "$PARAM" "$VALUE" ;;
    backup)   backup_configs ;;
    restore)  restore_backup "$CLIENT_NAME" ;; # Используем CLIENT_NAME как [файл]
    check|status) check_server ;;
    show)     log "Статус AmneziaWG..."; if ! awg show; then log_error "Ошибка awg show."; fi ;;
    restart)  log "Перезапуск сервиса..."; if ! confirm_action "перезапустить" "сервис"; then exit 1; fi; if ! systemctl restart awg-quick@awg0; then log_error "Ошибка перезапуска."; systemctl status awg-quick@awg0 --no-pager | log_msg "ERROR"; exit 1; else log "Сервис перезапущен."; fi ;;
    help)     usage ;;
    *)        log_error "Неизвестная команда: '$COMMAND'"; usage ;;
esac

log "Скрипт управления завершил работу."
exit 0
