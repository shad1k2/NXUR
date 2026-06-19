#!/bin/nsh
# Упрощённый пакетный менеджер для NuttX
# Предназначен для запуска прямо на устройстве NuttX.
# Требования (на устройстве): wget, basic shell, chmod, mv, rm, mkdir
# Формат файла packages.list (рядок на пакет): name:version:url
# Поддерживается: install, remove, list, available, info, help

set -eu

REPO_ROOT="$(dirname "$0")/.."
PACKAGES_FILE="$REPO_ROOT/packages.list"

: "${NXUR_ROOT:=${HOME:-/root}/.nxur}"
BIN_DIR="${NXUR_ROOT}/bin"
PKG_DIR="${NXUR_ROOT}/pkgs"
TMP_DIR="${NXUR_ROOT}/tmp"

# Создаём каталоги (попытка с -p, если не поддерживается — без)
if mkdir -p "$BIN_DIR" "$PKG_DIR" "$TMP_DIR" 2>/dev/null; then
  :
else
  mkdir "$BIN_DIR" 2>/dev/null || true
  mkdir "$PKG_DIR" 2>/dev/null || true
  mkdir "$TMP_DIR" 2>/dev/null || true
fi

warn() { printf "WARN: %s\n" "$*" >&2; }
err() { printf "ERROR: %s\n" "$*" >&2; exit 1; }
info() { printf "%s\n" "$*"; }

# Проверка wget
if ! command -v wget >/dev/null 2>&1; then
  err "Требуется wget на целевой системе NuttX"
fi

# Читаем строку пакета по имени (без awk)
get_pkg_line() {
  pkgname="$1"
  [ -f "$PACKAGES_FILE" ] || err "Файл packages.list не найден: $PACKAGES_FILE"
  while IFS= read -r line || [ -n "$line" ]; do
    # trim leading/trailing spaces
    l="$line"
    case "$l" in
      ""|#*) continue;;
    esac
    # split by first two ':'
    name="${l%%:*}"
    rest="${l#*:}"
    ver="${rest%%:*}"
    url="${rest#*:}"
    if [ "$name" = "$pkgname" ]; then
      printf "%s:%s:%s" "$name" "$ver" "$url"
      return 0
    fi
  done < "$PACKAGES_FILE"
  return 1
}

install_pkg() {
  pkgname="$1"
  line="$(get_pkg_line "$pkgname")" || err "Пакет '$pkgname' не найден в $PACKAGES_FILE"
  IFS=':' read -r name version url <<EOF
$line
EOF
  info "Установка $name (версия $version) из $url"

  tmpf="$TMP_DIR/$(basename "$url")"
  # wget: -q --no-check-certificate may be useful on some builds
  if ! wget -q -O "$tmpf" "$url"; then
    err "Не удалось скачать $url"
  fi

  target_dir="$PKG_DIR/${name}-${version}"
  # удалим старую и создадим
  rm -rf "$target_dir" || true
  if mkdir -p "$target_dir/bin" 2>/dev/null; then :; else mkdir "$target_dir" 2>/dev/null || true; mkdir "$target_dir/bin" 2>/dev/null || true; fi

  # Определяем по расширению — если .sh или без расширения, считаем одиночным исполняемым
  case "$tmpf" in
    *.tar.gz|*.tgz)
      if command -v tar >/dev/null 2>&1; then
        tar -xzf "$tmpf" -C "$target_dir" || err "Ошибка распаковки tar.gz"
      else
        err "Архив tar.gz — tar отсутствует на системе. Используйте архивацию на хосте."
      fi
      ;;
    *.zip)
      if command -v unzip >/dev/null 2>&1; then
        unzip -q "$tmpf" -d "$target_dir" || err "Ошибка распаковки zip"
      else
        err "Архив zip — unzip отсутствует на системе. Используйте одиночные файлы."
      fi
      ;;
    *)
      # считаем исполняемым файлом
      mv "$tmpf" "$target_dir/bin/$name" || err "Не удалось переместить файл"
      chmod +x "$target_dir/bin/$name" || true
      ;;
  esac

  # Установим исполняемый в BIN_DIR — копируем файл (в NuttX может не быть симв. ссылок)
  if [ -x "$target_dir/bin/$name" ]; then
    cp "$target_dir/bin/$name" "$BIN_DIR/$name" 2>/dev/null || mv "$target_dir/bin/$name" "$BIN_DIR/$name" || warn "Не удалось поместить исполняемый в $BIN_DIR"
    chmod +x "$BIN_DIR/$name" 2>/dev/null || true
  else
    # Если в пакете нет bin/<name>, попробуем найти исполняемый в распакованной папке
    if [ -f "$target_dir/$name" ]; then
      cp "$target_dir/$name" "$BIN_DIR/$name" 2>/dev/null || mv "$target_dir/$name" "$BIN_DIR/$name" || warn "Не удалось поместить исполняемый в $BIN_DIR"
      chmod +x "$BIN_DIR/$name" 2>/dev/null || true
    fi
  fi

  info "Установлено: $target_dir"
  info "Путь к исполняемому: $BIN_DIR/$name"
}

remove_pkg() {
  pkgname="$1"
  found=0
  for d in "$PKG_DIR"/${pkgname}-*; do
    [ -e "$d" ] || continue
    found=1
    rm -rf "$d" || true
    info "Удалена версия: $d"
  done
  # удалить исполняемый в BIN_DIR
  if [ -f "$BIN_DIR/$pkgname" ]; then
    rm -f "$BIN_DIR/$pkgname" || true
    info "Исполняемый $BIN_DIR/$pkgname удалён"
  fi
  [ "$found" -eq 1 ] || warn "Пакет $pkgname не найден"
}

list_pkgs() {
  [ -d "$PKG_DIR" ] || { info "Пакеты не установлены"; return; }
  for d in "$PKG_DIR"/*; do
    [ -d "$d" ] || continue
    printf "%s\n" "$(basename "$d")"
  done
}

info_pkg() {
  pkgname="$1"
  line="$(get_pkg_line "$pkgname")" || err "Пакет '$pkgname' не найден в $PACKAGES_FILE"
  IFS=':' read -r name version url <<EOF
$line
EOF
  info "Имя: $name"
  info "Версия: $version"
  info "URL: $url"
  if [ -f "$BIN_DIR/$name" ]; then
    info "Установлен: да, путь: $BIN_DIR/$name"
  else
    info "Установлен: нет"
  fi
}

list_available() {
  [ -f "$PACKAGES_FILE" ] || err "Файл packages.list не найден"
  info "Доступные пакеты:" 
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ""|#*) continue;;
    esac
    name="${line%%:*}"
    rest="${line#*:}"
    ver="${rest%%:*}"
    url="${rest#*:}"
    printf "  %s (версия %s) -> %s\n" "$name" "$ver" "$url"
  done < "$PACKAGES_FILE"
}

show_help() {
  cat <<EOF
Использование: $(basename "$0") <команда> [пакет]
Команды:
  install <name>   — скачать и установить пакет из packages.list
  remove <name>    — удалить пакет (все версии)
  list             — показать установленные пакеты
  available        — показать пакеты из packages.list
  info <name>      — показать информацию о пакете
  help             — показать это сообщение

Примечание: скрипт ориентирован на работу прямо на NuttX, где доступен wget.
EOF
}

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
  help|--help|-h)
    show_help
    ;;
  *)
    err "Неизвестная команда: $action"
    ;;
esac
