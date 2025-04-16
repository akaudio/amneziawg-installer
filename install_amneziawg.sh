#!/bin/bash

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG на Ubuntu 24.04 LTS Minimal
# Автор: @bivlked
# Версия: 3.1
# Дата: 2025-04-16
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
set -o pipefail
AWG_DIR="/root/awg"; CONFIG_FILE="$AWG_DIR/setup.conf"; STATE_FILE="$AWG_DIR/setup_state"; CLIENT_TEMPLATE_FILE="$AWG_DIR/_defclient.config"; LOG_FILE="$AWG_DIR/install_amneziawg.log";
PYTHON_VENV=""; AWGCFG_SCRIPT=""; MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/manage_amneziawg.sh"; MANAGE_SCRIPT_PATH="$AWG_DIR/manage_amneziawg.sh"; SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf";
UNINSTALL=0; HELP=0; DIAGNOSTIC=0; VERBOSE=0; NO_COLOR=0; CLI_PORT=""; CLI_SUBNET=""; CLI_DISABLE_IPV6="default"; CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES="";

# --- Обработка аргументов ---
while [[ $# -gt 0 ]]; do case <span class="math-inline">1 in \-\-uninstall\) UNINSTALL\=1;; \-\-help\|\-h\) HELP\=1;; \-\-diagnostic\) DIAGNOSTIC\=1;; \-\-verbose\|\-v\) VERBOSE\=1;; \-\-no\-color\) NO\_COLOR\=1;; \-\-port\=\*\) CLI\_PORT\="</span>{1#*=}";; --subnet=*) CLI_SUBNET="<span class="math-inline">\{1\#\*\=\}";; \-\-allow\-ipv6\) CLI\_DISABLE\_IPV6\=0;; \-\-disallow\-ipv6\) CLI\_DISABLE\_IPV6\=1;; \-\-route\-all\) CLI\_ROUTING\_MODE\=1;; \-\-route\-amnezia\) CLI\_ROUTING\_MODE\=2;; \-\-route\-custom\=\*\) CLI\_ROUTING\_MODE\=3; CLI\_CUSTOM\_ROUTES\="</span>{1#*=}";; *) echo "Неизвестный аргумент: $1"; HELP=1;; esac; shift; done

# --- Функции ---
# Логирование (цвет всегда, если не отключен; log_debug восстановлен)
log_msg() {
    local type="$1"; local message="<span class="math-inline">2"; local timestamp; timestamp\=</span>(date +'%Y-%m-%d %H:%M:%S');
    local safe_message; safe_message=$(echo "$message" | sed 's/%/%%/g'); local log_entry="[$timestamp] $type: $safe_message"
    local color_start=""; local color_end="\033[0m";
    if [[ "$NO_COLOR" -eq 0 ]]; then # Проверяем флаг отключения цвета
        case "<span class="math-inline">type" in INFO\) color\_start\="\\033\[0;32m";; WARN\) color\_start\="\\033\[0;33m";; ERROR\) color\_start\="\\033\[1;31m";; DEBUG\) color\_start\="\\033\[0;36m";; \*\) color\_start\=""; color\_end\="";; esac;
fi
\# Запись в лог
if \! mkdir \-p "</span>(dirname "$LOG_FILE")" || ! echo "$log_entry" >> "$LOG_FILE"; then echo "[$timestamp] ERROR: Ошибка записи лога $LOG_FILE" >&2; fi
    # Вывод на экран
    # Debug выводим только если VERBOSE=1
    if [[ "$type" == "DEBUG" && "$VERBOSE" -eq 0 ]]; then return; fi
    # Остальное выводим всегда
    if [[ "$type" == "ERROR" || "<span class="math-inline">type" \=\= "WARN" \]\]; then printf "</span>{color_start}%s${color_end}\n" "<span class="math-inline">entry" \>&2;
