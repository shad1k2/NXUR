#!/bin/sh
# Простая реализация пакетного менеджера для NXUR
# Читает packages.list в корне (формат: name:version:url)
# Поддерживает: install, remove, list, update, info

set -eu

REPO_ROOT="$(dirname "$0")/.."
PACKAGES_FILE="$REPO_ROOT/packages.list"

# Папка для локальных установок (по умолчанию ~/.nxur)
: "${NXUR_ROOT:=${HOME}/.nxur}"
BIN_DIR="${NXUR_ROOT}/bin"
PKG_DIR="${NXUR_ROOT}/pkgs"
TMP_DIR="${NXUR_ROOT}/tmp"

mkdir -p "$BIN_DIR" "$PKG_DIR" "$TMP_DIR"

warn() { printf "WARN: %s\n" "$*" >&2; }
err() { printf "ERROR: %s\n" "$*" >&2; exit 1; }
info() { printf "%s\n" "$*"; }

# Проверяем наличие curl/wget
DL_TOOL=""
if command -v curl >/dev/null 2>&1; then
  DL_TOOL="curl"
elif command -v wget >/dev/null 2>&1; then
  DL_TOOL="wget"
else
  err "Требуется curl или wget для загрузки пакетов"
fi

# Прочитать строку пакета по имени
# Возвращает строку name:version:url
get_pkg_line() {
  pkgname="$1"
  if [ ! -f "$PACKAGES_FILE" ]; then
    err "Файл packages.list не найден в $PACKAGES_FILE"
  fi
  # игнорируем пустые строки и комментарии
  awk -F":" -v name="$pkgname" 'BEGIN{IGNORECASE=1} $0~"^[[:space:]]*$"{next} $0~"^[[:space:]]*#"{next} $1==name{print $0; exit}' "$PACKAGES_FILE"
}

# Парсинг имени:version:url
parse_pkg_line() {
  IFS=':' read -r name version url <<EOF
$1
EOF
  printf "%s\n" "$name"  # name
  printf "%s\n" "$version" # version
  printf "%s\n" "$url" # url
}

# Скачать в временный файл, вывести путь
download_to_tmp() {
  url="$1"
  out="$TMP_DIR/$(basename "$url")"
  # если URL заканчивается ? ... убрать? оставим basename
  if [ "$DL_TOOL" = "curl" ]; then
    curl -fsSL -o "$out" "$url" || return 1
  else
    wget -q -O "$out" "$url" || return 1
  fi
  printf "%s" "$out"
}

# Установить пакет
install_pkg() {
  pkgname="$1"
  line="$(get_pkg_line "$pkgname")" || {
    err "Пакет '$pkgname' не найден в $PACKAGES_FILE"
  }
  read -r name version url <<EOF
$(parse_pkg_line "$line")
EOF
  info "Установка $name (версия ${version}) из $url"

  tmpf="$(download_to_tmp "$url")" || err "Не удалось скачать $url"

  # создаём целевую папку для версии
  target_dir="$PKG_DIR/${name}-${version}"
  rm -rf "$target_dir"
  mkdir -p "$target_dir/bin"

  # Если скачанный файл — исполняемый скрипт, помещаем в bin
  # Если это архив tar.gz, распакуем в target_dir
  mimetype="$(file -b --mime-type "$tmpf" 2>/dev/null || true)"
  case "$mimetype" in
    application/x-gzip|application/gzip|application/x-tar)
      tar -xzf "$tmpf" -C "$target_dir" || err "Ошибка распаковки архива"
      ;;
    application/zip)
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "$tmpf" -d "$target_dir" || err "Ошибка распаковки zip"
      else
        err "Требуется unzip для распаковки zip-архива"
      fi
      ;;
    *)
      # предполагаем одиночный исполняемый файл — переместим в bin
      mv "$tmpf" "$target_dir/bin/$name" || err "Не удалось поместить файл"
      chmod +x "$target_dir/bin/$name"
      ;;
  esac

  # Обновим символьную ссылку в BIN_DIR
  ln -sf "$target_dir/bin/$name" "$BIN_DIR/$name" || {
    warn "Не удалось создать ссылку в $BIN_DIR. Убедитесь, что каталог доступен"
  }

  info "Установлено в $target_dir"
  info "Используйте: $BIN_DIR/$name (или добавьте $BIN_DIR в PATH)"
}

