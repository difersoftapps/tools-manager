#!/bin/bash
# =====================================================================
#  Difersoft Manager - instala e atualiza as tools da Difersoft
#  Coloque este arquivo em /roms/tools/ (precisa de Wi-Fi para baixar)
# =====================================================================
MANAGER_VER="1.0.0"
CATALOG_REPO="SEU_USUARIO/difersoft-manager"   # <- troque pelo seu repo instalador
CATALOG_URL="https://raw.githubusercontent.com/$CATALOG_REPO/main/catalog.json"

BASE="/roms/tools/Difersoft"
STATE_DIR="$BASE/.manager"
INSTALLED="$STATE_DIR/installed.txt"   # formato: id|versao
CACHE="$STATE_DIR/catalog.json"
TTY="/dev/tty1"
TITLE="Difersoft Manager v$MANAGER_VER"

mkdir -p "$STATE_DIR"
touch "$INSTALLED"

# ---------- terminal e controles do aparelho ----------
export TERM=linux
sudo chmod 666 "$TTY" 2>/dev/null
printf "\033c" > "$TTY"
if [ -x /opt/inttools/gptokeyb ]; then
  /opt/inttools/gptokeyb -1 "Difersoft Manager.sh" -c "/opt/inttools/keys.gptk" >/dev/null 2>&1 &
fi
cleanup() {
  pkill -f gptokeyb 2>/dev/null
  printf "\033c" > "$TTY"
}
trap cleanup EXIT

# ---------- helpers de interface ----------
msg()  { dialog --backtitle "$TITLE" --title "$1" --msgbox "$2" 12 60 > "$TTY"; }
info() { dialog --backtitle "$TITLE" --infobox "$1" 5 60 > "$TTY"; }
ask()  { dialog --backtitle "$TITLE" --title "$1" --yesno "$2" 8 60 > "$TTY"; }

# ---------- dados ----------
declare -A NOME DESC REPO RV
IDS=()

local_ver()  { grep "^$1|" "$INSTALLED" | head -n1 | cut -d'|' -f2; }
remote_ver() {
  curl -fsL --max-time 6 "https://raw.githubusercontent.com/$1/main/version.txt" 2>/dev/null \
    | head -c 32 | tr -d ' \r\n'
}

# Converte o catalog.json em linhas: id<TAB>nome<TAB>descricao<TAB>repo
catalog_lines() {
  if command -v jq >/dev/null 2>&1; then
    jq -r '.tools[] | [.id, .nome, .descricao, .repo] | join("\t")' "$CACHE" 2>/dev/null
  elif command -v python3 >/dev/null 2>&1; then
    python3 -I -c 'import json,sys
for t in json.load(open(sys.argv[1]))["tools"]:
    print("\t".join([t["id"],t["nome"],t["descricao"],t["repo"]]))' "$CACHE" 2>/dev/null
  fi
}

json_ok() {
  if command -v jq >/dev/null 2>&1; then jq -e '.tools' "$1" >/dev/null 2>&1
  elif command -v python3 >/dev/null 2>&1; then python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))["tools"]' "$1" 2>/dev/null
  else return 1; fi
}

load_catalog() {
  info "Buscando catálogo..."
  if curl -fsL --max-time 8 "$CATALOG_URL" -o "$CACHE.tmp" && [ -s "$CACHE.tmp" ] && json_ok "$CACHE.tmp"; then
    mv "$CACHE.tmp" "$CACHE"
  else
    rm -f "$CACHE.tmp"
  fi
  [ -s "$CACHE" ]
}

scan() {
  IDS=(); NOME=(); DESC=(); REPO=(); RV=()
  info "Verificando versões..."
  local id nome desc repo
  while IFS=$'\t' read -r id nome desc repo; do
    [[ -z "$id" ]] && continue
    [[ "$id" =~ ^[A-Za-z0-9_-]+$ ]] || continue
    IDS+=("$id"); NOME[$id]="$nome"; DESC[$id]="$desc"; REPO[$id]="$repo"
    RV[$id]="$(remote_ver "$repo")"
  done < <(catalog_lines)
}

# ---------- instalar / atualizar uma tool ----------
install_tool() {
  local id="$1" tmp url expected actual
  url="https://github.com/${REPO[$id]}/releases/latest/download"
  tmp="$(mktemp -d)"
  info "Baixando ${NOME[$id]}..."
  if ! curl -fsL --max-time 180 "$url/$id.tar.gz" -o "$tmp/$id.tar.gz"; then
    rm -rf "$tmp"; return 1
  fi
  # verificação OBRIGATÓRIA: a release precisa ter id.tar.gz.sha256
  if ! curl -fsL --max-time 15 "$url/$id.tar.gz.sha256" -o "$tmp/sha" 2>/dev/null; then
    rm -rf "$tmp"; return 2
  fi
  expected="$(awk '{print tolower($1); exit}' "$tmp/sha" | tr -d '\r')"
  actual="$(sha256sum "$tmp/$id.tar.gz" | awk '{print $1}')"
  if [[ ! "$expected" =~ ^[0-9a-f]{64}$ ]] || [ "$expected" != "$actual" ]; then
    rm -rf "$tmp"; return 3
  fi
  tar -tzf "$tmp/$id.tar.gz" >/dev/null 2>&1 || { rm -rf "$tmp"; return 1; }
  info "Instalando ${NOME[$id]}..."
  mkdir -p "$BASE/$id"
  tar -xzf "$tmp/$id.tar.gz" -C "$BASE/$id" || { rm -rf "$tmp"; return 1; }
  find "$BASE/$id" -type f -name "*.sh" -exec chmod +x {} \;
  sed -i "/^$id|/d" "$INSTALLED"
  echo "$id|${RV[$id]}" >> "$INSTALLED"
  rm -rf "$tmp"
  return 0
}

