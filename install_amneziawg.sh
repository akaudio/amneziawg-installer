#!/bin/bash
# ==============================================================================
# Скрипт для установки и настройки AmneziaWG на Ubuntu 24.04 LTS Minimal
# Автор: Claude (адаптировано на основе обсуждения с пользователем @bivlked)
# Версия: 1.2
# Дата: 2025-04-14
# Репозиторий: https://github.com/bivlked/amneziawg-installer (Пример)
# ==============================================================================

# --- Безопасный режим и Константы ---
# set -e # Выход при любой ошибке (можно раскомментировать для строгой проверки)
set -o pipefail # Выход, если команда в пайпе завершается с ошибкой

# Директория для файлов скрипта, логов, конфигов пользователя и состояния
AWG_DIR="$HOME/awg"
# Файл для хранения пользовательских настроек (порт, подсеть)
CONFIG_FILE="$AWG_DIR/setup.conf"
# Файл для хранения текущего шага выполнения
STATE_FILE="$AWG_DIR/setup_state"
# Файл шаблона клиента AmneziaWG
CLIENT_TEMPLATE_FILE="$AWG_DIR/_defclient.config"
# Лог файл установки
LOG_FILE="$AWG_DIR/install_amneziawg.log"
# Путь к python внутри venv (определится позже)
PYTHON_VENV=""
# Путь к утилите awgcfg.py (определится позже)
AWGCFG_SCRIPT=""


# --- Функции Логирования ---
# Функция для вывода сообщений в лог и на экран
log_msg() {
    local type="$1" # INFO, WARN, ERROR
    local message="$2"
    local timestamp
    timestamp=$(date +'%Y-%m-%d %H:%M:%S')
    local log_entry="[$timestamp] $type: $message"

    # Запись в лог-файл
    echo "$log_entry" >> "$LOG_FILE"

    # Вывод на экран (stderr для ошибок/предупреждений)
    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        echo "$log_entry" >&2
    else
        echo "$log_entry"
    fi
}

log() { log_msg "INFO" "$1"; }
log_warn() { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }

# Функция для выхода при ошибке
die() {
    log_error "$1"
    exit 1
}

# --- Функции Управления Состоянием ---
# Функция для записи следующего шага
update_state() {
    local next_step=$1
    echo "$next_step" > "$STATE_FILE" || die "Не удалось записать состояние в $STATE_FILE"
    log "Состояние обновлено: следующий шаг - $next_step"
}

# Функция для запроса перезагрузки
request_reboot() {
    local next_step_after_reboot=$1
    update_state "$next_step_after_reboot" # Записываем шаг ПОСЛЕ перезагрузки
    echo "" >> "$LOG_FILE"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log_warn "!!! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА СИСТЕМЫ !!!"
    log_warn "!!! После перезагрузки, пожалуйста, запустите этот скрипт снова:"
    log_warn "!!! sudo bash $0"
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "" >> "$LOG_FILE"
    # Спросить пользователя, если скрипт запущен интерактивно
    if [[ -t 0 ]]; then # Проверка, подключен ли stdin к терминалу
      read -p "Перезагрузить сейчас? [y/N]: " confirm_reboot
      if [[ "$confirm_reboot" =~ ^[Yy]$ ]]; then
          log "Инициирована перезагрузка по команде пользователя..."
          # Даем системе немного времени перед перезагрузкой
          sleep 5
          if ! reboot; then die "Команда reboot не найдена или не удалась."; fi
          # Выход на случай, если команда reboot не сработала немедленно
          exit 1
      else
          log "Перезагрузка отменена пользователем. Пожалуйста, перезагрузитесь вручную и запустите скрипт снова."
          exit 1
      fi
    else
      log_warn "Скрипт запущен неинтерактивно. Перезагрузка не будет выполнена автоматически."
      log_warn "Пожалуйста, перезагрузите систему вручную и запустите скрипт снова."
      exit 1 # Выход, чтобы избежать продолжения без перезагрузки
    fi
}

