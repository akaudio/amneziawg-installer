#!/bin/bash

# ==============================================================================
# Скрипт для установки и настройки AmneziaWG на Ubuntu 24.04 LTS Minimal
# Автор: @bivlked)
# Версия: 1.8
# Дата: 2025-04-14
# Репозиторий: https://github.com/bivlked/amneziawg-installer
# ==============================================================================

# --- Безопасный режим и Константы ---
# set -e # Раскомментируйте для немедленного выхода при любой ошибке
set -o pipefail # Выход, если команда в пайпе завершается с ошибкой

# Директория для файлов скрипта, логов, конфигов пользователя и состояния
# Используем /root/awg, т.к. скрипт запускается через sudo bash
AWG_DIR="/root/awg"
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
# URL скрипта управления
MANAGE_SCRIPT_URL="https://raw.githubusercontent.com/bivlked/amneziawg-installer/main/manage_amneziawg.sh"
MANAGE_SCRIPT_PATH="$AWG_DIR/manage_amneziawg.sh"

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
    if [[ "$type" == "ERROR" || "$type" == "WARN" ]]; then
        printf "%s\n" "$log_entry" >&2
    else
        printf "%s\n" "$log_entry"
    fi
}

log() { log_msg "INFO" "$1"; }
log_warn() { log_msg "WARN" "$1"; }
log_error() { log_msg "ERROR" "$1"; }
# Функция для выхода при ошибке
die() {
    log_error "КРИТИЧЕСКАЯ ОШИБКА: $1"
    log_error "Установка прервана. Пожалуйста, проверьте лог $LOG_FILE для деталей."
    exit 1
}

# --- Функции Управления Состоянием ---
# Функция для записи следующего шага
update_state() {
    local next_step=$1
    # Убедимся, что директория существует
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "$next_step" > "$STATE_FILE" || die "Не удалось записать состояние в $STATE_FILE"
    log "Состояние обновлено: следующий шаг - $next_step"
}

# Функция для запроса перезагрузки
request_reboot() {
    local next_step_after_reboot=$1
    update_state "$next_step_after_reboot" # Записываем шаг ПОСЛЕ перезагрузки
    echo "" >> "$LOG_FILE" # Пустая строка для визуального разделения в логе
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log_warn "!!! ТРЕБУЕТСЯ ПЕРЕЗАГРУЗКА СИСТЕМЫ !!!"
    log_warn "!!! После перезагрузки, пожалуйста, запустите этот скрипт снова ОДНОЙ КОМАНДОЙ:"
    log_warn "!!! wget -O - $MANAGE_SCRIPT_URL | sudo bash" # Исправлен URL на правильный
    log_warn "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "" >> "$LOG_FILE"
    # Спросить пользователя, если скрипт запущен интерактивно
    if [[ -t 0 && -t 1 ]]; then # Проверка, что stdin и stdout подключены к терминалу
      # Читаем явно с терминала, чтобы избежать проблем с пайпом
      read -p "Перезагрузить сейчас? [y/N]: " confirm_reboot < /dev/tty
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
      log_warn "Скрипт запущен неинтерактивно или ввод/вывод перенаправлен."
      log_warn "Перезагрузка не будет выполнена автоматически."
      log_warn "Пожалуйста, перезагрузите систему вручную и запустите скрипт снова."
      exit 1 # Выход, чтобы избежать продолжения без перезагрузки
    fi
}