run_install() {
  local ok=0 fail=0 id rc notes=""
  for id in "$@"; do
    if [ -z "${RV[$id]}" ]; then fail=$((fail+1)); continue; fi
    install_tool "$id"; rc=$?
    case $rc in
      0) ok=$((ok+1)) ;;
      2) fail=$((fail+1)); notes="$notes\n- $id: falta o arquivo .sha256 na release" ;;
      3) fail=$((fail+1)); notes="$notes\n- $id: hash NÃO confere (arquivo recusado)" ;;
      *) fail=$((fail+1)); notes="$notes\n- $id: falha no download/instalação" ;;
    esac
  done
  msg "Concluído" "Instaladas/atualizadas: $ok\nFalhas: $fail$notes\n\nSe aparecerem tools novas, reinicie o EmulationStation (Start > Sair > Reiniciar)."
}

# ---------- telas ----------
choose_tools() {
  local args=() id lv label st sel
  for id in "${IDS[@]}"; do
    [ -z "${RV[$id]}" ] && continue
    lv="$(local_ver "$id")"
    if [ -z "$lv" ]; then
      st="off"; label="[NOVO] ${NOME[$id]} - ${DESC[$id]}"
    elif [ "$lv" != "${RV[$id]}" ]; then
      st="on";  label="[ATUALIZAR $lv > ${RV[$id]}] ${NOME[$id]}"
    else
      st="off"; label="[OK $lv] ${NOME[$id]}"
    fi
    args+=("$id" "$label" "$st")
  done
  if [ ${#args[@]} -eq 0 ]; then
    msg "Sem conexão" "Não foi possível consultar as versões.\nVerifique o Wi-Fi e tente de novo."
    return
  fi
  sel=$(dialog --backtitle "$TITLE" --title "Tools Difersoft" --separate-output --no-tags \
        --checklist "Marque com A/espaço e confirme em OK:" 18 72 9 "${args[@]}" 2>&1 >"$TTY") || return
  [ -z "$sel" ] && return
  run_install $sel
}

install_all() {
  local list=() id
  for id in "${IDS[@]}"; do
    [ -n "${RV[$id]}" ] && list+=("$id")
  done
  if [ ${#list[@]} -eq 0 ]; then
    msg "Sem conexão" "Não foi possível consultar as versões.\nVerifique o Wi-Fi e tente de novo."
    return
  fi
  run_install "${list[@]}"
}

remove_tool() {
  local args=() id lv sel
  while IFS='|' read -r id lv; do
    [ -z "$id" ] && continue
    args+=("$id" "${NOME[$id]:-$id} ($lv)")
  done < "$INSTALLED"
  if [ ${#args[@]} -eq 0 ]; then msg "Remover" "Nenhuma tool instalada."; return; fi
  sel=$(dialog --backtitle "$TITLE" --title "Remover tool" --no-tags \
        --menu "Qual tool remover?" 15 60 8 "${args[@]}" 2>&1 >"$TTY") || return
  [[ "$sel" =~ ^[A-Za-z0-9_-]+$ ]] || return
  if ask "Confirmar" "Remover '$sel' e seus arquivos?"; then
    rm -rf "${BASE:?}/$sel"
    sed -i "/^$sel|/d" "$INSTALLED"
    msg "Remover" "Removida. Reinicie o EmulationStation para atualizar a lista."
  fi
}

# ---------- início ----------
if ! command -v jq >/dev/null 2>&1 && ! command -v python3 >/dev/null 2>&1; then
  msg "Falta dependência" "Instale o jq (ou python3) para ler o catalog.json."
  exit 1
fi
if ! load_catalog; then
  msg "Sem catálogo" "Não foi possível baixar o catálogo e não há cópia local.\nLigue o Wi-Fi e tente novamente."
  exit 1
fi
scan

while true; do
  choice=$(dialog --backtitle "$TITLE" --title "Menu" --no-tags \
    --menu "O que deseja fazer?" 15 60 5 \
    1 "Escolher tools (instalar/atualizar)" \
    2 "Instalar/atualizar TODAS" \
    3 "Remover uma tool" \
    4 "Sair" 2>&1 >"$TTY") || break
  case "$choice" in
    1) choose_tools; scan ;;
    2) install_all;  scan ;;
    3) remove_tool ;;
    4) break ;;
  esac
done
exit 0
