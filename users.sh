#!/usr/bin/env bash
set -euo pipefail

AWG_DIR="${AWG_DIR:-/root/awg}"
MANAGE_SCRIPT="${MANAGE_SCRIPT:-$AWG_DIR/manage_amneziawg.sh}"
SERVER_CONF_DEFAULT="/etc/amnezia/amneziawg/awg0.conf"
MAIN_CONFIG_FILE="$AWG_DIR/.main.config"
PYTHON_BIN="${PYTHON_BIN:-$AWG_DIR/venv/bin/python}"

TTY_OUT="/dev/tty"
TTY_IN="/dev/tty"
if [[ ! -w "$TTY_OUT" ]]; then TTY_OUT="/dev/stderr"; fi
if [[ ! -r "$TTY_IN" ]]; then TTY_IN="/dev/stdin"; fi

die() { printf "ERROR: %s\n" "$*" >&2; exit 1; }
need_file() { [[ -f "$1" ]] || die "Не найден файл: $1"; }
need_exec() { [[ -x "$1" ]] || die "Не найден/не исполняемый: $1"; }

sanitize() {
  printf "%s" "$1" | tr -d '\r\n' | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//'
}

validate_name() {
  local n
  n="$(sanitize "$1")"
  [[ -n "$n" ]] || return 1
  [[ ${#n} -le 63 ]] || return 1
  [[ "$n" =~ ^[a-zA-Z0-9_-]+$ ]] || return 1
  return 0
}

if [[ -f "$MAIN_CONFIG_FILE" ]]; then
  SERVER_CONF_FILE="$(head -n1 "$MAIN_CONFIG_FILE" | tr -d '\r')"
else
  SERVER_CONF_FILE="$SERVER_CONF_DEFAULT"
fi

need_file "$SERVER_CONF_FILE"
need_exec "$MANAGE_SCRIPT"
need_exec "$PYTHON_BIN"

clients_list() {
  grep '^#_Name = ' "$SERVER_CONF_FILE" 2>/dev/null \
    | sed 's/^#_Name = //' \
    | tr -d '\r' \
    | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//' \
    | awk 'NF' \
    | sort -u
}

pick_client() {
  mapfile -t cl < <(clients_list || true)

  if [[ ${#cl[@]} -eq 0 ]]; then
    printf "%s" ""
    return 0
  fi

  {
    printf "\nКлиенты:\n"
    local i=1
    for name in "${cl[@]}"; do
      local cf="—"
      local png="—"
      [[ -f "$AWG_DIR/${name}.conf" ]] && cf="conf"
      [[ -f "$AWG_DIR/${name}.png" ]] && png="png"
      printf "  %2d) %-24s  [%s,%s]\n" "$i" "$name" "$cf" "$png"
      ((i++))
    done
    printf "\n"
    printf "Номер клиента (0-отмена): "
  } >"$TTY_OUT"

  local choice=""
  IFS= read -r choice <"$TTY_IN" || true
  choice="$(sanitize "$choice")"

  if ! [[ "$choice" =~ ^[0-9]+$ ]]; then
    printf "%s" ""
    return 0
  fi
  if [[ "$choice" -eq 0 ]]; then
    printf "%s" ""
    return 0
  fi
  if (( choice < 1 || choice > ${#cl[@]} )); then
    printf "%s" ""
    return 0
  fi

  printf "%s" "$(sanitize "${cl[$((choice-1))]}")"
}

print_qr_ascii_from_conf() {
  local cf="$1"
  "$PYTHON_BIN" - "$cf" <<'PY'
import sys
try:
    import qrcode
except Exception as e:
    sys.stderr.write(f"ERROR: python module qrcode not available: {e}\n")
    sys.exit(1)

p = sys.argv[1]
with open(p, "r", encoding="utf-8") as f:
    data = f.read()

qr = qrcode.QRCode(border=1)
qr.add_data(data)
qr.make(fit=True)
qr.print_ascii(invert=True)
PY
}

show_client() {
  local name
  name="$(sanitize "$1")"
  validate_name "$name" || die "Некорректное имя клиента: $name"

  local cf="$AWG_DIR/${name}.conf"
  local png="$AWG_DIR/${name}.png"

  if [[ ! -f "$cf" ]]; then
    printf "\nФайл клиента не найден: %s\nДелаю regen...\n\n" "$cf" >"$TTY_OUT"
    "$MANAGE_SCRIPT" --conf-dir="$AWG_DIR" --server-conf="$SERVER_CONF_FILE" regen
  fi

  [[ -f "$cf" ]] || die "Нет файла клиента: $cf"

  local addr="" endpoint="" pub="" priv=""
  addr="$(grep -oP '^Address = \K.*' "$cf" 2>/dev/null || true)"
  endpoint="$(grep -oP '^Endpoint = \K.*' "$cf" 2>/dev/null || true)"
  pub="$(grep -oP '^PublicKey = \K.*' "$cf" 2>/dev/null || true)"
  priv="$(grep -oP '^PrivateKey = \K.*' "$cf" 2>/dev/null || true)"

  printf "\n==============================\n" >"$TTY_OUT"
  printf "Клиент: %s\n" "$name" >"$TTY_OUT"
  printf "Address: %s\n" "${addr:-—}" >"$TTY_OUT"
  printf "Endpoint: %s\n" "${endpoint:-—}" >"$TTY_OUT"
  printf "PublicKey: %s\n" "${pub:-—}" >"$TTY_OUT"
  printf "PrivateKey: %s\n" "${priv:-—}" >"$TTY_OUT"
  printf "CONF: %s\n" "$cf" >"$TTY_OUT"
  if [[ -f "$png" ]]; then
    printf "PNG:  %s\n" "$png" >"$TTY_OUT"
  else
    printf "PNG:  — (нет файла)\n" >"$TTY_OUT"
  fi
  printf "==============================\n\n" >"$TTY_OUT"

  printf "QR (в терминале):\n" >"$TTY_OUT"
  print_qr_ascii_from_conf "$cf" >"$TTY_OUT"
  printf "\nCONF (целиком):\n------------------------------\n" >"$TTY_OUT"
  cat "$cf" >"$TTY_OUT"
  printf "\n------------------------------\n\n" >"$TTY_OUT"
}

add_client() {
  local name
  name="$(sanitize "$1")"
  validate_name "$name" || die "Некорректное имя клиента: $name"
  "$MANAGE_SCRIPT" --conf-dir="$AWG_DIR" --server-conf="$SERVER_CONF_FILE" add "$name"
  printf "\nРекомендуется перезапуск:\n  sudo systemctl restart awg-quick@awg0\n\n" >"$TTY_OUT"
  show_client "$name"
}

remove_client() {
  local name
  name="$(sanitize "$1")"
  validate_name "$name" || die "Некорректное имя клиента: $name"
  "$MANAGE_SCRIPT" --conf-dir="$AWG_DIR" --server-conf="$SERVER_CONF_FILE" remove "$name"
  printf "\nРекомендуется перезапуск:\n  sudo systemctl restart awg-quick@awg0\n\n" >"$TTY_OUT"
}

menu() {
  while true; do
    {
      printf "\n===== AWG Панель =====\n"
      printf "1) Список клиентов\n"
      printf "2) Показать клиента (конфиг + QR)\n"
      printf "3) Добавить клиента\n"
      printf "4) Удалить клиента\n"
      printf "5) Regen (перегенерировать conf+png)\n"
      printf "6) Restart сервиса\n"
      printf "0) Выход\n\n"
      printf "Выбор: "
    } >"$TTY_OUT"

    local cmd=""
    IFS= read -r cmd <"$TTY_IN" || true
    cmd="$(sanitize "$cmd")"

    case "${cmd:-}" in
      1)
        printf "\n" >"$TTY_OUT"
        "$MANAGE_SCRIPT" --conf-dir="$AWG_DIR" --server-conf="$SERVER_CONF_FILE" list -v
        ;;
      2)
        local picked=""
        picked="$(pick_client || true)"
        picked="$(sanitize "$picked")"
        [[ -n "$picked" ]] && show_client "$picked"
        ;;
      3)
        printf "\nИмя нового клиента: " >"$TTY_OUT"
        local name=""
        IFS= read -r name <"$TTY_IN" || true
        name="$(sanitize "$name")"
        [[ -n "$name" ]] && add_client "$name"
        ;;
      4)
        local picked=""
        picked="$(pick_client || true)"
        picked="$(sanitize "$picked")"
        [[ -n "$picked" ]] && remove_client "$picked"
        ;;
      5)
        printf "\n" >"$TTY_OUT"
        "$MANAGE_SCRIPT" --conf-dir="$AWG_DIR" --server-conf="$SERVER_CONF_FILE" regen
        ;;
      6)
        printf "\n" >"$TTY_OUT"
        "$MANAGE_SCRIPT" --conf-dir="$AWG_DIR" --server-conf="$SERVER_CONF_FILE" restart
        ;;
      0)
        exit 0
        ;;
      *)
        printf "Не понял. Выбери 0-6.\n" >"$TTY_OUT"
        ;;
    esac
  done
}

case "${1:-}" in
  list)     "$MANAGE_SCRIPT" --conf-dir="$AWG_DIR" --server-conf="$SERVER_CONF_FILE" list -v ;;
  show)     [[ -n "${2:-}" ]] || die "Использование: $0 show <name>"; show_client "$2" ;;
  add)      [[ -n "${2:-}" ]] || die "Использование: $0 add <name>"; add_client "$2" ;;
  remove)   [[ -n "${2:-}" ]] || die "Использование: $0 remove <name>"; remove_client "$2" ;;
  regen)    "$MANAGE_SCRIPT" --conf-dir="$AWG_DIR" --server-conf="$SERVER_CONF_FILE" regen ;;
  restart)  "$MANAGE_SCRIPT" --conf-dir="$AWG_DIR" --server-conf="$SERVER_CONF_FILE" restart ;;
  "" )      menu ;;
  * )       die "Команда: $1 (поддерживаются: list/show/add/remove/regen/restart или без аргументов для меню)" ;;
esac
