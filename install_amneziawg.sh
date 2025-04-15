#!/bin/bash

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG на Ubuntu 24.04 LTS Minimal
# Автор: Claude (адаптировано на основе обсуждения с пользователем @bivlked)
# Версия: 2.0
# Дата: 2025-04-14
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
set -o pipefail
AWG_DIR="/root/awg"; CONFIG_FILE="$AWG_DIR/setup.conf"; STATE_FILE="$AWG_DIR/setup_state"; CLIENT_TEMPLATE_FILE="$AWG_DIR/_defclient.config"; LOG_FILE="$AWG_DIR/install_amneziawg.log";
PYTHON_VENV=""; AWGCFG_SCRIPT=""; MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/manage_amneziawg.sh"; MANAGE_SCRIPT_PATH="$AWG_DIR/manage_amneziawg.sh"; SERVER_CONF_FILE="/etc/amnezia/amneziawg/awg0.conf";
UNINSTALL=0; HELP=0; DIAGNOSTIC=0; VERBOSE=0; CLI_PORT=""; CLI_SUBNET=""; CLI_DISABLE_IPV6="default"; CLI_ROUTING_MODE="default"; CLI_CUSTOM_ROUTES="";

# --- Обработка аргументов ---
while [[ $# -gt 0 ]]; do case $1 in --uninstall) UNINSTALL=1;; --help|-h) HELP=1;; --diagnostic) DIAGNOSTIC=1;; --verbose|-v) VERBOSE=1;; --port=*) CLI_PORT="${1#*=}";; --subnet=*) CLI_SUBNET="${1#*=}";; --allow-ipv6) CLI_DISABLE_IPV6=0;; --disallow-ipv6) CLI_DISABLE_IPV6=1;; --route-all) CLI_ROUTING_MODE=1;; --route-amnezia) CLI_ROUTING_MODE=2;; --route-custom=*) CLI_ROUTING_MODE=3; CLI_CUSTOM_ROUTES="${1#*=}";; *) echo "Неизвестный аргумент: $1"; HELP=1;; esac; shift; done

# --- Функции ---
log_msg() { local type="$1"; local msg="$2"; local ts; ts=$(date +'%F %T'); local safe_msg; safe_msg=$(echo "$msg" | sed 's/%/%%/g'); local entry="[$ts] $type: $safe_msg"; if ! mkdir -p "$(dirname "$LOG_FILE")" || ! touch "$LOG_FILE"; then echo "[$ts] ERROR: Ошибка лог-файла $LOG_FILE" >&2; else printf "%s\n" "$entry" >> "$LOG_FILE"; fi; if [[ "$type" == "ERROR" || "$type" == "WARN" || "$type" == "DEBUG" || "$VERBOSE" -eq 1 ]]; then printf "%s\n" "$entry" >&2; else printf "%s\n" "$entry"; fi; }
log() { log_msg "INFO" "$1"; }; log_warn() { log_msg "WARN" "$1"; }; log_error() { log_msg "ERROR" "$1"; }; log_debug() { log_msg "DEBUG" "$1"; }; die() { log_error "КРИТИЧЕСКАЯ ОШИБКА: $1"; log_error "Установка прервана. Лог: $LOG_FILE"; exit 1; }
is_interactive() { [[ -t 0 && -t 1 ]]; }
show_help() { cat << EOF ... (Справка без изменений) ... EOF; exit 0; } # Сокращено
update_state() { local next_step=$1; mkdir -p "$(dirname "$STATE_FILE")"; echo "$next_step" > "$STATE_FILE" || die "Ошибка записи состояния"; log "Состояние: шаг $next_step"; }
request_reboot() { local next_step=$1; update_state "$next_step"; echo "" >> "$LOG_FILE"; log_warn "... ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА ..."; log_warn "... Запустите снова: wget -O - ... | sudo bash ..."; if is_interactive; then read -p "Перезагрузить? [y/N]: " confirm < /dev/tty; if [[ "$confirm" =~ ^[Yy]$ ]]; then log "Перезагрузка..."; sleep 5; if ! reboot; then die "Ошибка reboot."; fi; exit 1; else log "Перезагрузка отменена."; exit 1; fi; else log_warn "Неинтерактивный режим. Перезагрузитесь вручную."; exit 1; fi; }
check_os_version() { log "Проверка ОС..."; ... (Код без изменений) ...; }
check_free_space() { log "Проверка места..."; ... (Код без изменений) ...; }
check_port_availability() { local port=$1; log "Проверка порта $port..."; ... (Код без изменений) ...; }
install_packages() { local packages=("$@"); local to_install=(); log "Проверка пакетов: ${packages[*]}..."; ... (Код без изменений) ...; if [ ${#to_install[@]} -gt 0 ]; then log "Установка: ${to_install[*]}..."; DEBIAN_FRONTEND=noninteractive apt install -y "${to_install[@]}" || die "Ошибка установки пакетов."; fi; }
cleanup_apt() { log "Очистка apt..."; apt clean; rm -rf /var/lib/apt/lists/*; }
configure_ipv6() { ... (Код без изменений, определяет DISABLE_IPV6) ... }
configure_routing_mode() { ... (Код без изменений, определяет ALLOWED_IPS_MODE и ALLOWED_IPS) ... }

# --- Шаг 0: Инициализация ---
initialize_setup() {
    mkdir -p "$AWG_DIR" || die "Ошибка создания $AWG_DIR"; chown root:root "$AWG_DIR"; exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)
    log "--- НАЧАЛО УСТАНОВКИ ---"; log "### ШАГ 0: Инициализация ###"
    if [ "$(id -u)" -ne 0 ]; then die "Запустите от root."; fi; cd "$AWG_DIR" || die "Ошибка cd $AWG_DIR"; log "Рабочая директория: $AWG_DIR"; log "Лог: $LOG_FILE"
    PYTHON_VENV="$AWG_DIR/venv/bin/python"; AWGCFG_SCRIPT="$AWG_DIR/awgcfg.py"
    check_os_version; check_free_space;
    local default_port=39743; local default_subnet="10.9.9.1/24"; local config_exists=0;
    if [[ -f "$CONFIG_FILE" ]]; then log "Найден $CONFIG_FILE..."; config_exists=1; source "$CONFIG_FILE" || log_warn "Ошибка загрузки $CONFIG_FILE."; AWG_PORT=${AWG_PORT:-$default_port}; AWG_TUNNEL_SUBNET=${AWG_TUNNEL_SUBNET:-$default_subnet}; else log "$CONFIG_FILE не найден."; AWG_PORT=$default_port; AWG_TUNNEL_SUBNET=$default_subnet; fi
    AWG_PORT=${CLI_PORT:-$AWG_PORT}; AWG_TUNNEL_SUBNET=${CLI_SUBNET:-$AWG_TUNNEL_SUBNET};
    if is_interactive && [[ "$config_exists" -eq 0 || "$CLI_PORT" != "" || "$CLI_SUBNET" != "" || "$CLI_DISABLE_IPV6" != "default" || "$CLI_ROUTING_MODE" != "default" ]]; then
      log "Запрос/Подтверждение настроек."; # Запросы port, subnet, ipv6, routing
      read -p "Порт UDP [${AWG_PORT}]: " input_port < /dev/tty; if [[ -n "$input_port" ]]; then AWG_PORT=$input_port; fi; if ! [[ "$AWG_PORT" =~ ^[0-9]+$ ]] || [ "$AWG_PORT" -lt 1024 ] || [ "$AWG_PORT" -gt 65535 ]; then die "Некорректный порт."; fi
      read -p "Подсеть [${AWG_TUNNEL_SUBNET}]: " input_subnet < /dev/tty; if [[ -n "$input_subnet" ]]; then AWG_TUNNEL_SUBNET=$input_subnet; fi; if ! [[ "$AWG_TUNNEL_SUBNET" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then printf "ERROR: Некорр. подсеть: '$AWG_TUNNEL_SUBNET'.\n">&2; exit 1; fi
    fi
    check_port_availability "$AWG_PORT" || die "Порт $AWG_PORT/udp занят."; configure_ipv6; configure_routing_mode;
    log "Сохранение/Обновление настроек в $CONFIG_FILE..."; printf "%s\n" "# Config AmneziaWG" > "$CONFIG_FILE" || die "Ошибка записи"; printf "%s\n" "# Used by manage script" >> "$CONFIG_FILE";
    printf "export AWG_PORT=%s\n" "${AWG_PORT}" >> "$CONFIG_FILE"; printf "export AWG_TUNNEL_SUBNET='%s'\n" "${AWG_TUNNEL_SUBNET}" >> "$CONFIG_FILE";
    printf "export DISABLE_IPV6=%s\n" "${DISABLE_IPV6}" >> "$CONFIG_FILE"; printf "export ALLOWED_IPS_MODE=%s\n" "${ALLOWED_IPS_MODE}" >> "$CONFIG_FILE"; printf "export ALLOWED_IPS='%s'\n" "${ALLOWED_IPS}" >> "$CONFIG_FILE"; log "Настройки сохранены."
    export AWG_PORT AWG_TUNNEL_SUBNET DISABLE_IPV6 ALLOWED_IPS_MODE ALLOWED_IPS; log "Порт: ${AWG_PORT}/udp"; log "Подсеть: ${AWG_TUNNEL_SUBNET}"; log "IPv6 Disabled: ${DISABLE_IPV6}"; log "Routing Mode: ${ALLOWED_IPS_MODE}";
    if [[ -f "$STATE_FILE" ]]; then current_step=$(cat "$STATE_FILE"); if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then log_warn "$STATE_FILE поврежден."; current_step=1; update_state 1; else log "Продолжение с шага $current_step."; fi; else current_step=1; log "Начало с шага 1."; update_state 1; fi
    log "Шаг 0 завершен."
}

# --- Шаги установки (1-7) ---
# ШАГ 1: Обновление и настройка ядра
step1_update_system_and_networking() {
    update_state 1; log "### ШАГ 1: Обновление и настройка ядра ###"; log "Обновление apt..."; apt update -y || die "apt update.";
    log "Разблокировка dpkg..."; if fuser /var/lib/dpkg/lock* &>/dev/null; then log_warn "dpkg заблокирован..."; DEBIAN_FRONTEND=noninteractive dpkg --configure -a || log_warn "dpkg --configure -a."; fi
    log "Обновление системы..."; DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "apt full-upgrade."; log "Система обновлена."
    install_packages curl wget gpg sudo net-tools; setup_advanced_sysctl; # Настройка sysctl (включая IPv6 и Forwarding)
    log "Шаг 1 завершен."; request_reboot 2;
}
# ШАГ 2: Установка AmneziaWG
step2_install_amnezia() {
    update_state 2; log "### ШАГ 2: Установка AmneziaWG ###"; local src_file="/etc/apt/sources.list.d/ubuntu.sources";
    log "Проверка/включение deb-src..."; if [ ! -f "$src_file" ]; then die "$src_file не найден."; fi; # Логика включения deb-src ...
    if grep -q "^Types: deb$" "$src_file"; then log "Включение deb-src..."; local bak="${src_file}.bak-$(date +%F_%T)"; cp "$src_file" "$bak" || log_warn "Ошибка бэкапа"; sed -i.bak '/^Types: deb$/s/Types: deb/Types: deb deb-src/' "$src_file" || die "Ошибка sed."; if grep -q "^Types: deb$" "$src_file"; then log_warn "Не удалось включить deb-src."; else log "deb-src добавлены."; fi; apt update -y || die "Ошибка apt update.";
    elif ! grep -q "Types: deb deb-src" "$src_file"; then log_warn "$src_file не стандартный."; apt update -y || die "Ошибка apt update."; else log "deb-src включены."; apt update -y; fi
    log "Добавление PPA Amnezia..."; local ppa_list="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).list"; local ppa_src="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).sources"; if [ ! -f "$ppa_list" ] && [ ! -f "$ppa_src" ]; then DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:amnezia/ppa || die "Ошибка PPA."; log "PPA добавлен."; apt update -y || die "Ошибка apt update."; else log "PPA уже добавлен."; apt update -y || die "Ошибка apt update."; fi
    log "Установка пакетов AmneziaWG..."; local pkgs=("amneziawg-dkms" "amneziawg-tools" "wireguard-tools" "dkms" "linux-headers-$(uname -r)" "build-essential" "dpkg-dev"); if ! dpkg -s "linux-headers-$(uname -r)" &>/dev/null; then pkgs+=( "linux-headers-generic" ); fi; install_packages "${pkgs[@]}";
    log "Проверка DKMS..."; local dkms_stat; dkms_stat=$(dkms status 2>&1); if ! echo "$dkms_stat" | grep -q 'amneziawg.*installed'; then log_warn "DKMS статус не OK."; log_msg "WARN" "$dkms_stat"; else log "DKMS статус OK."; fi
    log "Шаг 2 завершен."; request_reboot 3;
}
# ШАГ 3: Проверка модуля
step3_check_module() {
    update_state 3; log "### ШАГ 3: Проверка модуля ядра ###"; sleep 2; if ! lsmod | grep -q -w amneziawg; then log "Модуль не загружен. Загрузка..."; modprobe amneziawg || die "Ошибка modprobe."; log "Модуль загружен."; local mf="/etc/modules-load.d/amneziawg.conf"; mkdir -p "$(dirname "$mf")"; if ! grep -qxF 'amneziawg' "$mf" 2>/dev/null; then echo "amneziawg" > "$mf" || log_warn "Ошибка записи $mf"; log "Добавлено в $mf."; fi; else log "Модуль загружен."; fi
    log "Информация о модуле:"; modinfo amneziawg | grep -E "filename|version|vermagic|srcversion" | log_msg "INFO"; local cv; cv=$(modinfo amneziawg | grep vermagic | awk '{print $2}') || cv="?"; local kr; kr=$(uname -r); if [[ "$cv" != "$kr" ]]; then log_warn "VerMagic НЕ совпадает: $cv != $kr!"; else log "VerMagic совпадает."; fi
    log "Шаг 3 завершен."; update_state 4;
}
# ШАГ 4: Настройка UFW
step4_setup_firewall() {
    update_state 4; log "### ШАГ 4: Настройка фаервола UFW ###"; install_packages ufw; setup_improved_firewall; log "Шаг 4 завершен."; update_state 5;
}
# ШАГ 5: Python и скрипты
step5_setup_python() {
    update_state 5; log "### ШАГ 5: Настройка Python и скриптов ###"; install_packages python3-venv python3-pip; cd "$AWG_DIR" || die "Ошибка cd $AWG_DIR"; if [ ! -d "venv" ]; then log "Создание venv..."; python3 -m venv venv || die "Ошибка venv."; log "Venv создано."; else log "Venv существует."; fi
    log "Установка qrcode[pil]..."; if [ ! -x "$PYTHON_VENV" ]; then die "Нет $PYTHON_VENV"; fi; "$PYTHON_VENV" -m pip install -U pip || die "Ошибка pip."; "$PYTHON_VENV" -m pip install qrcode[pil] || die "Ошибка qrcode[pil]."; log "Зависимости установлены."
    if [ ! -f "$AWGCFG_SCRIPT" ]; then log "Скачивание $AWGCFG_SCRIPT..."; curl -fLso "$AWGCFG_SCRIPT" https://gist.githubusercontent.com/remittor/8c3d9ff293b2ba4b13c367cc1a69f9eb/raw/awgcfg.py || die "Ошибка curl."; chmod +x "$AWGCFG_SCRIPT" || die "Ошибка chmod."; log "$AWGCFG_SCRIPT скачан."; elif [ ! -x "$AWGCFG_SCRIPT" ]; then chmod +x "$AWGCFG_SCRIPT" || die "Ошибка chmod."; log "$AWGCFG_SCRIPT исполняемый."; else log "$AWGCFG_SCRIPT существует."; fi
    log "Скачивание $MANAGE_SCRIPT_PATH..."; if curl -fLso "$MANAGE_SCRIPT_PATH" "$MANAGE_SCRIPT_URL"; then chmod +x "$MANAGE_SCRIPT_PATH" || die "Ошибка chmod."; log "$MANAGE_SCRIPT_PATH скачан."; else log_error "Ошибка скачивания $MANAGE_SCRIPT_PATH"; fi
    log "Шаг 5 завершен."; update_state 6;
}
# ШАГ 6: Генерация конфигураций
step6_generate_configs() {
    update_state 6; log "### ШАГ 6: Генерация конфигураций ###"; cd "$AWG_DIR" || die "Ошибка cd $AWG_DIR"; local s_dir="/etc/amnezia/amneziawg"; local s_file="$s_dir/awg0.conf"; mkdir -p "$s_dir" || die "Ошибка mkdir $s_dir";
    log "Генерация конфига сервера..."; "$PYTHON_VENV" "$AWGCFG_SCRIPT" --make "$s_file" -i "${AWG_TUNNEL_SUBNET}" -p "${AWG_PORT}" || die "Ошибка генерации конфига сервера."; log "Конфиг сервера сгенерирован."
    local s_bak="${s_file}.bak-$(date +%F_%T)"; cp "$s_file" "$s_bak" || log_warn "Ошибка бэкапа $s_bak"; log "Создан бэкап $s_bak";
    log "Кастомизация шаблона $CLIENT_TEMPLATE_FILE..."; if [ ! -f "$CLIENT_TEMPLATE_FILE" ]; then log "Создание шаблона..."; "$PYTHON_VENV" "$AWGCFG_SCRIPT" --create || die "Ошибка создания шаблона."; log "Шаблон создан."; else log "Шаблон существует."; local t_bak="${CLIENT_TEMPLATE_FILE}.bak-$(date +%F_%T)"; cp "$CLIENT_TEMPLATE_FILE" "$t_bak" || log_warn "Ошибка бэкапа шаблона."; fi
    log "Применение настроек к шаблону:"; local sed_fail=0; sed -i 's/^DNS = .*/DNS = 1.1.1.1/' "$CLIENT_TEMPLATE_FILE" && log " - DNS: 1.1.1.1" || { log_warn "Ошибка sed DNS."; sed_fail=1; }; sed -i 's/^PersistentKeepalive = .*/PersistentKeepalive = 33/' "$CLIENT_TEMPLATE_FILE" && log " - Keepalive: 33" || { log_warn "Ошибка sed Keepalive."; sed_fail=1; }; sed -i "s#^AllowedIPs = .*#AllowedIPs = ${ALLOWED_IPS}#" "$CLIENT_TEMPLATE_FILE" && log " - AllowedIPs: Mode $ALLOWED_IPS_MODE" || { log_warn "Ошибка sed AllowedIPs."; sed_fail=1; };
    if [ "$sed_fail" -eq 1 ]; then log_warn "Не все настройки шаблона применены."; fi; log "Шаблон кастомизирован."
    log "Добавление клиентов по умолчанию..."; if ! grep -q "^#_Name = my_phone$" "$s_file"; then "$PYTHON_VENV" "$AWGCFG_SCRIPT" -a "my_phone" || log_warn "Ошибка add my_phone."; else log "Клиент my_phone существует."; fi; if ! grep -q "^#_Name = my_laptop$" "$s_file"; then "$PYTHON_VENV" "$AWGCFG_SCRIPT" -a "my_laptop" || log_warn "Ошибка add my_laptop."; else log "Клиент my_laptop существует."; fi;
    log "Генерация клиентских файлов..."; "$PYTHON_VENV" "$AWGCFG_SCRIPT" -c -q || die "Ошибка генерации клиентских файлов.";
    log "Клиентские файлы созданы/обновлены в $AWG_DIR:"; ls -l "$AWG_DIR"/*.conf "$AWG_DIR"/*.png | log_msg "INFO"; secure_files; # Установка прав
    log "Шаг 6 завершен."; update_state 7;
}
# ШАГ 7: Запуск сервиса и доп. настройки
step7_start_service_and_extras() {
    update_state 7; log "### ШАГ 7: Запуск сервиса и доп. настройки ###"; log "Включение и запуск awg-quick@awg0..."; systemctl enable --now awg-quick@awg0 || die "Ошибка enable --now."; log "Сервис включен и запущен."
    log "Проверка статуса сервиса..."; sleep 3; check_service_status || die "Проверка статуса сервиса не пройдена."
    log "Настройка дополнительных компонентов..."; setup_fail2ban; setup_auto_updates; setup_backups; setup_log_rotation;
    log "Шаг 7 завершен."; update_state 99;
}
# ШАГ 99: Завершение
step99_finish() {
    log "### ЗАВЕРШЕНИЕ УСТАНОВКИ ###"; log "=============================================================================="; log "Установка и настройка AmneziaWG УСПЕШНО ЗАВЕРШЕНА!"; log " ";
    log "КЛИЕНТСКИЕ ФАЙЛЫ:"; log "  Конфиги (.conf) и QR-коды (.png) в: $AWG_DIR"; log "  Скопируйте их безопасным способом."; log "  Пример (на вашем ПК):"; log "    scp root@<IP_СЕРВЕРА>:$AWG_DIR/*.conf ./"; log " ";
    log "ПОЛЕЗНЫЕ КОМАНДЫ:"; log "  sudo bash $MANAGE_SCRIPT_PATH help # Управление клиентами"; log "  systemctl status awg-quick@awg0  # Статус VPN"; log "  awg show                         # Статус WG"; log "  ufw status verbose               # Статус Firewall"; log " ";
    log "Очистка apt..."; cleanup_apt; log " ";
    log "[DEBUG] Проверка $CONFIG_FILE перед выходом..."; if [ -f "$CONFIG_FILE" ]; then log "[DEBUG] $CONFIG_FILE СУЩЕСТВУЕТ."; else log_error "[DEBUG] $CONFIG_FILE ОТСУТСТВУЕТ!"; fi
    # log "Удаление файла состояния..."; rm -f "$STATE_FILE" || log_warn "Не удалось удалить $STATE_FILE";
    log "Файл состояния $STATE_FILE НЕ удален."; log "Установка завершена. Лог: $LOG_FILE"; log "==============================================================================";
}
# Функция деинсталляции
step_uninstall() { log "### ДЕИНСТАЛЛЯЦИЯ AMNEZIAWG ###"; if is_interactive; then echo ""; echo "ВНИМАНИЕ! Полное удаление..."; read -p "Уверены? (yes): " confirm < /dev/tty; if [[ "$confirm" != "yes" ]]; then log "Отмена."; exit 1; fi; read -p "Создать бэкап? [Y/n]: " backup < /dev/tty; if [[ -z "$backup" || "$backup" =~ ^[Yy]$ ]]; then local bf="$HOME/awg_uninstall_backup_$(date +%F_%T).tar.gz"; log "Бэкап: $bf"; tar -czf "$bf" -C / etc/amnezia "$AWG_DIR" 2>/dev/null || log_warn "Ошибка бэкапа"; chmod 600 "$bf"; log "Бэкап создан: $bf"; fi; fi;
    log "Остановка сервиса..."; systemctl stop awg-quick@awg0 &>/dev/null; systemctl disable awg-quick@awg0 &>/dev/null;
    log "Удаление правил UFW..."; if command -v ufw &>/dev/null; then source "$CONFIG_FILE" 2>/dev/null; ufw delete allow ${AWG_PORT:-39743}/udp &>/dev/null; fi;
    log "Удаление пакетов..."; DEBIAN_FRONTEND=noninteractive apt-get purge -y amneziawg-dkms amneziawg-tools &>/dev/null || log_warn "Ошибка purge."; DEBIAN_FRONTEND=noninteractive apt-get autoremove -y &>/dev/null || log_warn "Ошибка autoremove.";
    log "Удаление файлов..."; rm -rf /etc/amnezia "$AWG_DIR" /etc/modules-load.d/amneziawg.conf /etc/sysctl.d/10-amneziawg-forward.conf /etc/sysctl.d/99-amneziawg-security.conf /etc/logrotate.d/amneziawg /etc/logrotate.d/amneziawg-custom || log_warn "Ошибка rm.";
    log "Удаление DKMS..."; rm -rf /var/lib/dkms/amneziawg* || log_warn "Ошибка rm DKMS.";
    log "Восстановление sysctl..."; if grep -q "disable_ipv6" /etc/sysctl.conf; then sed -i '/disable_ipv6/d' /etc/sysctl.conf || log_warn "Ошибка sed sysctl.conf"; fi; sysctl -p --system &>/dev/null;
    log "Удаление cron и скриптов..."; rm -f /etc/cron.d/*amneziawg* /usr/local/bin/*amneziawg*.sh &>/dev/null;
    log "=== ДЕИНСТАЛЛЯЦИЯ ЗАВЕРШЕНА ==="; exit 0;
}
# Дополнительные функции безопасности и автоматизации
setup_advanced_sysctl() { log "Настройка sysctl..."; local f="/etc/sysctl.d/99-amneziawg-security.conf"; { echo "# AmneziaWG Security/Perf"; echo "net.ipv4.ip_forward = 1"; if [ "${DISABLE_IPV6:-1}" -eq 1 ]; then echo "net.ipv6.conf.all.disable_ipv6 = 1"; echo "net.ipv6.conf.default.disable_ipv6 = 1"; echo "net.ipv6.conf.lo.disable_ipv6 = 1"; fi; echo "net.ipv4.conf.all.rp_filter = 1"; echo "net.ipv4.conf.default.rp_filter = 1"; echo "net.ipv4.icmp_echo_ignore_broadcasts = 1"; echo "net.ipv4.icmp_ignore_bogus_error_responses = 1"; echo "net.core.default_qdisc = fq"; echo "net.ipv4.tcp_congestion_control = bbr"; echo "net.ipv4.tcp_syncookies = 1"; echo "net.ipv4.tcp_max_syn_backlog = 2048"; echo "net.ipv4.tcp_synack_retries = 2"; echo "net.ipv4.tcp_syn_retries = 5"; } > "$f" || log_warn "Ошибка записи $f"; log "Применение sysctl..."; if ! sysctl -p "$f" > /dev/null; then log_warn "Не удалось применить $f."; fi; }
setup_improved_firewall() { log "Настройка UFW..."; if ! command -v ufw &>/dev/null; then install_packages ufw; fi; if ufw status | grep -q inactive; then log "UFW неактивен. Настройка..."; ufw default deny incoming; ufw default allow outgoing; ufw limit 22/tcp comment "SSH Rate Limit"; ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN"; log_warn "--- ВКЛЮЧЕНИЕ UFW ---"; log_warn "Проверьте доступ SSH!"; sleep 3; if is_interactive; then read -p "Включить UFW? [y/N]: " c < /dev/tty; if ! [[ "$c" =~ ^[Yy]$ ]]; then log_warn "UFW не включен."; return 1; fi; fi; ufw enable <<< "y" || die "Ошибка включения UFW."; log "UFW включен."; else log "UFW активен. Обновление правил..."; ufw allow 22/tcp; ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN"; ufw reload || log_warn "Ошибка перезагрузки UFW."; fi; log "UFW настроен."; ufw status verbose | log_msg "INFO"; }
secure_files() { log "Установка прав..."; chmod 700 /etc/amnezia &>/dev/null; chmod 700 /etc/amnezia/amneziawg &>/dev/null; chmod 700 "$AWG_DIR" &>/dev/null; chmod 600 /etc/amnezia/amneziawg/*.conf &>/dev/null; chmod 600 "$AWG_DIR"/*.conf &>/dev/null; chmod 600 "$CONFIG_FILE" &>/dev/null; chmod 640 "$LOG_FILE" &>/dev/null; log "Права установлены."; }
setup_fail2ban() { log "Настройка Fail2Ban..."; install_packages fail2ban; cat > /etc/fail2ban/jail.local << EOF || log_warn "Ошибка jail.local"; [DEFAULT]\nbantime=1h\nfindtime=10m\nmaxretry=5\nbanaction=ufw\n[sshd]\nenabled=true\nport=ssh\nmaxretry=3\nbantime=12h\nEOF; systemctl restart fail2ban || log_warn "Ошибка restart fail2ban"; log "Fail2Ban настроен."; }
setup_auto_updates() { log "Настройка авто-обновлений..."; install_packages unattended-upgrades apt-listchanges; DEBIAN_FRONTEND=noninteractive dpkg-reconfigure -plow unattended-upgrades; cat > /etc/apt/apt.conf.d/20auto-upgrades << EOF || log_warn "Ошибка 20auto-upgrades"; APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\nAPT::Periodic::AutocleanInterval "7";\nAPT::Periodic::Download-Upgradeable-Packages "1";\nEOF; log "Авто-обновления настроены."; }
setup_backups() { log "Настройка бэкапов..."; local bd="$AWG_DIR/backups"; mkdir -p "$bd" || die "Ошибка mkdir $bd"; chmod 700 "$bd"; local bs="/usr/local/bin/backup_amneziawg.sh"; cat > "$bs" << 'EOF' || die "Ошибка записи $bs"; #!/bin/bash... (код скрипта бэкапа)... EOF; chmod +x "$bs" || die "Ошибка chmod $bs"; echo "0 3 * * * root $bs" > /etc/cron.d/backup_amneziawg || log_warn "Ошибка cron"; log "Ежедневный бэкап в $bd настроен."; log "Создание первого бэкапа..."; if "$bs"; then log "OK."; else log_warn "Ошибка."; fi; } # Код скрипта бэкапа нужно вставить
setup_log_rotation() { log "Настройка ротации логов..."; cat > /etc/logrotate.d/amneziawg-installer << EOF || log_warn "Ошибка logrotate"; $LOG_FILE\n$AWG_DIR/manage_amneziawg.log\n$AWG_DIR/backups/backup.log {\n weekly\n rotate 12\n compress\n delaycompress\n missingok\n notifempty\n create 640 root adm\n}\nEOF; log "Ротация логов настроена."; }
create_diagnostic_report() { log "Создание диагностики..."; local rf="$AWG_DIR/diag_$(date +%F_%T).txt"; { echo "DIAG REPORT"; date; ...; } > "$rf" || log_error "Ошибка отчета."; chmod 600 "$rf"; log "Отчет: $rf"; } # Код генерации отчета нужно вставить

# --- Основной цикл выполнения ---
# Проверка опций
if [ "$HELP" -eq 1 ]; then show_help; fi
if [ "$UNINSTALL" -eq 1 ]; then step_uninstall; fi
if [ "$DIAGNOSTIC" -eq 1 ]; then create_diagnostic_report; exit 0; fi
if [ "$VERBOSE" -eq 1 ]; then set -x; fi # Включаем отладку, если нужно

initialize_setup # Всегда инициализируем
while (( current_step < 99 )); do log "Выполнение шага $current_step..."; case $current_step in
    1) step1_update_system_and_networking ;; 2) step2_install_amnezia ;; 3) step3_check_module; current_step=4 ;; 4) step4_setup_firewall; current_step=5 ;;
    5) step5_setup_python; current_step=6 ;; 6) step6_generate_configs; current_step=7 ;; 7) step7_start_service_and_extras; current_step=99 ;; *) die "Ошибка: Неизвестный шаг $current_step.";; esac;
done
if (( current_step == 99 )); then step99_finish; fi
exit 0