# --- Шаг 0: Инициализация и Настройка Переменных ---
initialize_setup() {
    # Перенаправляем весь вывод функций в лог (и на экран через log_msg)
    exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

    log "--- НАЧАЛО УСТАНОВКИ / ПРОВЕРКА СОСТОЯНИЯ ---"
    log "### ШАГ 0: Инициализация и проверка прав ###"

    # Проверка прав root
    if [ "$(id -u)" -ne 0 ]; then die "Скрипт должен быть запущен с правами root (через sudo)."; fi

    # Создание рабочей директории
    mkdir -p "$AWG_DIR" || die "Не удалось создать рабочую директорию $AWG_DIR"
    cd "$AWG_DIR" || die "Не удалось перейти в рабочую директорию $AWG_DIR"
    log "Рабочая директория: $AWG_DIR"
    log "Лог файл: $LOG_FILE"

    # Определение путей к Python и скрипту
    PYTHON_VENV="$AWG_DIR/venv/bin/python"
    AWGCFG_SCRIPT="$AWG_DIR/awgcfg.py"

    # Значения по умолчанию для настроек
    local default_port=39743
    local default_subnet="10.9.9.1/24"

    # Загружаем конфиг, если он есть, иначе создаем с дефолтами/запросом
    if [[ -f "$CONFIG_FILE" ]]; then
        log "Загрузка настроек из $CONFIG_FILE..."
        source "$CONFIG_FILE" || log_warn "Не удалось полностью загрузить настройки из $CONFIG_FILE."
        AWG_PORT=${AWG_PORT:-$default_port}
        AWG_TUNNEL_SUBNET=${AWG_TUNNEL_SUBNET:-$default_subnet}
        log "Настройки загружены."
    else
        log "Файл конфигурации $CONFIG_FILE не найден. Запрос настроек у пользователя."
        # Запрос порта у пользователя
        read -p "Введите UDP порт для AmneziaWG (рекомендуется 1024-65535) [${default_port}]: " input_port
        AWG_PORT=${input_port:-$default_port}
        if ! [[ "$AWG_PORT" =~ ^[0-9]+$ ]] || [ "$AWG_PORT" -lt 1024 ] || [ "$AWG_PORT" -gt 65535 ]; then
            die "Некорректный номер порта: $AWG_PORT. Введите число от 1024 до 65535."
        fi

        # Запрос подсети у пользователя
        read -p "Введите подсеть туннеля (например, 10.x.x.1/24) [${default_subnet}]: " input_subnet
        AWG_TUNNEL_SUBNET=${input_subnet:-$default_subnet}
        if ! [[ "$AWG_TUNNEL_SUBNET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            die "Некорректный формат подсети: $AWG_TUNNEL_SUBNET. Пример: 10.9.9.1/24."
        fi

        # Сохраняем введенные/дефолтные настройки в файл
        log "Сохранение настроек в $CONFIG_FILE..."
        cat > "$CONFIG_FILE" << EOF || die "Не удалось записать файл конфигурации $CONFIG_FILE"
# Конфигурация установки AmneziaWG
# Этот файл генерируется автоматически. Не редактируйте вручную без необходимости.
export AWG_PORT=${AWG_PORT}
export AWG_TUNNEL_SUBNET="${AWG_TUNNEL_SUBNET}"
EOF
        log "Настройки сохранены."
    fi

    # Экспортируем переменные, чтобы они были доступны в функциях текущего запуска
    export AWG_PORT
    export AWG_TUNNEL_SUBNET

    log "Используемый порт AmneziaWG: ${AWG_PORT}/udp"
    log "Используемая подсеть туннеля: ${AWG_TUNNEL_SUBNET}"

    # Загружаем состояние (номер следующего шага)
    if [[ -f "$STATE_FILE" ]]; then
        current_step=$(cat "$STATE_FILE")
        # Проверка, что в файле число
        if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then
            log_warn "Файл состояния $STATE_FILE поврежден. Начинаем установку с начала."
            current_step=1
            update_state 1
        else
             log "Обнаружен файл состояния. Продолжение установки с шага $current_step."
        fi
    else
        current_step=1
        log "Файл состояния не найден. Начало установки с шага 1."
        update_state 1 # Создаем файл состояния с шагом 1
    fi
    log "Шаг 0 завершен."
}

# --- Функции для каждого шага установки ---

# ШАГ 1: Обновление системы, отключение IPv6, включение IP Forwarding
step1_update_system_and_networking() {
    update_state 1
    log "### ШАГ 1: Обновление системы и настройка ядра ###"
    log "Обновление списка пакетов..."
    apt update -y || die "Ошибка при apt update."
    log "Обновление системы (может занять время)..."
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "Ошибка при apt full-upgrade."
    log "Система обновлена."

    log "Отключение IPv6..."
    {
        grep -qxF 'net.ipv6.conf.all.disable_ipv6 = 1' /etc/sysctl.conf || echo 'net.ipv6.conf.all.disable_ipv6 = 1'
        grep -qxF 'net.ipv6.conf.default.disable_ipv6 = 1' /etc/sysctl.conf || echo 'net.ipv6.conf.default.disable_ipv6 = 1'
        grep -qxF 'net.ipv6.conf.lo.disable_ipv6 = 1' /etc/sysctl.conf || echo 'net.ipv6.conf.lo.disable_ipv6 = 1'
    } | tee -a /etc/sysctl.conf > /dev/null || log_warn "Не удалось записать все параметры IPv6 в /etc/sysctl.conf"
    log "Параметры для отключения IPv6 добавлены в /etc/sysctl.conf (если отсутствовали)."

    log "Включение IPv4 Forwarding..."
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/10-amneziawg-forward.conf || die "Не удалось создать файл /etc/sysctl.d/10-amneziawg-forward.conf"
    log "Создан файл /etc/sysctl.d/10-amneziawg-forward.conf."

    log "Применение настроек sysctl..."
    sysctl -p --system || log_warn "Не удалось применить все настройки sysctl немедленно (это нормально, применятся после перезагрузки)."

    log "Шаг 1 успешно завершен."
    request_reboot 2
}

# ШАГ 2: Установка AmneziaWG и зависимостей
step2_install_amnezia() {
    update_state 2
    log "### ШАГ 2: Установка AmneziaWG и зависимостей ###"

    local sources_file="/etc/apt/sources.list.d/ubuntu.sources"

    # Автоматическое включение deb-src
    log "Проверка и включение deb-src репозиториев в $sources_file..."
    if [ ! -f "$sources_file" ]; then die "Файл $sources_file не найден. Невозможно проверить deb-src."; fi

    if grep -q "^Types: deb$" "$sources_file"; then
        log "Обнаружены строки 'Types: deb' без 'deb-src'. Включение..."
        local backup_file="${sources_file}.bak-$(date +%F_%T)"
        cp "$sources_file" "$backup_file" || log_warn "Не удалось создать резервную копию $backup_file"
        sed -i.bak '/^Types: deb$/s/Types: deb/Types: deb deb-src/' "$sources_file" || die "Ошибка при модификации $sources_file с помощью sed."
        # Проверка после модификации
        if grep -q "^Types: deb$" "$sources_file"; then
             log_warn "Не удалось автоматически включить все deb-src. Возможно, требуется ручное редактирование $sources_file."
        else
             log "deb-src успешно добавлены в $sources_file."
             log "Обновление списка пакетов после изменения sources..."
             apt update -y || die "Ошибка при apt update после включения deb-src."
        fi
    elif ! grep -q "Types: deb deb-src" "$sources_file"; then
         log_warn "Не найдены строки 'Types: deb deb-src' или 'Types: deb' в $sources_file. Проверьте конфигурацию APT."
         # Не выходим, т.к. формат может быть другим, но предупреждаем
    else
        log "deb-src репозитории уже включены."
        apt update -y # Обновим на всякий случай
    fi

    # Добавление PPA Amnezia
    log "Добавление PPA репозитория Amnezia..."
    add-apt-repository -y ppa:amnezia/ppa || die "Не удалось добавить PPA amnezia/ppa."
    log "Обновление списка пакетов после добавления PPA..."
    apt update -y || die "Ошибка при apt update после добавления PPA."

    # Установка необходимых пакетов
    log "Установка AmneziaWG (DKMS), инструментов и зависимостей для сборки..."
    local packages_to_install=(
        amneziawg-dkms amneziawg-tools wireguard-tools
        dkms "linux-headers-$(uname -r)" build-essential dpkg-dev
    )
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${packages_to_install[@]}"; then
        log_warn "Ошибка при установке пакетов: ${packages_to_install[*]}. Попытка исправить..."
        if ! DEBIAN_FRONTEND=noninteractive apt --fix-broken install -y; then
           die "Не удалось исправить зависимости ('apt --fix-broken install'). Проверьте вывод apt и логи DKMS."
        fi
        log "Повторная попытка установки пакетов после исправления зависимостей..."
         if ! DEBIAN_FRONTEND=noninteractive apt install -y "${packages_to_install[@]}"; then
             die "Повторная установка пакетов также не удалась. Проверьте логи и системные требования."
         fi
    fi
    log "Пакеты AmneziaWG и зависимости успешно установлены."

    log "Шаг 2 успешно завершен."
    request_reboot 3
}

# ШАГ 3: Проверка загрузки модуля ядра
step3_check_module() {
    update_state 3
    log "### ШАГ 3: Проверка загрузки модуля ядра AmneziaWG ###"
    if lsmod | grep -q -w amneziawg; then # -w для точного совпадения слова
        log "Модуль amneziawg уже загружен."
    else
        log "Модуль amneziawg не найден в lsmod. Попытка загрузить вручную..."
        modprobe amneziawg || die "Ошибка: Не удалось загрузить модуль amneziawg через modprobe. Проверьте dmesg и логи DKMS."
        log "Модуль успешно загружен через modprobe."
        # Добавляем его в автозагрузку, если пришлось грузить вручную
        local modules_file="/etc/modules-load.d/amneziawg.conf"
        if ! grep -qxF 'amneziawg' "$modules_file" 2>/dev/null; then
             echo "amneziawg" > "$modules_file" || log_warn "Не удалось записать модуль в $modules_file"
             log "Добавлено в $modules_file для автозагрузки."
        fi
    fi
    log "Проверка информации о модуле..."
    modinfo amneziawg | grep -E "version|vermagic" | log_msg "INFO" # Логируем вывод
    # Проверка совместимости vermagic
    local current_vermagic
    current_vermagic=$(modinfo amneziawg | grep vermagic | awk '{print $2}')
    if [[ "$current_vermagic" != "$(uname -r)" ]]; then
        log_warn "Версия ядра в vermagic модуля ($current_vermagic) НЕ совпадает с текущим ядром ($(uname -r)). Это МОЖЕТ вызвать проблемы."
    else
        log "Версия ядра vermagic модуля совпадает с текущим ядром."
    fi
    log "Шаг 3 успешно завершен."
    update_state 4
}

# ШАГ 4: Настройка фаервола (UFW)
step4_setup_firewall() {
    update_state 4
    log "### ШАГ 4: Настройка фаервола UFW ###"
    log "Установка UFW (если не установлен)..."
    apt install -y ufw || die "Не удалось установить UFW."

    log "Настройка правил UFW..."
    ufw reset # Сброс до дефолтных правил (на случай предыдущих настроек)
    ufw default deny incoming      || log_warn "Не удалось установить default deny incoming."
    ufw default allow outgoing     || log_warn "Не удалось установить default allow outgoing."
    ufw allow OpenSSH              || log_warn "Не удалось добавить правило для OpenSSH."
    ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || log_warn "Не удалось добавить правило для порта AmneziaWG."
    log "Правила UFW настроены (запрет по умолч., разрешены SSH и ${AWG_PORT}/udp)."

    log "Включение UFW..."
    if ! ufw status | grep -q 'Status: active'; then
        # Проверка наличия правила SSH перед включением
        if ! ufw status | grep -q '22/tcp.*ALLOW'; then # Проверяем стандартный порт, если вы используете другой, эту проверку нужно изменить
            log_error "Правило для SSH (порт 22/tcp) не найдено в UFW! Включение фаервола ЗАБЛОКИРУЕТ ВАШ ДОСТУП!"
            read -p "Вы уверены, что SSH на другом порту и правило добавлено? Или хотите продолжить на свой страх и риск? [y/N]: " confirm_ssh
            if ! [[ "$confirm_ssh" =~ ^[Yy]$ ]]; then
                 die "Включение UFW отменено для предотвращения блокировки доступа."
            fi
            log_warn "Продолжение включения UFW без стандартного правила SSH!"
        fi
        ufw --force enable || die "Не удалось включить UFW."
        log "UFW включен и активирован при загрузке."
    else
        log "UFW уже активен."
        ufw reload || log_warn "Не удалось перезагрузить правила UFW."
    fi

    log "Текущий статус UFW:"
    ufw status verbose | log_msg "INFO" # Логируем вывод
    log "Шаг 4 успешно завершен."
    update_state 5
}

# ШАГ 5: Настройка Python окружения и утилиты
step5_setup_python() {
    update_state 5
    log "### ШАГ 5: Настройка Python и утилиты awgcfg.py ###"
    log "Установка необходимых Python пакетов (venv, pip)..."
    apt install -y python3-venv python3-pip || die "Не удалось установить python3-venv/pip."

    cd "$AWG_DIR" || die "Не удалось перейти в рабочую директорию $AWG_DIR"

    if [ ! -d "venv" ]; then
        log "Создание виртуального окружения Python в $AWG_DIR/venv..."
        python3 -m venv venv || die "Не удалось создать venv."
        log "Виртуальное окружение создано."
    else
        log "Виртуальное окружение venv уже существует."
    fi

    log "Обновление pip и установка qrcode[pil] в venv..."
    "$PYTHON_VENV" -m pip install -U pip || die "Не удалось обновить pip в venv."
    "$PYTHON_VENV" -m pip install qrcode[pil] || die "Не удалось установить qrcode[pil] в venv."
    log "Зависимости Python установлены."

    if [ ! -f "$AWGCFG_SCRIPT" ]; then
        log "Скачивание скрипта $AWGCFG_SCRIPT..."
        wget --no-verbose -O "$AWGCFG_SCRIPT" https://gist.githubusercontent.com/remittor/8c3d9ff293b2ba4b13c367cc1a69f9eb/raw/awgcfg.py || die "Не удалось скачать $AWGCFG_SCRIPT."
        chmod +x "$AWGCFG_SCRIPT" || die "Не удалось сделать $AWGCFG_SCRIPT исполняемым."
        log "Скрипт $AWGCFG_SCRIPT скачан и сделан исполняемым."
    else
        log "Скрипт $AWGCFG_SCRIPT уже существует."
    fi
    log "Шаг 5 успешно завершен."
    update_state 6
}

# ШАГ 6: Генерация конфигураций AmneziaWG и кастомизация шаблона
step6_generate_configs() {
    update_state 6
    log "### ШАГ 6: Генерация конфигураций AmneziaWG ###"
    cd "$AWG_DIR" || die "Не удалось перейти в рабочую директорию $AWG_DIR"

    local server_conf_dir="/etc/amnezia/amneziawg"
    local server_conf_file="$server_conf_dir/awg0.conf"

    mkdir -p "$server_conf_dir" || die "Не удалось создать директорию $server_conf_dir"
    log "Создана/проверена директория $server_conf_dir."

    # --- Кастомизация шаблона клиента ---
    log "Проверка/создание и кастомизация шаблона $CLIENT_TEMPLATE_FILE..."
    if [ ! -f "$CLIENT_TEMPLATE_FILE" ]; then
         log "Шаблон $CLIENT_TEMPLATE_FILE не найден, создаем..."
         "$PYTHON_VENV" "$AWGCFG_SCRIPT" --create || die "Не удалось создать шаблон $CLIENT_TEMPLATE_FILE. Проверьте доступность внешнего IP."
         log "Шаблон $CLIENT_TEMPLATE_FILE создан."
    else
         log "Используется существующий шаблон $CLIENT_TEMPLATE_FILE."
         # Сохраняем резервную копию шаблона перед изменением
         cp "$CLIENT_TEMPLATE_FILE" "${CLIENT_TEMPLATE_FILE}.bak-$(date +%F_%T)" || log_warn "Не удалось создать резервную копию шаблона."
    fi

    # Применяем желаемые изменения к шаблону:
    log "Применение кастомных настроек к шаблону:"
    # 1. DNS = 1.1.1.1
    sed -i 's/^DNS = .*/DNS = 1.1.1.1/' "$CLIENT_TEMPLATE_FILE" && log " - DNS установлен в 1.1.1.1" || log_warn "Не удалось установить DNS в шаблоне."
    # 2. PersistentKeepalive = 33
    sed -i 's/^PersistentKeepalive = .*/PersistentKeepalive = 33/' "$CLIENT_TEMPLATE_FILE" && log " - PersistentKeepalive установлен в 33" || log_warn "Не удалось установить PersistentKeepalive в шаблоне."
    # 3. AllowedIPs = Список Amnezia + DNS Google/Cloudflare
    local amnezia_allowed_ips="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
    # Используем другой разделитель для sed из-за слешей в IP-адресах
    sed -i "s|^AllowedIPs = .*|AllowedIPs = ${amnezia_allowed_ips}|" "$CLIENT_TEMPLATE_FILE" && log " - AllowedIPs установлен в список Amnezia + DNS" || log_warn "Не удалось установить AllowedIPs в шаблоне."
    log "Шаблон $CLIENT_TEMPLATE_FILE успешно кастомизирован."
    # --- Конец кастомизации шаблона ---

    log "Генерация основного конфигурационного файла сервера $server_conf_file..."
    "$PYTHON_VENV" "$AWGCFG_SCRIPT" --make "$server_conf_file" -i "${AWG_TUNNEL_SUBNET}" -p "${AWG_PORT}" || die "Ошибка генерации конфигурации сервера $server_conf_file."
    log "Конфигурация сервера успешно сгенерирована."

    # Резервная копия и права доступа
    local server_conf_bak="${server_conf_file}.bak-$(date +%F_%T)"
    cp "$server_conf_file" "$server_conf_bak" || log_warn "Не удалось создать резервную копию $server_conf_bak"
    log "Создана резервная копия $server_conf_bak"
    chmod 700 /etc/amnezia || log_warn "Не удалось установить права на /etc/amnezia"
    chmod 700 "$server_conf_dir" || log_warn "Не удалось установить права на $server_conf_dir"
    chmod 600 "$server_conf_file" || log_warn "Не удалось установить права на $server_conf_file"
    log "Установлены безопасные права доступа к конфигурации."

    # Добавление тестовых/начальных клиентов
    log "Добавление/проверка клиентов по умолчанию (my_phone, my_laptop)..."
    # Используем grep для проверки наличия секции пира (комментарий обязателен!)
    if ! grep -q "\[Peer\] # my_phone" "$server_conf_file"; then
      "$PYTHON_VENV" "$AWGCFG_SCRIPT" -a "my_phone" || log_warn "Не удалось добавить клиента my_phone."
    else log "Клиент my_phone уже существует в $server_conf_file."; fi

    if ! grep -q "\[Peer\] # my_laptop" "$server_conf_file"; then
      "$PYTHON_VENV" "$AWGCFG_SCRIPT" -a "my_laptop" || log_warn "Не удалось добавить клиента my_laptop."
    else log "Клиент my_laptop уже существует в $server_conf_file."; fi

    # Генерация клиентских файлов
    log "Генерация клиентских конфигурационных файлов (.conf) и QR-кодов (.png)..."
    "$PYTHON_VENV" "$AWGCFG_SCRIPT" -c -q || die "Ошибка генерации клиентских конфигурационных файлов."

    log "Клиентские файлы созданы/обновлены в директории $AWG_DIR:"
    ls -l "$AWG_DIR"/*.conf "$AWG_DIR"/*.png | log_msg "INFO" # Логируем вывод ls
    log "Шаг 6 успешно завершен."
    update_state 7
}

# ШАГ 7: Запуск и автозагрузка сервиса
step7_start_service() {
    update_state 7
    log "### ШАГ 7: Запуск и автозагрузка сервиса AmneziaWG ###"
    log "Включение автозагрузки и запуск сервиса awg-quick@awg0..."
    systemctl enable --now awg-quick@awg0 || die "Не удалось включить или запустить сервис awg-quick@awg0. Проверьте логи."
    log "Сервис awg-quick@awg0 включен и запущен."

    log "Проверка статуса сервиса systemd (ожидание 3 сек)..."
    sleep 3
    systemctl status awg-quick@awg0 --no-pager -l | log_msg "INFO" # Логируем вывод

    if systemctl is-failed --quiet awg-quick@awg0; then
        die "Сервис awg-quick@awg0 находится в состоянии failed. Проверьте 'journalctl -u awg-quick@awg0'."
    elif ! systemctl is-active --quiet awg-quick@awg0; then
        # Для wg-quick@.service статус 'inactive (dead)' после 'exited' тоже может быть нормой, если интерфейс остался поднят.
        # Главное - не 'failed'. Проверим сам интерфейс.
        log_warn "Статус systemd сервиса awg-quick@awg0 не 'active'. Проверяем интерфейс awg0..."
    fi

    log "Проверка статуса интерфейса AmneziaWG (awg show)..."
    sleep 2
    local awg_show_output
    awg_show_output=$(awg show 2>&1) # Захватываем и stderr
    if ! echo "$awg_show_output" | grep -q "interface: awg0"; then
       log_error "Команда 'awg show' не показывает активный интерфейс awg0. Вывод команды:"
       log_msg "ERROR" "$awg_show_output"
       die "Проблема с запуском интерфейса awg0."
    fi
    log "Интерфейс awg0 активен. Вывод 'awg show':"
    echo "$awg_show_output" | log_msg "INFO" # Логируем вывод awg show

    log "Шаг 7 успешно завершен."
    update_state 99
}

# ШАГ 99: Завершение установки
step99_finish() {
    # Этот шаг вызывается, когда state=99
    log "### ЗАВЕРШЕНИЕ УСТАНОВКИ ###"
    log "=============================================================================="
    log "Установка и настройка AmneziaWG УСПЕШНО ЗАВЕРШЕНА!"
    log " "
    log "КЛИЕНТСКИЕ ФАЙЛЫ:"
    log "  Конфигурационные файлы (.conf) и QR-коды (.png) находятся в директории:"
    log "  $AWG_DIR"
    log "  Скопируйте их на ваши клиентские устройства безопасным способом."
    log "  Пример команды для копирования (выполнять на вашем локальном компьютере):"
    log "    scp root@<IP_АДРЕС_СЕРВЕРА>:$AWG_DIR/*.conf /путь/на/вашем/компьютере/"
    log "    scp root@<IP_АДРЕС_СЕРВЕРА>:$AWG_DIR/*.png /путь/на/вашем/компьютере/"
    log " "
    log "ПОЛЕЗНЫЕ КОМАНДЫ НА СЕРВЕРЕ:"
    log "  systemctl status awg-quick@awg0  - Проверить статус сервиса"
    log "  systemctl stop awg-quick@awg0   - Остановить AmneziaWG"
    log "  systemctl start awg-quick@awg0  - Запустить AmneziaWG"
    log "  systemctl restart awg-quick@awg0 - Перезапустить AmneziaWG"
    log "  journalctl -u awg-quick@awg0 -f - Следить за логами AmneziaWG в реальном времени"
    log "  awg show                         - Показать текущий статус AmneziaWG (пиры, ключи)"
    log "  ufw status verbose               - Показать статус и правила фаервола"
    log " "
    log "УПРАВЛЕНИЕ ПОЛЬЗОВАТЕЛЯМИ:"
    log "  Используйте скрипт 'manage_amneziawg.sh', который должен быть скачан в $AWG_DIR."
    log "  Пример: sudo bash $AWG_DIR/manage_amneziawg.sh add new_client_name"
    log " "
    log "Удаление файла состояния установки..."
    if ! rm -f "$STATE_FILE"; then log_warn "Не удалось удалить файл состояния $STATE_FILE"; fi
    log "Установка полностью завершена. Лог файл: $LOG_FILE"
    log "=============================================================================="
}


# --- Основной цикл выполнения скрипта ---
initialize_setup

# Цикл выполняется до тех пор, пока не будет достигнут шаг завершения (99)
while (( current_step < 99 )); do
    log "Выполнение шага $current_step..."
    case $current_step in
        1) step1_update_system_and_networking ;;
        2) step2_install_amnezia ;;
        3) step3_check_module; current_step=4 ;; # Переход к следующему шагу без break/continue
        4) step4_setup_firewall; current_step=5 ;;
        5) step5_setup_python; current_step=6 ;;
        6) step6_generate_configs; current_step=7 ;;
        7) step7_start_service; current_step=99 ;; # Установка завершена
        *) die "Ошибка: Неизвестный или недостижимый шаг состояния $current_step в файле $STATE_FILE." ;;
    esac
    # Если шаг требовал перезагрузки, скрипт завершится внутри request_reboot
done

# Вызов финального шага, если цикл завершился (current_step == 99)
if (( current_step == 99 )); then
    step99_finish
fi

exit 0