# --- Шаг 0: Инициализация и Настройка Переменных ---
initialize_setup() {
    # Перенаправляем весь вывод функций в лог (и на экран через log_msg)
    # Делаем это здесь, чтобы лог создавался в правильном месте
    mkdir -p "$AWG_DIR" || die "Не удалось создать рабочую директорию $AWG_DIR"
    # Устанавливаем права, чтобы root мог писать в лог, даже если директорию создал обычный пользователь через sudo
    chown root:root "$AWG_DIR" || log_warn "Не удалось сменить владельца $AWG_DIR на root:root"
    exec > >(tee -a "$LOG_FILE") 2> >(tee -a "$LOG_FILE" >&2)

    log "--- НАЧАЛО УСТАНОВКИ / ПРОВЕРКА СОСТОЯНИЯ ---"
    log "### ШАГ 0: Инициализация и проверка прав ###"

    # Проверка прав root
    if [ "$(id -u)" -ne 0 ]; then die "Скрипт должен быть запущен с правами root (через sudo)."; fi

    # Переходим в рабочую директорию (уже создана)
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
        # Запрос порта у пользователя (читаем с терминала!)
        read -p "Введите UDP порт для AmneziaWG (рекомендуется 1024-65535) [${default_port}]: " input_port < /dev/tty
        AWG_PORT=${input_port:-$default_port}
        if ! [[ "$AWG_PORT" =~ ^[0-9]+$ ]] || [ "$AWG_PORT" -lt 1024 ] || [ "$AWG_PORT" -gt 65535 ]; then
            die "Некорректный номер порта: $AWG_PORT. Введите число от 1024 до 65535."
        fi

        # Запрос подсети у пользователя (читаем с терминала!)
        read -p "Введите подсеть туннеля (например, 10.x.x.1/24) [${default_subnet}]: " input_subnet < /dev/tty
        AWG_TUNNEL_SUBNET=${input_subnet:-$default_subnet}
        if ! [[ "$AWG_TUNNEL_SUBNET" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
            printf "%s\n" "ERROR: Некорректный формат подсети: '$AWG_TUNNEL_SUBNET'. Пример: 10.9.9.1/24." >&2
            exit 1
        fi

        # Сохраняем введенные/дефолтные настройки в файл
        log "Сохранение настроек в $CONFIG_FILE..."
        # Используем printf для большей надежности при записи
        printf "%s\n" "# Конфигурация установки AmneziaWG" > "$CONFIG_FILE" || die "Не удалось записать в $CONFIG_FILE"
        printf "%s\n" "# Этот файл генерируется автоматически." >> "$CONFIG_FILE" || die "Не удалось записать в $CONFIG_FILE"
        printf "export AWG_PORT=%s\n" "${AWG_PORT}" >> "$CONFIG_FILE" || die "Не удалось записать порт в $CONFIG_FILE"
        printf "export AWG_TUNNEL_SUBNET='%s'\n" "${AWG_TUNNEL_SUBNET}" >> "$CONFIG_FILE" || die "Не удалось записать подсеть в $CONFIG_FILE" # Добавлены кавычки
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
        if ! [[ "$current_step" =~ ^[0-9]+$ ]]; then
            log_warn "Файл состояния $STATE_FILE поврежден или содержит нечисловое значение. Начинаем установку с начала."
            current_step=1
            update_state 1
        else
             log "Обнаружен файл состояния. Продолжение установки с шага $current_step."
        fi
    else
        current_step=1
        log "Файл состояния не найден. Начало установки с шага 1."
        update_state 1
    fi
    log "Шаг 0 завершен."
}

# --- Функции для каждого шага установки ---

# ШАГ 1: Обновление системы, отключение IPv6, включение IP Forwarding
step1_update_system_and_networking() {
    update_state 1 # Помечаем, что мы выполняем этот шаг
    log "### ШАГ 1: Обновление системы и настройка ядра ###"
    log "Обновление списка пакетов..."
    apt update -y || die "Ошибка при apt update."
    log "Обновление системы (может занять время)..."
    # DEBIAN_FRONTEND=noninteractive предотвращает большинство диалогов apt
    DEBIAN_FRONTEND=noninteractive apt full-upgrade -y || die "Ошибка при apt full-upgrade."
    log "Система обновлена."
    # Установка базовых утилит, если их вдруг нет
    DEBIAN_FRONTEND=noninteractive apt install -y curl wget gpg sudo net-tools || log_warn "Не удалось установить базовые утилиты."

    log "Отключение IPv6..."
    # Используем tee -a для добавления строк в конец файла, если их там еще нет
    {
        grep -qxF 'net.ipv6.conf.all.disable_ipv6 = 1' /etc/sysctl.conf || echo 'net.ipv6.conf.all.disable_ipv6 = 1'
        grep -qxF 'net.ipv6.conf.default.disable_ipv6 = 1' /etc/sysctl.conf || echo 'net.ipv6.conf.default.disable_ipv6 = 1'
        grep -qxF 'net.ipv6.conf.lo.disable_ipv6 = 1' /etc/sysctl.conf || echo 'net.ipv6.conf.lo.disable_ipv6 = 1'
    } | tee -a /etc/sysctl.conf > /dev/null || log_warn "Не удалось записать все параметры IPv6 в /etc/sysctl.conf"
    log "Параметры для отключения IPv6 добавлены в /etc/sysctl.conf (если отсутствовали)."

    log "Включение IPv4 Forwarding..."
    # Создаем или перезаписываем файл для настройки форвардинга
    echo "net.ipv4.ip_forward = 1" > /etc/sysctl.d/10-amneziawg-forward.conf || die "Не удалось создать файл /etc/sysctl.d/10-amneziawg-forward.conf"
    log "Создан файл /etc/sysctl.d/10-amneziawg-forward.conf."

    log "Применение настроек sysctl..."
    # Вывод sysctl может быть большим, не логируем его полностью
    if ! sysctl -p --system > /dev/null; then log_warn "Не удалось применить все настройки sysctl немедленно (это нормально, применятся после перезагрузки)."; fi
    log "Настройки sysctl применены (или будут применены после перезагрузки)."

    log "Шаг 1 успешно завершен."
    # После этого шага ТРЕБУЕТСЯ перезагрузка для полного применения настроек ядра
    request_reboot 2 # Указываем, что после ребута нужно начать с шага 2
}

# ШАГ 2: Установка AmneziaWG и зависимостей
step2_install_amnezia() {
    update_state 2 # Помечаем, что мы выполняем этот шаг
    log "### ШАГ 2: Установка AmneziaWG и зависимостей ###"

    local sources_file="/etc/apt/sources.list.d/ubuntu.sources" # Стандартный путь в Ubuntu 24.04

    # Автоматическое включение deb-src
    log "Проверка и включение deb-src репозиториев в $sources_file..."
    if [ ! -f "$sources_file" ]; then die "Файл $sources_file не найден. Невозможно проверить или включить deb-src."; fi

    # Проверяем, есть ли строки ТОЛЬКО с 'Types: deb'
    if grep -q "^Types: deb$" "$sources_file"; then
        log "Обнаружены строки 'Types: deb' без 'deb-src'. Включение..."
        local backup_file="${sources_file}.bak-$(date +%F_%T)"
        cp "$sources_file" "$backup_file" || log_warn "Не удалось создать резервную копию $backup_file"
        # Используем -i без суффикса для редактирования на месте (GNU sed)
        sed -i '/^Types: deb$/s/Types: deb/Types: deb deb-src/' "$sources_file" || die "Ошибка при модификации $sources_file с помощью sed."
        # Проверка после модификации
        if grep -q "^Types: deb$" "$sources_file"; then
             log_warn "Не удалось автоматически включить все deb-src. Возможно, требуется ручное редактирование $sources_file."
             # Не выходим, но предупреждаем
        else
             log "deb-src успешно добавлены в $sources_file."
             log "Обновление списка пакетов после изменения sources..."
             apt update -y || die "Ошибка при apt update после включения deb-src."
        fi
    elif ! grep -q "Types: deb deb-src" "$sources_file"; then
         # Если нет ни 'Types: deb', ни 'Types: deb deb-src', возможно используется старый формат sources.list
         # Или файл имеет нестандартную структуру. Предупреждаем.
         log_warn "Не найдены строки 'Types: deb deb-src' или 'Types: deb' в $sources_file."
         log_warn "Проверьте конфигурацию APT. Установка DKMS может завершиться ошибкой без deb-src."
         # Пробуем обновить список пакетов в любом случае
         apt update -y || die "Ошибка при apt update."
    else
        log "deb-src репозитории уже включены."
        apt update -y # Обновим на всякий случай
    fi

    # Добавление PPA Amnezia
    log "Добавление PPA репозитория Amnezia..."
    # Проверяем наличие файла репозитория перед добавлением
    local ppa_list_file="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).list"
    local ppa_sources_file="/etc/apt/sources.list.d/amnezia-ubuntu-ppa-$(lsb_release -sc).sources"
    if [ ! -f "$ppa_list_file" ] && [ ! -f "$ppa_sources_file" ]; then
        # Используем DEBIAN_FRONTEND=noninteractive для add-apt-repository, если возможно
        DEBIAN_FRONTEND=noninteractive add-apt-repository -y ppa:amnezia/ppa || die "Не удалось добавить PPA amnezia/ppa."
        log "PPA amnezia/ppa добавлен."
        log "Обновление списка пакетов после добавления PPA..."
        apt update -y || die "Ошибка при apt update после добавления PPA."
    else
        log "PPA amnezia/ppa уже добавлен."
        # Обновление все равно нужно
        apt update -y || die "Ошибка при apt update."
    fi

    # Установка необходимых пакетов
    log "Установка AmneziaWG (DKMS), инструментов и зависимостей для сборки..."
    local packages_to_install=(
        amneziawg-dkms amneziawg-tools wireguard-tools
        dkms "linux-headers-$(uname -r)" build-essential dpkg-dev
    )
    # Проверяем наличие headers для текущего ядра
    if ! dpkg -s "linux-headers-$(uname -r)" &> /dev/null; then
        log_warn "Заголовки для текущего ядра linux-headers-$(uname -r) не найдены. Попытка установить generic версию..."
        packages_to_install+=( "linux-headers-generic" )
    fi

    # Устанавливаем или обновляем пакеты
    if ! DEBIAN_FRONTEND=noninteractive apt install -y "${packages_to_install[@]}"; then
        log_warn "Ошибка при установке пакетов: ${packages_to_install[*]}. Попытка исправить..."
        # Попытка исправить сломанные зависимости
        if ! DEBIAN_FRONTEND=noninteractive apt --fix-broken install -y; then
           die "Не удалось исправить зависимости ('apt --fix-broken install'). Проверьте вывод apt и логи DKMS."
        fi
        log "Повторная попытка установки пакетов после исправления зависимостей..."
         if ! DEBIAN_FRONTEND=noninteractive apt install -y "${packages_to_install[@]}"; then
             die "Повторная установка пакетов также не удалась. Проверьте логи и системные требования."
         fi
    fi
    log "Пакеты AmneziaWG и зависимости успешно установлены."

    # Проверка статуса DKMS модуля
    log "Проверка статуса DKMS модуля amneziawg..."
    local dkms_status
    dkms_status=$(dkms status 2>&1) # Захватываем и stderr
    if ! echo "$dkms_status" | grep -q 'amneziawg.*installed'; then
        log_warn "DKMS статус не показывает модуль amneziawg как 'installed'. Проверьте логи DKMS (/var/lib/dkms/...). DKMS статус:"
        log_msg "WARN" "$dkms_status"
        # Не выходим, т.к. модуль мог установиться и без DKMS, но предупреждаем
    else
        log "DKMS статус показывает модуль amneziawg как установленный."
    fi

    log "Шаг 2 успешно завершен."
    # После установки DKMS модуля ТРЕБУЕТСЯ перезагрузка для гарантированной сборки и загрузки
    request_reboot 3 # Указываем, что после ребута нужно начать с шага 3
}

# ШАГ 3: Проверка загрузки модуля ядра
step3_check_module() {
    update_state 3 # Помечаем, что мы выполняем этот шаг
    log "### ШАГ 3: Проверка загрузки модуля ядра AmneziaWG ###"
    # Ждем немного, чтобы модуль успел загрузиться после перезагрузки, если он в автозагрузке
    sleep 2
    if lsmod | grep -q -w amneziawg; then # -w для точного совпадения слова
        log "Модуль amneziawg уже загружен."
    else
        log "Модуль amneziawg не найден в lsmod. Попытка загрузить вручную..."
        modprobe amneziawg || die "Ошибка: Не удалось загрузить модуль amneziawg через modprobe. Проверьте dmesg и логи DKMS."
        log "Модуль успешно загружен через modprobe."
        # Добавляем его в автозагрузку, если пришлось грузить вручную
        local modules_file="/etc/modules-load.d/amneziawg.conf"
        # Создаем директорию, если ее нет
        mkdir -p "$(dirname "$modules_file")"
        if ! grep -qxF 'amneziawg' "$modules_file" 2>/dev/null; then
             echo "amneziawg" > "$modules_file" || log_warn "Не удалось записать модуль в $modules_file"
             log "Добавлено в $modules_file для автозагрузки."
        fi
    fi
    log "Проверка информации о модуле..."
    # Логируем вывод modinfo
    modinfo amneziawg | grep -E "filename|version|vermagic|srcversion" | log_msg "INFO"
    # Проверка совместимости vermagic
    local current_vermagic
    current_vermagic=$(modinfo amneziawg | grep vermagic | awk '{print $2}') || current_vermagic="<не найден>"
    local kernel_release
    kernel_release=$(uname -r)
    if [[ "$current_vermagic" != "$kernel_release" ]]; then
        log_warn "Версия ядра в vermagic модуля ($current_vermagic) НЕ совпадает с текущим ядром ($kernel_release)."
        log_warn "Это МОЖЕТ вызвать проблемы в работе VPN или при следующих обновлениях ядра!"
        log_warn "Рекомендуется проверить логи DKMS и убедиться, что модуль собран для правильного ядра."
    else
        log "Версия ядра vermagic модуля совпадает с текущим ядром."
    fi
    log "Шаг 3 успешно завершен."
    update_state 4 # Переходим к шагу 4 без перезагрузки
}

# ШАГ 4: Настройка фаервола (UFW)
step4_setup_firewall() {
    update_state 4
    log "### ШАГ 4: Настройка фаервола UFW ###"
    log "Установка UFW (если не установлен)..."
    DEBIAN_FRONTEND=noninteractive apt install -y ufw || die "Не удалось установить UFW."

    log "Настройка правил UFW..."
    # Сбрасываем правила
    if ! ufw --force reset; then log_warn "Не удалось сбросить UFW."; fi # Используем --force для неинтерактивного сброса
    ufw default deny incoming      || log_warn "Не удалось установить default deny incoming."
    ufw default allow outgoing     || log_warn "Не удалось установить default allow outgoing."

    # --- ИЗМЕНЕНИЕ: Добавляем правило ЯВНО по порту 22/tcp ---
    log "Добавление правила для стандартного порта SSH (22/tcp)..."
    ufw allow 22/tcp comment "SSH Access" || log_warn "Не удалось добавить правило для порта 22/tcp."
    # --------------------------------------------------------

    # Добавляем правило для порта AmneziaWG
    ufw allow "${AWG_PORT}/udp" comment "AmneziaWG VPN" || log_warn "Не удалось добавить правило для порта AmneziaWG."
    log "Правила UFW настроены (запрет по умолч., разрешены 22/tcp и ${AWG_PORT}/udp)."

    # Убираем отладочный вывод, т.к. он вызывал BrokenPipe
    # log "Отладочный вывод 'ufw status verbose' ПЕРЕД проверкой:"
    # ufw status verbose | log_msg "DEBUG"

    log "Включение UFW..."
    if ! ufw status | grep -q 'Status: active'; then
        # --- ИЗМЕНЕННАЯ ПРОВЕРКА SSH (по порту 22) ---
        # Проверяем, разрешен ли порт 22/tcp
        if ! ufw status verbose | grep -q '22/tcp.*ALLOW IN'; then
             log_error "Правило для стандартного порта SSH (22/tcp) не найдено в UFW!"
             log_warn "Это критично для сохранения доступа к серверу."
             log_warn "Если ваш SSH на ДРУГОМ порту, вам НУЖНО было добавить правило для него вручную ДО этого шага!"
             # Запрос подтверждения в интерактивном режиме
             if [[ -t 0 && -t 1 ]]; then
                 read -p "Вы уверены, что доступ по SSH обеспечен и хотите включить фаервол? [y/N]: " confirm_ssh < /dev/tty
                 if ! [[ "$confirm_ssh" =~ ^[Yy]$ ]]; then
                      die "Включение UFW отменено пользователем для предотвращения блокировки доступа."
                 fi
                 log_warn "Продолжение включения UFW по подтверждению пользователя, несмотря на отсутствие явного правила для порта 22!"
             else
                 die "Включение UFW прервано, т.к. правило для порта 22/tcp не найдено, а скрипт запущен неинтерактивно."
             fi
        else
             log "Проверка наличия правила для порта 22/tcp прошла успешно."
        fi
        # --- КОНЕЦ ИЗМЕНЕНИЙ ПРОВЕРКИ ---

        # Включаем UFW
        ufw enable <<< "y" || die "Не удалось включить UFW."
        log "UFW включен и активирован при загрузке."
    else
        log "UFW уже активен. Перезагрузка правил..."
        ufw reload || log_warn "Не удалось перезагрузить правила UFW."
    fi

    log "Текущий статус UFW ПОСЛЕ включения/перезагрузки:"
    ufw status verbose | log_msg "INFO"
    log "Шаг 4 успешно завершен."
    update_state 5
}

# ШАГ 5: Настройка Python окружения, утилит и скачивание скрипта управления
step5_setup_python() {
    update_state 5 # Помечаем, что мы выполняем этот шаг
    log "### ШАГ 5: Настройка Python, утилит и скачивание скрипта управления ###"
    log "Установка необходимых Python пакетов (venv, pip)..."
    DEBIAN_FRONTEND=noninteractive apt install -y python3-venv python3-pip || die "Не удалось установить python3-venv/pip."

    cd "$AWG_DIR" || die "Не удалось перейти в рабочую директорию $AWG_DIR"

    # Создание venv, если его нет
    if [ ! -d "venv" ]; then
        log "Создание виртуального окружения Python в $AWG_DIR/venv..."
        python3 -m venv venv || die "Не удалось создать venv."
        log "Виртуальное окружение создано."
    else
        log "Виртуальное окружение venv уже существует."
    fi

    # Установка зависимостей в venv
    log "Обновление pip и установка qrcode[pil] в venv..."
    # Убедимся, что Python из venv существует и исполняемый
    if [ ! -x "$PYTHON_VENV" ]; then die "Не найден исполняемый файл Python в venv: $PYTHON_VENV"; fi
    "$PYTHON_VENV" -m pip install -U pip || die "Не удалось обновить pip в venv."
    "$PYTHON_VENV" -m pip install qrcode[pil] || die "Не удалось установить qrcode[pil] в venv."
    log "Зависимости Python установлены."

    # Скачивание скрипта awgcfg.py
    if [ ! -f "$AWGCFG_SCRIPT" ]; then
        log "Скачивание скрипта $AWGCFG_SCRIPT..."
        # Используем curl для большей совместимости и опций
        curl -fLso "$AWGCFG_SCRIPT" https://gist.githubusercontent.com/remittor/8c3d9ff293b2ba4b13c367cc1a69f9eb/raw/awgcfg.py || die "Не удалось скачать $AWGCFG_SCRIPT."
        chmod +x "$AWGCFG_SCRIPT" || die "Не удалось сделать $AWGCFG_SCRIPT исполняемым."
        log "Скрипт $AWGCFG_SCRIPT скачан и сделан исполняемым."
    elif [ ! -x "$AWGCFG_SCRIPT" ]; then
         # Если файл есть, но не исполняемый
         chmod +x "$AWGCFG_SCRIPT" || die "Не удалось сделать $AWGCFG_SCRIPT исполняемым."
         log "Скрипт $AWGCFG_SCRIPT сделан исполняемым."
    else
        log "Скрипт $AWGCFG_SCRIPT уже существует и является исполняемым."
    fi

    # Скачивание скрипта управления manage_amneziawg.sh
    log "Скачивание скрипта управления $MANAGE_SCRIPT_PATH..."
    if curl -fLso "$MANAGE_SCRIPT_PATH" "$MANAGE_SCRIPT_URL"; then
        chmod +x "$MANAGE_SCRIPT_PATH" || die "Не удалось сделать $MANAGE_SCRIPT_PATH исполняемым."
        log "Скрипт управления $MANAGE_SCRIPT_PATH скачан и сделан исполняемым."
    else
        log_error "Не удалось скачать скрипт управления $MANAGE_SCRIPT_PATH с URL: $MANAGE_SCRIPT_URL"
        log_error "Управление пользователями через скрипт будет недоступно."
        # Не выходим из скрипта установки, но предупреждаем
    fi

    log "Шаг 5 успешно завершен."
    update_state 6 # Переходим к шагу 6
}


# ШАГ 6: Генерация конфигураций AmneziaWG и кастомизация шаблона
step6_generate_configs() {
    update_state 6 # Помечаем, что мы выполняем этот шаг
    log "### ШАГ 6: Генерация конфигураций AmneziaWG ###"
    cd "$AWG_DIR" || die "Не удалось перейти в рабочую директорию $AWG_DIR"

    local server_conf_dir="/etc/amnezia/amneziawg"
    local server_conf_file="$server_conf_dir/awg0.conf"

    mkdir -p "$server_conf_dir" || die "Не удалось создать директорию $server_conf_dir"
    log "Создана/проверена директория $server_conf_dir."

    # Сначала генерируем конфигурацию сервера (--make)
    log "Генерация основного конфигурационного файла сервера $server_conf_file..."
    "$PYTHON_VENV" "$AWGCFG_SCRIPT" --make "$server_conf_file" -i "${AWG_TUNNEL_SUBNET}" -p "${AWG_PORT}" || die "Ошибка генерации конфигурации сервера $server_conf_file."
    log "Конфигурация сервера успешно сгенерирована."

    # Резервная копия и права доступа к конфигу сервера
    local server_conf_bak="${server_conf_file}.bak-$(date +%F_%T)"
    cp "$server_conf_file" "$server_conf_bak" || log_warn "Не удалось создать резервную копию $server_conf_bak"
    log "Создана резервная копия $server_conf_bak"
    chmod 700 /etc/amnezia || log_warn "Не удалось установить права на /etc/amnezia"
    chmod 700 "$server_conf_dir" || log_warn "Не удалось установить права на $server_conf_dir"
    chmod 600 "$server_conf_file" || log_warn "Не удалось установить права на $server_conf_file"
    log "Установлены безопасные права доступа к конфигурации."

    # Затем создаем и кастомизируем шаблон клиента (--create и sed)
    log "Проверка/создание и кастомизация шаблона $CLIENT_TEMPLATE_FILE..."
    if [ ! -f "$CLIENT_TEMPLATE_FILE" ]; then
         log "Шаблон $CLIENT_TEMPLATE_FILE не найден, создаем..."
         "$PYTHON_VENV" "$AWGCFG_SCRIPT" --create || die "Не удалось создать шаблон $CLIENT_TEMPLATE_FILE. Проверьте доступность внешнего IP или лог awgcfg.py."
         log "Шаблон $CLIENT_TEMPLATE_FILE создан."
    else
         log "Используется существующий шаблон $CLIENT_TEMPLATE_FILE."
         local template_backup="${CLIENT_TEMPLATE_FILE}.bak-$(date +%F_%T)"
         cp "$CLIENT_TEMPLATE_FILE" "$template_backup" || log_warn "Не удалось создать резервную копию шаблона $template_backup."
    fi

    # Применяем желаемые изменения к шаблону:
    log "Применение кастомных настроек к шаблону:"
    local sed_failed=0
    # 1. DNS = 1.1.1.1
    sed -i 's/^DNS = .*/DNS = 1.1.1.1/' "$CLIENT_TEMPLATE_FILE" && log " - DNS установлен в 1.1.1.1" || { log_warn "Не удалось установить DNS в шаблоне."; sed_failed=1; }
    # 2. PersistentKeepalive = 33
    sed -i 's/^PersistentKeepalive = .*/PersistentKeepalive = 33/' "$CLIENT_TEMPLATE_FILE" && log " - PersistentKeepalive установлен в 33" || { log_warn "Не удалось установить PersistentKeepalive в шаблоне."; sed_failed=1; }
    # 3. AllowedIPs = Список Amnezia + DNS Google/Cloudflare
    local amnezia_allowed_ips="0.0.0.0/5, 8.0.0.0/7, 11.0.0.0/8, 12.0.0.0/6, 16.0.0.0/4, 32.0.0.0/3, 64.0.0.0/2, 128.0.0.0/3, 160.0.0.0/5, 168.0.0.0/6, 172.0.0.0/12, 172.32.0.0/11, 172.64.0.0/10, 172.128.0.0/9, 173.0.0.0/8, 174.0.0.0/7, 176.0.0.0/4, 192.0.0.0/9, 192.128.0.0/11, 192.160.0.0/13, 192.169.0.0/16, 192.170.0.0/15, 192.172.0.0/14, 192.176.0.0/12, 192.192.0.0/10, 193.0.0.0/8, 194.0.0.0/7, 196.0.0.0/6, 200.0.0.0/5, 208.0.0.0/4, 8.8.8.8/32, 1.1.1.1/32"
    # Используем другой разделитель для sed (#) из-за слешей в IP-адресах
    sed -i "s#^AllowedIPs = .*#AllowedIPs = ${amnezia_allowed_ips}#" "$CLIENT_TEMPLATE_FILE" && log " - AllowedIPs установлен в список Amnezia + DNS" || { log_warn "Не удалось установить AllowedIPs в шаблоне."; sed_failed=1; }

    if [ "$sed_failed" -eq 1 ]; then log_warn "Не все настройки шаблона были применены успешно."; fi
    log "Шаблон $CLIENT_TEMPLATE_FILE кастомизирован."

    # Добавление тестовых/начальных клиентов
    log "Добавление/проверка клиентов по умолчанию (my_phone, my_laptop)..."
    # Используем grep для проверки наличия секции пира (комментарий '#_Name =' обязателен!)
    if ! grep -q "^#_Name = my_phone$" "$server_conf_file"; then
      "$PYTHON_VENV" "$AWGCFG_SCRIPT" -a "my_phone" || log_warn "Не удалось добавить клиента my_phone."
    else log "Клиент my_phone уже существует в $server_conf_file."; fi

    if ! grep -q "^#_Name = my_laptop$" "$server_conf_file"; then
      "$PYTHON_VENV" "$AWGCFG_SCRIPT" -a "my_laptop" || log_warn "Не удалось добавить клиента my_laptop."
    else log "Клиент my_laptop уже существует в $server_conf_file."; fi

    # Генерация клиентских файлов
    log "Генерация клиентских конфигурационных файлов (.conf) и QR-кодов (.png)..."
    "$PYTHON_VENV" "$AWGCFG_SCRIPT" -c -q || die "Ошибка генерации клиентских конфигурационных файлов."

    log "Клиентские файлы созданы/обновлены в директории $AWG_DIR:"
    ls -l "$AWG_DIR"/*.conf "$AWG_DIR"/*.png | log_msg "INFO" # Логируем вывод ls
    log "Шаг 6 успешно завершен."
    update_state 7 # Переходим к шагу 7
}


# ШАГ 7: Запуск и автозагрузка сервиса
step7_start_service() {
    update_state 7 # Помечаем, что мы выполняем этот шаг
    log "### ШАГ 7: Запуск и автозагрузка сервиса AmneziaWG ###"
    log "Включение автозагрузки и запуск сервиса awg-quick@awg0..."
    # enable --now включает и запускает
    systemctl enable --now awg-quick@awg0 || die "Не удалось включить или запустить сервис awg-quick@awg0. Проверьте логи 'journalctl -u awg-quick@awg0'."
    log "Сервис awg-quick@awg0 включен и запущен."

    log "Проверка статуса сервиса systemd (ожидание 3 сек)..."
    sleep 3
    systemctl status awg-quick@awg0 --no-pager -l | log_msg "INFO" # Логируем вывод статуса

    # Проверяем статус более надежно
    if systemctl is-failed --quiet awg-quick@awg0; then
        die "Сервис awg-quick@awg0 находится в состоянии failed. Проверьте 'journalctl -u awg-quick@awg0'."
    fi
    # Для wg-quick@.service статус 'exited' - это норма, главное не 'failed'.

    log "Проверка статуса интерфейса AmneziaWG (awg show)..."
    sleep 2 # Даем интерфейсу время на инициализацию
    local awg_show_output
    # Выполняем в subshell чтобы не загрязнять переменные основного скрипта, если awg выдаст ошибку
    awg_show_output=$(awg show 2>&1)
    local awg_show_status=$?
    # Проверяем код возврата И наличие строки "interface: awg0"
    if [ $awg_show_status -ne 0 ] || ! echo "$awg_show_output" | grep -q "interface: awg0"; then
       log_error "Команда 'awg show' не показывает активный интерфейс awg0 или завершилась с ошибкой (код $awg_show_status). Вывод команды:"
       log_msg "ERROR" "$awg_show_output" # Логируем вывод ошибки
       die "Проблема с запуском интерфейса awg0. Проверьте конфигурацию и логи."
    fi
    log "Интерфейс awg0 активен. Вывод 'awg show':"
    echo "$awg_show_output" | log_msg "INFO" # Логируем успешный вывод

    log "Шаг 7 успешно завершен."
    update_state 99 # Указываем, что всё успешно завершено
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
    log "  Скрипт 'manage_amneziawg.sh' был скачан в $AWG_DIR."
    log "  Используйте его для добавления/удаления клиентов:"
    log "  Пример: sudo bash $MANAGE_SCRIPT_PATH add new_client_name"
    log "  (Не забудьте перезапустить сервис после добавления/удаления: sudo systemctl restart awg-quick@awg0)"
    log "  Справка: sudo bash $MANAGE_SCRIPT_PATH help"
    log " "
    log "Удаление файла состояния установки..."
    # Используем rm -f для игнорирования ошибки, если файла нет
    rm -f "$STATE_FILE" || log_warn "Не удалось удалить файл состояния $STATE_FILE"
    log "Установка полностью завершена. Лог файл: $LOG_FILE"
    log "=============================================================================="
}


# --- Основной цикл выполнения скрипта ---
initialize_setup

# Цикл выполняется до тех пор, пока не будет достигнут шаг завершения (99)
# Переменная current_step обновляется либо при чтении state_file, либо после успешного выполнения шага
while (( current_step < 99 )); do
    log "Выполнение шага $current_step..."
    case $current_step in
        1) step1_update_system_and_networking ;; # Завершится с exit или request_reboot
        2) step2_install_amnezia ;;             # Завершится с exit или request_reboot
        3) step3_check_module; current_step=4 ;; # Обновляем current_step для следующей итерации
        4) step4_setup_firewall; current_step=5 ;;
        5) step5_setup_python; current_step=6 ;;
        6) step6_generate_configs; current_step=7 ;;
        7) step7_start_service; current_step=99 ;; # Установка завершена, выходим из цикла
        *) die "Ошибка: Неизвестный или недостижимый шаг состояния $current_step в файле $STATE_FILE." ;;
    esac
    # Если шаг требовал перезагрузки, скрипт завершится внутри request_reboot
done

# Вызов финального шага, если цикл завершился нормально (current_step == 99)
if (( current_step == 99 )); then
    step99_finish
fi

exit 0