else printf "</span>{color_start}%s${color_end}\n" "$entry"; fi
}
log() { log_msg "INFO" "$1"; }; log_warn() { log_msg "WARN" "$1"; }; log_error() { log_msg "ERROR" "$1"; }; log_debug() { log_msg "DEBUG" "$1"; }; die() { log_error "КРИТИЧЕСКАЯ ОШИБКА: $1"; log_error "Установка прервана. Лог: $LOG_FILE"; exit 1; }
# Справка
show_help() {
    # Полный текст справки
    cat << EOF
Использование: $0 [ОПЦИИ]
Скрипт для автоматической установки и настройки AmneziaWG на Ubuntu 24.04.

Опции:
  -h, --help            Показать эту справку и выйти
  --uninstall           Удалить AmneziaWG и все его конфигурации
  --diagnostic          Создать диагностический отчет и выйти
  -v, --verbose         Расширенный вывод для отладки (включая DEBUG)
  --no-color            Отключить цветной вывод в терминале
  --port=НОМЕР          Установить UDP порт (1024-65535) неинтерактивно
  --subnet=ПОДСЕТЬ      Установить подсеть туннеля (x.x.x.x/yy) неинтерактивно
  --allow-ipv6          Оставить IPv6 включенным неинтерактивно
  --disallow-ipv6       Принудительно отключить IPv6 неинтерактивно
  --route-all           Использовать режим 'Весь трафик' неинтерактивно
  --route-amnezia       Использовать режим 'Amnezia' неинтерактивно
  --route-custom=СЕТИ   Использовать режим 'Пользовательский' неинтерактивно

Примеры:
  sudo bash $0                             # Интерактивная установка
  sudo bash $0 --port=51820 --route-all    # Неинтерактивная установка с параметрами
  sudo bash $0 --uninstall                 # Удаление
  sudo bash $0 --diagnostic                # Диагностика

Репозиторий: https://github.com/bivlked/amneziawg-installer
EOF
exit 0; }
# Управление состоянием и перезагрузка
update_state() { local next_step=<span class="math-inline">1; mkdir \-p "</span>(dirname "$STATE_FILE")"; echo "$next_step" > "$STATE_FILE" || die "Ошибка записи состояния"; log "Состояние: следующий шаг - $next_step"; }
request_reboot() { local next_step=$1; update_state "$next_step"; echo "" >> "$LOG_FILE"; log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; log_warn "!!! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА СИСТЕМЫ !!!"; log_warn "!!! После перезагрузки, запустите скрипт снова командой:"; log_warn "!!! sudo bash $0 [с теми же параметрами, если были]"; log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"; echo "" >> "$LOG_FILE"; read -p "Перезагрузить сейчас? [y/N]: " confirm < /dev/tty; if [[ "<span class="math-inline">confirm" \=\~ ^\[Yy\]</span> ]]; then log "Инициирована перезагрузка..."; sleep 5; if ! reboot; then die "Команда reboot не удалась."; fi; exit 1; else log "Перезагрузка отменена. Перезагрузитесь вручную и запустите скрипт снова."; exit 1; fi; }
# Проверки окружения
check_os_version() { log "Проверка ОС..."; if ! command -v lsb_release &> /dev/null; then log_warn "lsb_release не найден."; return 0; fi; local os_id; os_id=<span class="math-inline">\(lsb\_release \-si\); local os\_ver; os\_ver\=</span>(lsb_release -sr); if [[ "$os_id" != "Ubuntu" || "$os_ver" != "24.04" ]]; then log_warn "Обнаружена $os_id $os_ver. Скрипт для Ubuntu 24.04."; read -p "Продолжить? [y/N]: " confirm < /dev/tty; if ! [[ "<span class="math-inline">confirm" \=\~ ^\[Yy\]</span> ]]; then die "Отмена."; fi; else log "ОС: Ubuntu <span class="math-inline">os\_ver \(OK\)"; fi; \}
check\_free\_space\(\) \{ log "Проверка места\.\.\."; local req\=2048; local avail; avail\=</span>(df -m / | awk 'NR==2 {print $4}'); if [[ -z "$avail" ]]; then log_warn "Не удалось определить свободное место."; return 0; fi; if [ "$avail" -lt "$req" ]; then log_warn "Доступно $avail МБ. Рекомендуется >= $req МБ."; read -p "Продолжить? [y/N]: " confirm < /dev/tty; if ! [[ "<span class="math-inline">confirm" \=\~ ^\[Yy\]</span> ]]; then die "Отмена."; fi; else log "Свободно: $avail МБ (OK)"; fi; }
check_port_availability() { local port=$1; log "Проверка порта <span class="math-inline">port\.\.\."; local proc; proc\=</span>(ss -lunp | grep ":${port} "); if [[ -n "$proc" ]]; then log_error "Порт ${port}/udp уже используется! Процесс: $proc"; return 1; else log "Порт <span class="math-inline">port/udp свободен\."; return 0; fi; \}
\# Установка пакетов
install\_packages\(\) \{ local packages\=\("</span>@"); local to_install=(); local pkg; log "Проверка пакетов: <span class="math-inline">\{packages\[\*\]\}\.\.\."; for pkg in "</span>{packages[@]}"; do if ! dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "ok installed"; then to_install+=("$pkg"); fi; done; if [ ${#to_install[@]} -eq 0 ]; then log "Все пакеты уже установлены."; return 0; fi; log "Установка: <span class="math-inline">\{to\_install\[\*\]\}\.\.\."; apt update \-y \|\| log\_warn "Не удалось обновить apt\."; DEBIAN\_FRONTEND\=noninteractive apt install \-y "</span>{to_install[@]}" || die "Ошибка установки пакетов."; log "Пакеты установлены."; }
# Очистка apt
cleanup_apt() { log "Очистка apt..."; apt-get clean || log_warn "Ошибка apt-get clean"; rm -rf /var/lib/apt/lists/* || log_warn "Ошибка rm /var/lib/apt/lists/*"; log "Кэш apt очищен."; }
# Настройка IPv6 и Маршрутизации
configure_ipv6() { if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then DISABLE_IPV6=$CLI_DISABLE_IPV6; log "IPv6 из CLI: $DISABLE_IPV6"; else read -p "Отключить IPv6? [Y/n]: " dis_ipv6 < /dev/tty; if [[ "<span class="math-inline">dis\_ipv6" \=\~ ^\[Nn\]</span> ]]; then DISABLE_IPV6=0; else DISABLE_IPV6=1; fi; fi; export DISABLE_IPV6; log "Отключение IPv6: $(if [ "$DISABLE_IPV6" -eq 1 ]; then echo 'Да'; else echo 'Нет'; fi)"; }
configure_routing_mode() { if [[ "$CLI_ROUTING_MODE" != "default" ]]; then ALLOWED_IPS_MODE=$CLI_ROUTING_MODE; if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then ALLOWED_IPS=$CLI_CUSTOM_ROUTES; if [ -z "$ALLOWED_IPS" ]; then die "Не указаны сети для --route-custom."; fi; fi; log "Режим маршрутизации из CLI: <span class="math-inline">ALLOWED\_IPS\_MODE"; else echo ""; log "Выберите режим маршрутизации\:"; echo "  1\) Весь трафик \(0\.0\.0\.0/0\)"; echo "  2\) Список Amnezia\+DNS \(умолч\.\)"; echo "  3\) Только указанные сети"; read \-p "Выбор \[2\]\: " r\_mode < /dev/tty; ALLOWED\_IPS\_MODE\=</span>{r_mode:-2}; fi; case "$ALLOWED_IPS_MODE" in 1) ALLOWED_IPS="0.0.0.0/0"; log "Выбран режим: Весь трафик.";; 3) if [[ -z "$CLI_CUSTOM_ROUTES" ]]; then read -p "Введите сети (a.b.c.d/xx,...): " custom < /dev/tty; ALLOWED_IPS=$custom; else ALLOWED_IPS=$CLI_CUSTOM_ROUTES; fi; if ! echo "<span class="math-inline">ALLOWED\_IPS" \| grep \-qE '^\(\[0\-9\]\{1,3\}\\\.\)\{3\}\[0\-9\]\{1,3\}/\[0\-9\]\{1,2\}\(,\(\[0\-9\]\{1,3\}\\\.\)\{3\}\[0\-9\]\{1,3\}/\[0\-9\]\{1,2\}\)\*</span>'; then log_warn "Формат сетей ('$ALLOWED_IPS') некорректен."; fi; log "Выбран режим: Пользовательский ($ALLOWED_IPS)";; *) ALLOWED_IPS_MODE=2; ALLOWED_IPS="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"; log "Выбран режим: Список Amnezia+DNS.";; esac; if [ -z "$ALLOWED_IPS" ]; then die "Не удалось определить AllowedIPs."; fi; if [[ "<span class="math-inline">ALLOWED\_IPS\_MODE" \-eq 3 \]\]; then ALLOWED\_IPS\_SAVE\=</span>(echo "$ALLOWED_IPS" | sed 's/,/\\,/g'); else ALLOWED_IPS_SAVE="$ALLOWED_IPS"; fi; export ALLOWED_IPS_MODE ALLOWED_IPS ALLOWED_IPS_SAVE; }
run_awgcfg() { log_debug "Вызов run_awgcfg из $(pwd): $*"; if [ ! -x "$PYTHON_VENV" ] || [ ! -x "$AWGCFG_SCRIPT" ]; then log_error "Python venv или awgcfg.py недоступен."; return 1; fi; if ! (cd "$AWG_DIR" && "$PYTHON_VENV" "<span class="math-inline">AWGCFG\_SCRIPT" "</span>@"); then log_error "Ошибка выполнения awgcfg.py $*"; return 1; fi; log_debug "awgcfg.py <span class="math-inline">\* выполнен успешно\."; return 0; \}
check\_service\_status\(\) \{ log "Проверка статуса сервиса\.\.\."; local ok\=1; if \! systemctl is\-active \-\-quiet awg\-quick@awg0 && \! systemctl is\-failed \-\-quiet awg\-quick@awg0; then local state; state\=</span>(systemctl show -p SubState --value awg-quick@awg0 2>/dev/null) || state="unknown"; if [[ "$state" != "exited" ]]; then log_warn "Статус сервиса: <span class="math-inline">state"; fi; fi; if systemctl is\-failed \-\-quiet awg\-quick@awg0; then log\_error "Сервис FAILED\!"; ok\=0; fi; if \! ip addr show awg0 &\>/dev/null; then log\_error "Интерфейс awg0 не найден\!"; ok\=0; fi; if \! awg show \| grep \-q "interface\: awg0"; then log\_error "awg show не видит интерфейс\!"; ok\=0; fi; local port\_check\=</span>{AWG_PORT:-0}; if [ "$port_check" -eq 0 ] && [ -f "<span class="math-inline">CONFIG\_FILE" \]; then port\_check\=</span>(source "$CONFIG_FILE" && echo "<span class="math-inline">AWG\_PORT"\); port\_check\=</span>{port_check:-0}; fi; if [ "<span class="math-inline">port\_check" \-ne 0 \]; then if \! ss \-lunp \| grep \-q "\:</span>{port_check} "; then log_error "Порт $port_check/udp не прослушивается!"; ok=0; fi; else log_warn "Не удалось проверить порт."; fi; if [ "$ok" -eq 1 ]; then log "Статус сервиса и интерфейса OK."; return 0; else return 1; fi; }

# --- Шаг 0: Инициализация ---
initialize_setup() {
    mkdir -p "$AWG_DIR" || die "Ошибка создания $AWG_DIR"; chown root:root "$AWG_DIR";
    touch "$LOG_FILE" || die "Не удалось создать лог-файл $LOG_FILE"; chmod 640 "<span class="math-inline">LOG\_FILE";
log "\-\-\- НАЧАЛО УСТАНОВКИ / ПРОВЕРКА СОСТОЯНИЯ \-\-\-"; log "\#\#\# ШАГ 0\: Инициализация и проверка параметров \#\#\#";
if \[ "</span>(id -u)" -ne 0 ]; then die "Запустите скрипт от root (sudo bash $0)."; fi
    cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"; log "Рабочая директория: $AWG_DIR"; log "Лог файл: $LOG_FILE";
    PYTHON_VENV="$AWG_DIR/venv/bin/python"; AWGCFG_SCRIPT="$AWG_DIR/awgcfg.py";
    check_os_version; check_free_space;
    local default_port=39743; local default_subnet="10.9.9.1/24"; local config_exists=0;
    local loaded_port=""; local loaded_subnet=""; local loaded_disable_ipv6=""; local loaded_ips_mode=""; local loaded_ips="";
    # Загрузка конфига
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Найден файл конфигурации $CONFIG_FILE. Загрузка настроек..."; config_exists=1;
        source "$CONFIG_FILE" || log_warn "Не удалось полностью загрузить настройки из <span class="math-inline">CONFIG\_FILE\.";
AWG\_PORT\=</span>{AWG_PORT:-<span class="math-inline">default\_port\}; AWG\_TUNNEL\_SUBNET\=</span>{AWG_TUNNEL_SUBNET:-<span class="math-inline">default\_subnet\}; DISABLE\_IPV6\=</span>{DISABLE_IPV6:-"default"}; ALLOWED_IPS_MODE=<span class="math-inline">\{ALLOWED\_IPS\_MODE\:\-"default"\}; ALLOWED\_IPS\=</span>{ALLOWED_IPS:-""};
        log "Настройки из файла загружены.";
    else
        log "Файл конфигурации $CONFIG_FILE не найден."; AWG_PORT=$default_port; AWG_TUNNEL_SUBNET=<span class="math-inline">default\_subnet; DISABLE\_IPV6\="default"; ALLOWED\_IPS\_MODE\="default"; ALLOWED\_IPS\="";
fi
\# Переопределение из CLI
AWG\_PORT\=</span>{CLI_PORT:-<span class="math-inline">AWG\_PORT\}; AWG\_TUNNEL\_SUBNET\=</span>{CLI_SUBNET:-$AWG_TUNNEL_SUBNET};
    if [[ "$CLI_DISABLE_IPV6" != "default" ]]; then DISABLE_IPV6=$CLI_DISABLE_IPV6; fi
    if [[ "$CLI_ROUTING_MODE" != "default" ]]; then ALLOWED_IPS_MODE=$CLI_ROUTING_MODE; if [[ "$CLI_ROUTING_MODE" -eq 3 ]]; then ALLOWED_IPS=$CLI_CUSTOM_ROUTES; fi; fi

    # Запрашиваем, если конфига НЕ БЫЛО или параметры не были заданы через CLI
    if [[ "$config_exists" -eq 0 || -z "$CLI_PORT" || -z "$CLI_SUBNET" || "$CLI_DISABLE_IPV6" == "default" || "<span class="math-inline">CLI\_ROUTING\_MODE" \=\= "default" \]\]; then
log "Запрос/Подтверждение настроек у пользователя\.";
\# Используем read < /dev/tty для чтения с терминала
read \-p "Введите UDP порт AmneziaWG \(1024\-65535\) \[</span>{AWG_PORT}]: " input_port < /dev/tty; if [[ -n "$input_port" ]]; then AWG_PORT=$input_port; fi; if ! [[ "<span class="math-inline">AWG\_PORT" \=\~ ^\[0\-9\]\+</span> ]] || [ "$AWG_PORT" -lt 1024 ] || [ "<span class="math-inline">AWG\_PORT" \-gt 65535 \]; then die "Некорректный порт\."; fi
read \-p "Введите подсеть туннеля \[</span>{AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty; if [[ -n "$input_subnet" ]]; then AWG_TUNNEL_SUBNET=$input_subnet; fi; if ! [[ "<span class="math-inline">AWG\_TUNNEL\_SUBNET" \=\~ ^\(\[0\-9\]\{1,3\}\\\.\)\{3\}\[0\-9\]\{1,3\}/\[0\-9\]\{1,2\}</span> ]]; then printf "ERROR: Некорр. подсеть: '$AWG_TUNNEL_SUBNET'.\n">&2; exit 1; fi
         # Запрашиваем остальные, только если не заданы через CLI
         if [[ "$DISABLE_IPV6" == "default" ]]; then configure_ipv6; fi
         if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then configure_routing_mode; fi
    else
         # Если все задано через CLI/config, просто устанавливаем переменные
         log "Используются настройки из $CONFIG_FILE или аргументов CLI.";
         if [[ "$DISABLE_IPV6" == "default" ]]; then DISABLE_IPV6=1; fi # Дефолт, если не загрузился
         if [[ "$ALLOWED_IPS_MODE" == "default" ]]; then configure_routing_mode; fi # Запустит с дефолтом
    fi

    # Финальная проверка порта
    check_port_availability "$AWG_PORT" || die "Выбранный порт $AWG_PORT/udp занят.";

    # Гарантированное сохранение setup.conf
    log "Сохранение/Обновление настроек в <span class="math-inline">CONFIG\_FILE\.\.\."; local temp\_conf; temp\_conf\=</span>(mktemp) || die "Ошибка mktemp.";
    printf "%s\n" "# Конфигурация установки AmneziaWG (Авто)" > "$temp_conf" || die "Ошибка записи"; printf "%s\n" "# Используется скриптом управления" >> "<span class="math-inline">temp\_conf";
printf "export AWG\_PORT\=%s\\n" "</span>{AWG_PORT}" >> "<span class="math-inline">temp\_conf"; printf "export AWG\_TUNNEL\_SUBNET\='%s'\\n" "</span>{AWG_TUNNEL_SUBNET}" >> "<span class="math-inline">temp\_conf";
printf "export DISABLE\_IPV6\=%s\\n" "</span>{DISABLE_IPV6}" >> "<span class="math-inline">temp\_conf"; printf "export ALLOWED\_IPS\_MODE\=%s\\n" "</span>{ALLOWED_IPS_MODE}" >> "<span class="math-inline">temp\_conf";
local saved\_ips; saved\_ips\=</span>(echo "<span class="math-inline">ALLOWED\_IPS" \| sed 's/\\\\,/,/g'\); printf "export ALLOWED\_IPS\='%s'\\n" "</span>{saved_ips}" >> "$temp_conf";
    if ! mv "$temp_conf" "$CONFIG_FILE"; then rm -f "$temp_conf"; die "Ошибка сохранения $CONFIG_FILE"; fi; chmod 600 "$CONFIG_FILE" || log_warn "Ошибка chmod $CONFIG_FILE"; log "Настройки сохранены.";
    export AWG_PORT AWG_TUNNEL_SUBNET DISABLE_IPV6 ALLOWED_IPS_MODE ALLOWED_IPS; # Экспорт для скрипта
    log "Порт: ${AWG_PORT}/udp"; log "Подсеть: ${AWG_TUNNEL_SUBNET}"; log "Откл. IPv6: $DISABLE_IPV6"; log "Режим AllowedIPs: $ALLOWED_IPS_MODE";

    # Загрузка состояния
    if [[ -f "<span class="math-inline">STATE\_FILE" \]\]; then current\_step\=</span>(cat "$STATE_FILE"); if ! [[ "<span class="math-inline">current\_step" \=\~ ^\[0\-9\]\+</span> ]]; then log_warn "$STATE_FILE поврежден."; current_step=1; update_state 1; else log "Продолжение с шага $current_step."; fi; else current_step=1; log "Начало с шага 1."; update_state 1; fi
    log "Шаг 0 завершен.";
}

# --- Функции для шагов установки ---

# ШАГ 1: Обновление системы и настройка ядра
step1_update_system_and_networking() {
    update_state 1; log "### ШАГ 1: Обновление и настройка ядра ###";
    log "Обновление списка пакетов..."; apt update -y || die "Ошибка apt update.";
    log "Разблокировка dpkg..."; if fuser /var/lib/dpkg/lock* &>/dev/null; then log_warn "dpkg заблокирован..."; DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."; fi
    log "Обновление системы..."; DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "Ошибка apt full-upgrade."; log "Система обновлена.";
    install_packages curl wget gpg sudo net-tools; setup_advanced_sysctl;
    log "Шаг 1 успешно завершен."; request_reboot 2;
}

# ШАГ 2: Установка AmneziaWG и зависимостей
step2_install_amnezia() {
    update_state 2; log "### ШАГ 2: Установка AmneziaWG и зависимостей ###"; local sources_file="/etc/apt/sources.list.d/ubuntu.sources";
    log "Проверка/включение deb-src..."; if [ ! -f "$sources_file" ]; then die "<span class="math-inline">sources\_file не найден\."; fi;
if grep \-q "^Types\: deb</span>" "<span class="math-inline">sources\_file"; then log "Включение deb\-src\.\.\."; local bak\="</span>{sources_file}.bak-$(date +%F_%T)"; cp "$sources_file" "<span class="math-inline">bak" \|\| log\_warn "Ошибка бэкапа"; local tmp\_sed; tmp\_sed\=</span>(mktemp); sed '/^Types: deb$/s/Types: deb/Types: deb deb-src/' "$sources_file" > "$tmp_sed" || { rm -f "$tmp_sed"; die "Ошибка sed."; }; if ! mv "$tmp_sed" "$sources_file"; then rm -f "$tmp_sed"; die "Ошибка mv <span class="math-inline">sources\_file"; fi; if grep \-q "^Types\: deb</span>" "$sources_file"; then log_warn "Не удалось включить deb-src."; else log "deb-src добавлены."; fi; apt update -y || die "Ошибка apt update.";
    elif ! grep -q "Types: deb deb-src" "$sources_file"; then log_warn "Структура <span class="math-inline">sources\_file нестандартная\."; apt update \-y \|\| die "Ошибка apt update\."; else log "deb\-src включены\."; apt update \-y; fi
log "Добавление PPA Amnezia\.\.\."; local ppa\_list\="/etc/apt/sources\.list\.d/amnezia\-ubuntu\-ppa\-</span>(lsb_release -sc).list"; local ppa_sources="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).sources"; if [ ! -f "$ppa_list" ] && [ ! -f "<span class="math-inline">ppa\_sources" \]; then DEBIAN\_FRONTEND\=noninteractive add\-apt\-repository \-y ppa\:amnezia/ppa \|\| die "Ошибка PPA\."; log "PPA добавлен\."; apt update \-y \|\| die "Ошибка apt update\."; else log "PPA уже добавлен\."; apt update \-y \|\| die "Ошибка apt update\."; fi
log "Установка пакетов AmneziaWG\.\.\."; local packages\=\("amneziawg\-dkms" "amneziawg\-tools" "wireguard\-tools" "dkms" "linux\-headers\-</span>(uname -r)" "build-essential" "dpkg-dev"); if ! dpkg -s "linux-headers-$(uname -r)" &> /dev/null; then log_warn "Нет headers для <span class="math-inline">\(uname \-r\)\.\.\."; packages\+\=\( "linux\-headers\-generic" \); fi; install\_packages "</span>{packages[@]}";
    log "Проверка статуса DKMS..."; local dkms_stat; dkms_stat=$(dkms status 2>&1); if ! echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then log_warn "DKMS статус не OK."; log_msg "WARN" "<span class="math-inline">dkms\_stat"; else log "DKMS статус OK\."; fi
log "Шаг 2 завершен\."; request\_reboot 3;
\}
\# ШАГ 3\: Проверка загрузки модуля ядра
step3\_check\_module\(\) \{
update\_state 3; log "\#\#\# ШАГ 3\: Проверка модуля ядра \#\#\#"; sleep 2;
if \! lsmod \| grep \-q \-w amneziawg; then log "Модуль не загружен\. Загрузка\.\.\."; modprobe amneziawg \|\| die "Ошибка modprobe amneziawg\."; log "Модуль загружен\."; local mf\="/etc/modules\-load\.d/amneziawg\.conf"; mkdir \-p "</span>(dirname "$mf")"; if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then echo "amneziawg" > "$mf" || log_warn "Ошибка записи $mf"; log "Добавлено в <span class="math-inline">mf\."; fi; else log "Модуль amneziawg загружен\."; fi
log "Информация о модуле\:"; modinfo amneziawg \| grep \-E "filename\|version\|vermagic\|srcversion" \| log\_msg "INFO"; local cv; cv\=</span>(modinfo amneziawg | grep vermagic | awk '{print <span class="math-inline">2\}'\) \|\| cv\="?"; local kr; kr\=</span>(uname -r); if [[ "$cv" != "$kr" ]]; then log_warn "VerMagic НЕ совпадает: Модуль($cv) != Ядро($kr)!"; else log "VerMagic совпадает."; fi
    log "Шаг 3 завершен."; update_state 4;
}

# ШАГ 4: Настройка фаервола (UFW)
step4_setup_firewall() {
    update_state 4; log "### ШАГ 4: Настройка фаервола UFW ###";
    install_packages ufw;
    setup_improved_firewall || die "Ошибка настройки UFW.";
    log "Шаг 4 завершен."; update_state 5;
}

# ШАГ 5: Python, утилиты, скрипт управления
step5_setup_python() {
    update_state 5; log "### ШАГ 5: Python, утилиты, скрипт управления ###";
    install_packages python3-venv python3-pip;
    cd "$AWG_DIR" || die "Ошибка перехода в $AWG_DIR"
    if [ ! -d "venv" ]; then log "Создание venv..."; python3 -m venv venv || die "Ошибка создания venv."; log "Venv создано."; else log "Venv уже существует."; fi
    log "Установка qrcode[pil] в venv..."; if [ ! -x "$PYTHON_VENV" ]; then die "Нет $PYTHON_VENV"; fi
    "$PYTHON_VENV" -m pip install -U pip || die "Ошибка обновления pip."; "$PYTHON_VENV" -m pip install qrcode[pil] || die "Ошибка установки qrcode[pil]."; log "Зависимости Python установлены."
    if [ ! -f "$AWGCFG_SCRIPT" ]; then log "Скачивание $AWGCFG_SCRIPT..."; curl -fLso "$AWGCFG_SCRIPT" https://gist.githubusercontent.com/remittor/8c3d9ff293b2ba4b13c367cc1a69f9eb/raw/awgcfg.py || die "Ошибка скачивания $AWGCFG_SCRIPT."; chmod +x "$AWGCFG_SCRIPT" || die "Ошибка chmod."; log "$AWGCFG_SCRIPT скачан."; elif [ ! -x "$AWGCFG_SCRIPT" ]; then chmod +x "$AWGCFG_SCRIPT" || die "Ошибка chmod."; log "$AWGCFG_SCRIPT исполняемый."; else log "$AWGCFG_SCRIPT существует."; fi
    log "Скачивание $MANAGE_SCRIPT_PATH..."; if curl -fLso "$MANAGE_SCRIPT_PATH" "$MANAGE_SCRIPT_URL"; then chmod +x "$MANAGE_SCRIPT_PATH" || die "Ошибка chmod."; log "$MANAGE_SCRIPT_PATH скачан."; else log_error "Ошибка скачивания $MANAGE_SCRIPT_PATH"; fi
    log "Шаг 5 завершен."; update_state 6;
}

# ШАГ 6: Генерация конфигураций
step6_generate_configs() {
    update_state 6; log "### ШАГ 6: Генерация конфигураций ###"; cd "$AWG_DIR" || die "Ошибка cd $AWG_DIR";
    local s_dir="/etc/amnezia/amneziawg"; local s_file="$s_dir/awg0.conf"; mkdir -p "$s_dir" || die "Ошибка mkdir $s_dir";
    log "Генерация конфига сервера..."; run_awgcfg --make "<span class="math-inline">s\_file" \-i "</span>{AWG_TUNNEL_SUBNET}" -p "<span class="math-inline">\{AWG\_PORT\}" \|\| die "Ошибка генерации конфига сервера\."; log "Конфиг сервера сгенерирован\."
local s\_bak\="</span>{s_file}.bak-$(date +%F_%T)"; cp "$s_file" "$s_bak" || log_warn "Ошибка бэкапа $s_bak"; log "Создан бэкап $s_bak";
    log "Кастомизация шаблона $CLIENT_TEMPLATE_FILE..."; if [ ! -f "<span class="math-inline">CLIENT\_TEMPLATE\_FILE" \]; then log "Создание шаблона\.\.\."; run\_awgcfg \-\-create \|\| die "Ошибка создания шаблона\."; log "Шаблон создан\."; else log "Шаблон существует\."; local t\_bak\="</span>{CLIENT_TEMPLATE_FILE}.bak-$(date +%F_%T)"; cp "$CLIENT_TEMPLATE_FILE" "<span class="math-inline">t\_bak" \|\| log\_warn "Ошибка бэкапа шаблона\."; fi
log "Применение настроек к шаблону\:"; local sed\_fail\=0;
local sed\_allowed\_ips; sed\_allowed\_ips\=</span>(echo "$ALLOWED_IPS" | sed 's/\\,/,/g');
    sed -i 's/^DNS = .*/DNS = 1.1.1.1/' "$CLIENT_TEMPLATE_FILE" && log " - DNS: 1.1.1.1" || { log_warn "Ошибка sed DNS."; sed_fail=1; };
    sed -i 's/^PersistentKeepalive = .*/PersistentKeepalive = 33/' "$CLIENT_TEMPLATE_FILE" && log " - Keepalive: 33" || { log_warn "Ошибка sed Keepalive."; sed_fail=1; };
    sed -i "s#^AllowedIPs = .*#AllowedIPs = ${sed_allowed_ips}#" "$CLIENT_TEMPLATE_FILE" && log " - AllowedIPs: Mode $ALLOWED_IPS_MODE" || { log_warn "Ошибка sed AllowedIPs."; sed_fail=1; };
    if [ "<span class="math-inline">sed\_fail" \-eq 1 \]; then log\_warn "Не все настройки шаблона применены\."; fi; log "Шаблон кастомизирован\."
log "Добавление клиентов по умолчанию\.\.\."; if \! grep \-q "^\#\_Name \= my\_phone</span>" "<span class="math-inline">s\_file"; then run\_awgcfg \-a "my\_phone" \|\| log\_warn "Ошибка add my\_phone\."; else log "Клиент my\_phone существует\."; fi; if \! grep \-q "^\#\_Name \= my\_laptop</span>" "$s_file"; then run_awgcfg -a "my_laptop" || log_warn "Ошибка add my_laptop."; else log "Клиент my_laptop существует."; fi;
    log "Генерация клиентских файлов..."; run_awgcfg -c -q || die "Ошибка генерации клиентских файлов.";
    log "Клиентские файлы созданы/обновлены в $AWG_DIR:"; ls -l "$AWG_DIR"/*.conf "$AWG_DIR"/*.png | log_msg "INFO";
    secure_files; # Установка прав доступа
    log "Шаг 6 завершен."; update_state 7;
}

# ШАГ 7: Запуск сервиса и доп. настройки
step7_start_service_and_extras() {
    update_state 7; log "### ШАГ 7: Запуск сервиса и доп. настройки ###";
    log "Включение и запуск awg-quick@awg0..."; systemctl enable --now awg-quick@awg0 || die "Ошибка enable --now."; log "Сервис включен и запущен."
    log "Проверка статуса сервиса..."; sleep 3; check_service_status || die "Проверка статуса сервиса не пройдена."
    log "Настройка дополнительных компонентов...";
    # setup_fail2ban; # Убрано
    setup_auto_updates; setup_backups; setup_log_rotation;
    log "Шаг 7 завершен."; update_state 99;
}

# ШАГ 99: Завершение
step99_finish() {
    log "### ЗАВЕРШЕНИЕ УСТАНОВКИ ###"; log "=============================================================================="; log "Установка и настройка AmneziaWG УСПЕШНО ЗАВЕРШЕНА!"; log " ";
    log "КЛИЕНТСКИЕ ФАЙЛЫ:"; log "  Конфиги (.conf) и QR-коды (.png) в: $AWG_DIR"; log "  Скопируйте их безопасным способом."; log "  Пример (на вашем ПК):"; log "    scp root@<IP_СЕРВЕРА>:$AWG_DIR/*.conf ./"; log " ";
    log "ПОЛЕЗНЫЕ КОМАНДЫ:"; log "  sudo bash $MANAGE_SCRIPT_PATH help # Управление клиентами"; log "  systemctl status awg-quick@awg0  # Статус VPN"; log "  awg show                         # Статус WG"; log "  ufw status verbose               # Статус Firewall"; log " ";
    log "Очистка apt..."; cleanup_apt; log " ";
    if [ -f "$CONFIG_FILE" ]; then log "Файл настроек $CONFIG_FILE существует."; else log_error "Файл настроек $CONFIG_FILE ОТСУТСТВУЕТ!"; fi
    # Удаляем файл состояния после успешного завершения
    log "Удаление файла состояния установки..."; rm -f "$STATE_FILE" || log_warn "Не удалось удалить $STATE_FILE";
    log "Установка полностью завершена. Лог: $LOG_FILE"; log "==============================================================================";
}

# Функция деинсталляции
step_uninstall() {
    log "### ДЕИНСТАЛЛЯЦИЯ AMNEZIAWG ###";
    echo ""; echo "ВНИМАНИЕ! Полное удаление AmneziaWG и конфигураций."; echo "Процесс необратим!"; echo "";
    read -p "Уверены? (введите 'yes'): " confirm < /dev/tty; if [[ "$confirm" != "yes" ]]; then log "Деинсталляция отменена."; exit 1; fi;
    read -p "Создать бэкап перед удалением? [Y/n]: " backup < /dev/tty;
    if [[ -z "$backup" || "<span class="math-inline">backup" \=\~ ^\[Yy\]</span> ]]; then
         local bf="<span class="math-inline">HOME/awg\_uninstall\_backup\_</span>(date +%F_%T).tar.gz"; log "Создание бэкапа: $bf";
         tar -czf "$bf" -C / etc/amnezia "$AWG_DIR" --ignore-failed-read 2>/dev/null || log_warn "Ошибка создания бэкапа $bf";
         chmod 600 "$bf" || log_warn "Ошибка chmod бэкапа"; log "Бэкап создан: $bf";
    fi
    log "Остановка сервиса..."; systemctl stop awg-quick@awg0 &>/dev/null; systemctl disable awg-quick@awg0 &>/dev/null;
    log "Удаление правил UFW..."; if command -v ufw &>/dev/null; then local port_to_del; if [ -f "<span class="math-inline">CONFIG\_FILE" \]; then port\_to\_del\=</span>(source "$CONFIG_FILE" && echo "<span class="math-inline">AWG\_PORT"\); fi; port\_to\_del\=</span>{port_to_del:-39743}; ufw delete allow "${port_to_del}/udp" &>/dev/null; ufw delete limit 22/tcp &>/dev/null; fi
    log "Удаление пакетов..."; DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools unattended-upgrades &>/dev/null || log_warn "Ошибка purge."; DEBIAN_FRONTEND=noninteractive apt-get autoremove -y &>/dev/null || log_warn "Ошибка autoremove.";
    log "Удаление файлов..."; rm -rf /etc/amnezia "$AWG_DIR" /etc/modules-load.d/amneziawg.conf /etc/sysctl.d/10-amneziawg-forward.conf /etc/sysctl.d/99-amneziawg-security.conf /etc/logrotate.d/amneziawg* /etc/apt/apt.conf.d/20auto-upgrades || log_warn "Ошибка удаления файлов.";
    log "Удаление DKMS..."; rm -rf /var/lib/dkms/amneziawg* || log_warn "Ошибка удаления DKMS.";
    log "Восстановление sysctl..."; if grep -q "disable_ipv6" /etc/sysctl.conf; then sed -i '/disable_ipv6/d' /etc/sysctl.conf || log_warn "Ошибка sed sysctl.conf"; fi; sysctl -p --system &>/dev/null;
    log "Удаление cron и скриптов..."; rm -f /etc/cron.d/*amneziawg* /usr/local/bin/*amneziawg*.sh &>/dev/null;
    log "=== ДЕИНСТАЛЛЯЦИЯ ЗАВЕРШЕНА ==="; exit 0;
}
# Дополнительные функции безопасности и автоматизации
setup_advanced_sysctl() {
    log "Настройка sysctl..."; local f="/etc/sysctl.d/99-amneziawg-security.conf";
    { echo "# AmneziaWG Security/Perf Settings - <span class="math-inline">\(date\)";
echo "net\.ipv4\.ip\_forward \= 1";
if \[ "</span>{DISABLE_IPV6:-1}" -eq 1 ]; then echo "net.ipv6.conf.all.disable_ipv6 = 1"; echo "net.ipv6.conf.default.disable_ipv6 = 1"; echo "net.ipv6.conf.lo.disable_ipv6 = 1"; else echo "# IPv6 не отключен"; fi
      echo "net.ipv4.conf.all.rp_filter = 1"; echo "net.ipv4.conf.default.rp_filter = 1"; echo "net.ipv4.icmp_echo_ignore_broadcasts = 1"; echo "net.ipv4.icmp_ignore_bogus_error_responses = 1";
      echo "net.core.default_qdisc = fq"; echo "net.ipv4.tcp_congestion_control = bbr"; echo "net.ipv4.tcp_syncookies = 1"; echo "net.ipv4.tcp_max_syn_backlog = 4096";
      echo "net.ipv4.tcp_synack_retries = 2"; echo "net.ipv4.tcp_syn_retries = 5"; echo "net.ipv4.tcp_rfc1337 = 1";
      echo "net.ipv4.conf.all.accept_redirects = 0"; echo "net.ipv4.conf.default.accept_redirects = 0"; echo "net.ipv4.conf.all.secure_redirects = 0"; echo "net.ipv4.conf.default.secure_redirects = 0";
      if [ "${DISABLE_IPV6:-1}" -ne 1 ]; then echo "net.ipv6.conf.all.accept_redirects = 0"; echo "net.ipv6.conf.default.accept_redirects = 0"; fi
    } > "$f" || die "Ошибка записи в $f";
    log "Применение sysctl..."; if ! sysctl -p "$f" > /dev/null; then log_warn "Не удалось применить <span class="math-inline">f\."; fi
\}
setup\_improved\_firewall\(\) \{
log "Настройка UFW\.\.\."; if \! command \-v ufw &\>/dev/null; then install\_packages ufw; fi;
if ufw status \| grep \-q inactive; then
log "UFW неактивен\. Настройка\.\.\."; ufw default deny incoming; ufw default allow outgoing;
ufw limit 22/tcp comment "SSH Rate Limit"; ufw allow "</span>{AWG_PORT}/udp" comment "AmneziaWG VPN"; log "Правила UFW добавлены.";
        log_warn "--- ВКЛЮЧЕНИЕ UFW ---"; log_warn "Проверьте SSH доступ!"; sleep 5;
        read -p "Включить UFW? [y/N]: " confirm_ufw < /dev/tty; if ! [[ "<span class="math-inline">confirm\_ufw" \=\~ ^\[Yy\]</span> ]]; then log_warn "UFW не включен."; return 1; fi;
        if ! ufw enable <<< "y"; then die "Ошибка включения UFW."; fi; log "UFW включен.";
    else
        log "UFW активен. Обновление правил..."; ufw limit 22/tcp comment "SSH Rate Limit"; ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN";
        ufw reload || log_warn "Ошибка перезагрузки UFW."; log "Правила обновлены/проверены.";
    fi
    log "UFW настроен."; ufw status verbose | log_msg "INFO"; return 0;
}
secure_files() {
    log "Установка безопасных прав доступа..."; chmod 700 "$AWG_DIR" &>/dev/null; chmod 700 /etc/amnezia &>/dev/null; chmod 700 /etc/amnezia/amneziawg &>/dev/null;
    chmod 600 /etc/amnezia/amneziawg/*.conf &>/dev/null; find "$AWG_DIR" -name "*.conf" -type f -exec chmod 600 {} \; &>/dev/null;
    if [ -f "$CONFIG_FILE" ]; then chmod 600 "$CONFIG_FILE"; fi; if [ -f "$LOG_FILE" ]; then chmod 640 "$LOG_FILE"; fi; if [ -f "$MANAGE_SCRIPT_PATH" ]; then chmod 700 "<span class="math-inline">MANAGE\_SCRIPT\_PATH"; fi; log "Права доступа установлены\.";
\}
setup\_auto\_updates\(\) \{
log "Настройка автоматических обновлений безопасности\.\.\."; if \! command \-v unattended\-upgrade &\>/dev/null; then install\_packages unattended\-upgrades apt\-listchanges; fi; if \! command \-v unattended\-upgrade &\>/dev/null; then log\_warn "Пропускаем авто\-обновления\."; return 1; fi
if DEBIAN\_FRONTEND\=noninteractive dpkg\-reconfigure \-plow unattended\-upgrades; then
\# Полный код для 20auto\-upgrades
cat \> /etc/apt/apt\.conf\.d/20auto\-upgrades << EOF \|\| \{ log\_warn "Ошибка записи 20auto\-upgrades"; return 1; \}
APT\:\:Periodic\:\:Update\-Package\-Lists "1";
APT\:\:Periodic\:\:Unattended\-Upgrade "1";
APT\:\:Periodic\:\:AutocleanInterval "7";
APT\:\:Periodic\:\:Download\-Upgradeable\-Packages "1";
Unattended\-Upgrade\:\:Allowed\-Origins \{
"\\$\{distro\_id\}\:\\$\{distro\_codename\}\-security";
//      "\\$\{distro\_id\}\:\\$\{distro\_codename\}\-updates";
//      "\\$\{distro\_id\}\:\\$\{distro\_codename\}\-proposed";
//      "\\$\{distro\_id\}\:\\</span>{distro_codename}-backports";
};
Unattended-Upgrade::Package-Blacklist {
    // "vim";
};
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
//Unattended-Upgrade::Automatic-Reboot "false";
//Unattended-Upgrade::Automatic-Reboot-Time "02:00";
EOF
        log "Авто-обновления настроены.";
    else log_warn "Ошибка dpkg-reconfigure unattended-upgrades."; fi
}
setup_backups() {
    log "Настройка резервного копирования..."; local bd="$AWG_DIR/backups"; mkdir -p "$bd" || die "Ошибка mkdir $bd"; chmod 700 "$bd"; local bs="/usr/local/bin/backup_amneziawg.sh";
    # Полный код скрипта бэкапа
    cat > "$bs" << 'EOF' || die "Ошибка записи $bs";
#!/bin/bash
AWG_DIR="/root/awg"
BACKUP_DIR="<span class="math-inline">AWG\_DIR/backups"
SERVER\_CONF\_DIR\="/etc/amnezia/amneziawg"
TIMESTAMP\=</span>(date +%Y%m%d-%H%M%S)
BACKUP_FILE="<span class="math-inline">BACKUP\_DIR/awg\_backup\_</span>{TIMESTAMP}.tar.gz"
LOG_FILE="$BACKUP_DIR/backup.log"
MAX_BACKUPS=10 # Сколько бэкапов хранить

echo "[$TIMESTAMP] Starting backup..." >> "<span class="math-inline">LOG\_FILE"
TEMP\_DIR\=</span>(mktemp -d)
if [ $? -ne 0 ]; then echo "[$TIMESTAMP] ERROR: Failed to create temp dir." >> "$LOG_FILE"; exit 1; fi
mkdir -p "$TEMP_DIR/server_conf" "$TEMP_DIR/client_conf"
# Копируем все из директории конфигов сервера
cp -a "$SERVER_CONF_DIR/." "$TEMP_DIR/server_conf/" 2>> "$LOG_FILE"
# Копируем нужные файлы из рабочей директории
cp -a "$AWG_DIR"/*.conf "$AWG_DIR"/*.png "$AWG_DIR"/setup.conf "$TEMP_DIR/client_conf/" 2>> "$LOG_FILE" || true # Игнорируем ошибку, если setup.conf еще нет
# Создаем архив
if ! tar -czf "$BACKUP_FILE