# Удалить пакет (все версии)
remove_pkg() {
  pkgname="$1"
  found=0
  for d in "$PKG_DIR"/${pkgname}-*; do
    [ -e "$d" ] || continue
    found=1
    rm -rf "$d"
    info "Удалена версия: $d"
  done
  # убрать ссылку
  if [ -L "$BIN_DIR/$pkgname" ]; then
    rm -f "$BIN_DIR/$pkgname"
    info "Символическая ссылка $BIN_DIR/$pkgname удалена"
  fi
  [ "$found" -eq 1 ] || warn "Пакет $pkgname не найден в $PKG_DIR"
}

list_pkgs() {
  if [ ! -d "$PKG_DIR" ]; then
    info "Пакеты не установлены"
    return
  fi
  for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    base="$(basename "$d")"
    printf "%s\n" "$base"
  done
}

info_pkg() {
  pkgname="$1"
  line="$(get_pkg_line "$pkgname")" || {
    err "Пакет '$pkgname' не найден в $PACKAGES_FILE"
  }
  read -r name version url <<EOF
$(parse_pkg_line "$line")
EOF
  info "Имя: $name"
  info "Версия: $version"
  info "URL: $url"
  if [ -L "$BIN_DIR/$name" ]; then
    info "Установлен: да -> $(readlink -f "$BIN_DIR/$name")"
  else
    info "Установлен: нет"
  fi
}

update_pkg() {
  pkgname="$1"
  # Если в PKG_DIR уже есть версии, удалим старую и установим заново
  # простая политика — просто установить указанную версию
  install_pkg "$pkgname"
}

show_help() {
  cat <<EOF
Использование: $(basename "$0") <команда> [пакет]
Команды:
  install <name>   — скачать и установить пакет из packages.list
  remove <name>    — удалить пакет (все версии)
  list             — показать установленные пакеты (по папкам в $PKG_DIR)
  available        — показать пакеты, перечисленные в packages.list
  info <name>      — показать информацию о пакете
  update <name>    — обновить (переустановить) пакет
  help             — показать это сообщение

Примечания:
  - Файл packages.list должен находиться в корне репозитория и иметь формат:
      name:version:url
    Например:
      hello:1.0:https://raw.githubusercontent.com/shad1k2/NXUR/main/scripts/hello.sh
  - По умолчанию пакеты устанавливаются в $NXUR_ROOT (можно переопределить переменной окружения NXUR_ROOT).
  - Добавьте "$BIN_DIR" в PATH, чтобы запускать установленные пакеты напрямую.
EOF
}

list_available() {
  if [ ! -f "$PACKAGES_FILE" ]; then
    err "Файл packages.list не найден"
  fi
  awk -F":" 'BEGIN{printf "Доступные пакеты:\n"} $0~"^[[:space:]]*$"{next} $0~"^[[:space:]]*#"{next} {printf "  %s (версия %s) -> %s\n", $1, $2, $3}' "$PACKAGES_FILE"
}

# main
if [ $# -lt 1 ]; then
  show_help
  exit 0
fi

action="$1"; shift || true
case "$action" in
  install)
    [ $# -ge 1 ] || err "Требуется имя пакета"
    install_pkg "$1"
    ;;
  remove)
    [ $# -ge 1 ] || err "Требуется имя пакета"
    remove_pkg "$1"
    ;;
  list)
    list_pkgs
    ;;
  available)
    list_available
    ;;
  info)
    [ $# -ge 1 ] || err "Требуется имя пакета"
    info_pkg "$1"
    ;;
  update)
    [ $# -ge 1 ] || err "Требуется имя пакета"
    update_pkg "$1"
    ;;
  help|--help|-h)
    show_help
    ;;
  *)
    err "Неизвестная команда: $action"
    ;;
esac
