#!/usr/bin/env bash
# Terminal UI and prompt helpers for Deploykit.
#
# Precedence for every answer: value already in the environment (answers file,
# exported var) > saved state (S_<VAR>, see state.sh) > built-in default.
# DP_YES=1 accepts defaults without asking (fails if a required value has none).

if [[ -t 1 && -z "${NO_COLOR:-}" && "${TERM:-}" != "dumb" ]]; then
  DP_UI_COLOR=1
  DP_C_B=$'\e[1m'
  DP_C_DIM=$'\e[2m'
  DP_C_OFF=$'\e[0m'
  if [[ "${COLORTERM:-}" =~ ^(truecolor|24bit)$ ]]; then
    # Monochrome Swiss (Vercel / Linear inspired) truecolor palette
    DP_C_RED=$'\e[38;2;239;68;68m'      # coral red #ef4444
    DP_C_GRN=$'\e[38;2;16;185;129m'     # subtle emerald #10b981
    DP_C_YEL=$'\e[38;2;245;158;11m'     # warm amber #f59e0b
    DP_C_CYN=$'\e[38;2;250;250;250m'    # crisp white #fafafa
    DP_C_SKY=$'\e[38;2;212;212;216m'    # light silver #d4d4d8
    DP_C_IND=$'\e[38;2;161;161;170m'    # silver #a1a1aa
    DP_C_SLATE=$'\e[38;2;82;82;91m'     # dark zinc #52525b
    DP_C_WHT=$'\e[38;2;250;250;250m'    # pure white #fafafa
  else
    DP_C_RED=$'\e[38;5;203m'
    DP_C_GRN=$'\e[38;5;78m'
    DP_C_YEL=$'\e[38;5;221m'
    DP_C_CYN=$'\e[97m'
    DP_C_SKY=$'\e[38;5;252m'
    DP_C_IND=$'\e[38;5;248m'
    DP_C_SLATE=$'\e[38;5;240m'
    DP_C_WHT=$'\e[97m'
  fi
else
  DP_UI_COLOR=0
  DP_C_B='' DP_C_DIM='' DP_C_RED='' DP_C_GRN='' DP_C_YEL='' DP_C_CYN=''
  DP_C_SKY='' DP_C_IND='' DP_C_SLATE='' DP_C_WHT='' DP_C_OFF=''
fi

if [[ "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" =~ [Uu][Tt][Ff]-?8 ]]; then
  DP_UI_UTF8=1
  DP_SYM_OK='✔'
  DP_SYM_WARN='▲'
  DP_SYM_ERR='✖'
  DP_SYM_INFO='▸'
  DP_SYM_ASK='◆'
  DP_SYM_DONE='◇'
  DP_SYM_SEC='◈'
  DP_SYM_ARROW='❯'
  DP_SYM_DOT='●'
  DP_SYM_CIR='○'
  DP_RAIL='│'
  DP_TOP='┌'
  DP_BOT='└'
  DP_H='─'
  DP_TL='╭'
  DP_TR='╮'
  DP_BL='╰'
  DP_BR='╯'
else
  DP_UI_UTF8=0
  DP_SYM_OK='*'
  DP_SYM_WARN='!'
  DP_SYM_ERR='x'
  DP_SYM_INFO='>'
  DP_SYM_ASK='?'
  DP_SYM_DONE='+'
  DP_SYM_SEC='*'
  DP_SYM_ARROW='>'
  DP_SYM_DOT='*'
  DP_SYM_CIR='o'
  DP_RAIL='|'
  DP_TOP='+'
  DP_BOT='+'
  DP_H='-'
  DP_TL='+'
  DP_TR='+'
  DP_BL='+'
  DP_BR='+'
fi

_dp_term_cols() {
  local c="${COLUMNS:-}"
  if [[ -z "$c" ]] && command -v tput >/dev/null 2>&1; then
    c="$(tput cols 2>/dev/null || true)"
  fi
  [[ "$c" =~ ^[0-9]+$ ]] && echo "$c" || echo 80
}

_dp_repeat() {
  local ch="$1" n="$2" out="" i
  for (( i = 0; i < n; i++ )); do out+="$ch"; done
  printf '%s' "$out"
}

_dp_strip_ansi() {
  sed -E $'s/\x1b\\[[0-9;]*m//g' <<<"$1"
}

dp_info() {
  printf '%s%s%s  %s%s%s %s\n' "$DP_C_SLATE" "$DP_RAIL" "$DP_C_OFF" "$DP_C_CYN" "$DP_SYM_INFO" "$DP_C_OFF" "$*"
}

dp_ok() {
  printf '%s%s%s  %s%s%s %s\n' "$DP_C_SLATE" "$DP_RAIL" "$DP_C_OFF" "$DP_C_GRN" "$DP_SYM_OK" "$DP_C_OFF" "$*"
}

dp_warn() {
  printf '%s%s%s  %s%s%s %s%s%s\n' "$DP_C_SLATE" "$DP_RAIL" "$DP_C_OFF" "$DP_C_YEL" "$DP_SYM_WARN" "$DP_C_OFF" "$DP_C_YEL" "$*" "$DP_C_OFF" >&2
}

dp_die() {
  printf '%s%s%s  %s%s%s %s%s%s\n' "$DP_C_SLATE" "$DP_BOT" "$DP_C_OFF" "$DP_C_RED" "$DP_SYM_ERR" "$DP_C_OFF" "$DP_C_RED" "$*" "$DP_C_OFF" >&2
  exit 1
}

dp_section() {
  printf '\n%s%s%s  %s%s%s%s\n%s%s%s\n' \
    "$DP_C_SLATE" "$DP_TOP" "$DP_C_OFF" \
    "$DP_C_B" "$DP_C_SKY" "$*" "$DP_C_OFF" \
    "$DP_C_SLATE" "$DP_RAIL" "$DP_C_OFF"
}

dp_section_end() {
  local label="${1:-}"
  if [[ -n "$label" ]]; then
    printf '%s%s%s  %s%s%s %s\n' "$DP_C_SLATE" "$DP_BOT" "$DP_C_OFF" "$DP_C_GRN" "$DP_SYM_OK" "$DP_C_OFF" "$label"
  else
    printf '%s%s%s\n' "$DP_C_SLATE" "$DP_BOT" "$DP_C_OFF"
  fi
}

dp_kv() {
  local key="$1" val="$2" w="${3:-15}"
  printf '%s%s%s  %s%-*s%s %s%s%s\n' \
    "$DP_C_SLATE" "$DP_RAIL" "$DP_C_OFF" \
    "$DP_C_SLATE" "$w" "$key" "$DP_C_OFF" \
    "$DP_C_WHT" "$val" "$DP_C_OFF"
}

dp_badge() {
  local kind="$1" text="$2" col="$DP_C_SLATE"
  case "$kind" in
    ok)   col="$DP_C_GRN" ;;
    warn) col="$DP_C_YEL" ;;
    err)  col="$DP_C_RED" ;;
    info) col="$DP_C_CYN" ;;
  esac
  printf '%s%s %s%s' "$col" "$DP_SYM_DOT" "$text" "$DP_C_OFF"
}

# Rounded callout box: dp_box <ok|warn|err|info> "Title" "line1" ["line2"...]
dp_box() {
  local style="$1" title="$2"; shift 2
  local col="$DP_C_CYN" icon="$DP_SYM_INFO"
  case "$style" in
    ok)   col="$DP_C_GRN"; icon="$DP_SYM_OK" ;;
    warn) col="$DP_C_YEL"; icon="$DP_SYM_WARN" ;;
    err)  col="$DP_C_RED"; icon="$DP_SYM_ERR" ;;
  esac
  local lines=("$@") max_len=0 l plain
  local head=" ${icon} ${title} "
  max_len=${#head}
  for l in "${lines[@]}"; do
    plain="$(_dp_strip_ansi "$l")"
    (( ${#plain} + 4 > max_len )) && max_len=$(( ${#plain} + 4 ))
  done
  local cols; cols="$(_dp_term_cols)"
  (( max_len > cols - 4 )) && max_len=$(( cols - 4 ))
  (( max_len < 36 )) && max_len=36

  local fill=$(( max_len - ${#head} - 1 ))
  (( fill < 2 )) && fill=2
  printf '\n%s%s%s%s%s%s%s%s\n' \
    "$col" "$DP_TL" "$DP_H" "$DP_C_B" "$head" "$DP_C_OFF" \
    "$col" "$(_dp_repeat "$DP_H" "$fill")${DP_TR}${DP_C_OFF}"

  for l in "${lines[@]}"; do
    plain="$(_dp_strip_ansi "$l")"
    local pad=$(( max_len - ${#plain} - 2 ))
    (( pad < 0 )) && pad=0
    printf '%s%s%s  %s%*s%s%s%s\n' \
      "$col" "$DP_RAIL" "$DP_C_OFF" \
      "$l" "$pad" "" \
      "$col" "$DP_RAIL" "$DP_C_OFF"
  done
  printf '%s%s%s%s%s\n' "$col" "$DP_BL" "$(_dp_repeat "$DP_H" "$max_len")" "$DP_BR" "$DP_C_OFF"
}

# Fastfetch-style hero header: dp_hero "Title" "Subtitle" "Key|Val" ...
dp_hero() {
  local title="$1" subtitle="${2:-}"; shift 2 || true
  local kvs=("$@")
  local cols; cols="$(_dp_term_cols)"

  # Compact fallback for narrow terminals or non-TTY.
  if (( DP_UI_COLOR == 0 || cols < 70 )); then
    printf '\n%s%s%s%s' "$DP_C_B" "$DP_C_SKY" "$title" "$DP_C_OFF"
    [[ -n "$subtitle" ]] && printf '  %s%s%s' "$DP_C_SLATE" "$subtitle" "$DP_C_OFF"
    printf '\n'
    local kv
    for kv in "${kvs[@]}"; do
      printf '  %s%-10s%s %s\n' "$DP_C_SLATE" "${kv%%|*}" "$DP_C_OFF" "${kv#*|}"
    done
    return 0
  fi

  local logo=()
  if (( DP_UI_UTF8 )); then
    logo=(
      "${DP_C_CYN}   ╭───────╮   ${DP_C_OFF}"
      "${DP_C_CYN}   │  ${DP_C_SKY}╱╲   ${DP_C_CYN}│   ${DP_C_OFF}"
      "${DP_C_SKY}   │ ╱  ╲  │   ${DP_C_OFF}"
      "${DP_C_IND}   │ ╲  ╱  │   ${DP_C_OFF}"
      "${DP_C_IND}   │  ╲╱   │   ${DP_C_OFF}"
      "${DP_C_IND}   ╰───────╯   ${DP_C_OFF}"
      "               "
    )
  else
    logo=(
      "${DP_C_CYN}   +-------+   ${DP_C_OFF}"
      "${DP_C_CYN}   |  /\\   |   ${DP_C_OFF}"
      "${DP_C_SKY}   | /  \\  |   ${DP_C_OFF}"
      "${DP_C_IND}   | \\  /  |   ${DP_C_OFF}"
      "${DP_C_IND}   |  \\/   |   ${DP_C_OFF}"
      "${DP_C_IND}   +-------+   ${DP_C_OFF}"
      "               "
    )
  fi

  local info=()
  local head="${DP_C_B}${DP_C_WHT}${title}${DP_C_OFF}"
  [[ -n "$subtitle" ]] && head+="  ${DP_C_SLATE}${DP_SYM_DOT}  ${DP_C_SKY}${subtitle}${DP_C_OFF}"
  info+=("$head")
  info+=("${DP_C_SLATE}$(_dp_repeat "$DP_H" 34)${DP_C_OFF}")
  local kv
  for kv in "${kvs[@]}"; do
    info+=("$(printf '%s%-10s%s %s%s%s' "$DP_C_SLATE" "${kv%%|*}" "$DP_C_OFF" "$DP_C_WHT" "${kv#*|}" "$DP_C_OFF")")
  done
  info+=("${DP_C_CYN}${DP_SYM_DOT} ${DP_C_SKY}${DP_SYM_DOT} ${DP_C_IND}${DP_SYM_DOT} ${DP_C_GRN}${DP_SYM_DOT} ${DP_C_YEL}${DP_SYM_DOT} ${DP_C_RED}${DP_SYM_DOT}${DP_C_OFF}")

  local rows=${#logo[@]}
  (( ${#info[@]} > rows )) && rows=${#info[@]}
  printf '\n'
  local i l_part r_part
  for (( i = 0; i < rows; i++ )); do
    l_part="${logo[$i]:-               }"
    r_part="${info[$i]:-}"
    printf '%s%s\n' "$l_part" "$r_part"
  done
}

# Saved value for VAR (from state), empty if none.
dp_saved() { local s="S_$1"; printf '%s' "${!s:-}"; }

_dp_prompt_read() {
  local __var="$1"
  local __prompt="${DP_C_SLATE}${DP_RAIL}${DP_C_OFF}  ${DP_C_CYN}${DP_SYM_ARROW}${DP_C_OFF} "
  local __val=""
  read -r -p "$__prompt" __val || true
  printf -v "$__var" '%s' "$__val"
}

_dp_prompt_secret_read() {
  local __var="$1"
  local __prompt="${DP_C_SLATE}${DP_RAIL}${DP_C_OFF}  ${DP_C_IND}${DP_SYM_ARROW}${DP_C_OFF} "
  local __val=""
  read -r -s -p "$__prompt" __val || true
  printf '\n'
  printf -v "$__var" '%s' "$__val"
}

# dp_ask VAR "Label" [default] [validator-fn]
dp_ask() {
  local var="$1" label="$2" def="${3:-}" check="${4:-}" val saved
  saved="$(dp_saved "$var")"
  [[ -n "$saved" ]] && def="$saved"
  if [[ -n "${!var:-}" ]]; then
    val="${!var}"
  elif [[ "${DP_YES:-0}" == "1" ]]; then
    val="$def"
  else
    while :; do
      if [[ -n "$def" ]]; then
        printf '%s%s%s  %s%s%s  %s[%s]%s\n' \
          "$DP_C_CYN" "$DP_SYM_ASK" "$DP_C_OFF" \
          "$DP_C_B" "$label" "$DP_C_OFF" \
          "$DP_C_SLATE" "$def" "$DP_C_OFF"
      else
        printf '%s%s%s  %s%s%s\n' \
          "$DP_C_CYN" "$DP_SYM_ASK" "$DP_C_OFF" \
          "$DP_C_B" "$label" "$DP_C_OFF"
      fi
      _dp_prompt_read val
      val="${val:-$def}"
      if [[ -n "$check" ]] && ! "$check" "$val"; then
        printf '%s%s%s  %s%s invalid value, try again%s\n' \
          "$DP_C_SLATE" "$DP_RAIL" "$DP_C_OFF" "$DP_C_RED" "$DP_SYM_ERR" "$DP_C_OFF" >&2
        continue
      fi
      break
    done
  fi
  if [[ -n "$check" ]] && ! "$check" "$val"; then
    dp_die "${var}: invalid value '${val}'"
  fi
  printf -v "$var" '%s' "$val"
}

# dp_ask_required VAR "Label" [default] [validator]
dp_ask_required() {
  dp_ask "$@"
  [[ -n "${!1:-}" ]] || dp_die "${1} is required (${2})."
}

dp_gen_secret() { openssl rand -base64 48 | tr -d '/+=\n' | head -c "${1:-32}"; }

# dp_ask_secret VAR "Label" [gen=1] — Enter keeps the saved value, else generates (gen=1) or leaves empty.
dp_ask_secret() {
  local var="$1" label="$2" gen="${3:-0}" val saved
  saved="$(dp_saved "$var")"
  if [[ -n "${!var:-}" ]]; then
    return 0
  fi
  if [[ "${DP_YES:-0}" == "1" ]]; then
    val="$saved"
  else
    local hint="empty = skip"
    [[ "$gen" == "1" ]] && hint="empty = generate"
    [[ -n "$saved" ]] && hint="Enter = keep current"
    printf '%s%s%s  %s%s%s  %s(%s)%s\n' \
      "$DP_C_IND" "$DP_SYM_SEC" "$DP_C_OFF" \
      "$DP_C_B" "$label" "$DP_C_OFF" \
      "$DP_C_SLATE" "$hint" "$DP_C_OFF"
    _dp_prompt_secret_read val
    [[ -z "$val" ]] && val="$saved"
  fi
  if [[ -z "$val" && "$gen" == "1" ]]; then
    val="$(dp_gen_secret)"
    dp_ok "generated ${var} ${DP_C_SLATE}(shown once after apply)${DP_C_OFF}"
    DP_GENERATED+=" ${var}"
  fi
  printf -v "$var" '%s' "$val"
}

# dp_choose VAR "Label" default opt1 opt2 ...
dp_choose() {
  local var="$1" label="$2" def="$3"; shift 3
  local opts=("$@") o saved val
  saved="$(dp_saved "$var")"
  [[ -n "$saved" ]] && def="$saved"
  _dp_in_list() { local x; for x in "${opts[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }

  if [[ -n "${!var:-}" ]]; then
    val="${!var}"
  elif [[ "${DP_YES:-0}" == "1" ]]; then
    val="$def"
  else
    while :; do
      printf '%s%s%s  %s%s%s\n' "$DP_C_CYN" "$DP_SYM_ASK" "$DP_C_OFF" "$DP_C_B" "$label" "$DP_C_OFF"
      printf '%s%s%s  ' "$DP_C_SLATE" "$DP_RAIL" "$DP_C_OFF"
      for o in "${opts[@]}"; do
        if [[ "$o" == "$def" ]]; then
          printf '%s%s %s%s   ' "$DP_C_GRN" "$DP_SYM_DOT" "$o" "$DP_C_OFF"
        else
          printf '%s%s %s%s   ' "$DP_C_SLATE" "$DP_SYM_CIR" "$o" "$DP_C_OFF"
        fi
      done
      printf '\n'
      _dp_prompt_read val
      val="${val:-$def}"
      if _dp_in_list "$val"; then
        break
      fi
      printf '%s%s%s  %s%s choose one of: %s%s\n' \
        "$DP_C_SLATE" "$DP_RAIL" "$DP_C_OFF" "$DP_C_RED" "$DP_SYM_ERR" "${opts[*]}" "$DP_C_OFF" >&2
    done
  fi
  _dp_in_list "$val" || dp_die "${var}: invalid value '${val}'"
  printf -v "$var" '%s' "$val"
}

# dp_yes "Question" [default y|n] [VAR] — VAR (answers) may pre-answer with y/n.
dp_yes() {
  local q="$1" def="${2:-n}" var="${3:-}" ans
  if [[ -n "$var" ]]; then
    dp_ask "$var" "${q} (y/n)" "$def"
    ans="${!var}"
  elif [[ "${DP_YES:-0}" == "1" ]]; then
    ans="$def"
  else
    local hint; [[ $def == y ]] && hint="Y/n" || hint="y/N"
    printf '%s%s%s  %s%s%s  %s[%s]%s\n' \
      "$DP_C_CYN" "$DP_SYM_ASK" "$DP_C_OFF" \
      "$DP_C_B" "$q" "$DP_C_OFF" \
      "$DP_C_SLATE" "$hint" "$DP_C_OFF"
    _dp_prompt_read ans
    ans="${ans:-$def}"
  fi
  [[ "$ans" =~ ^[Yy] ]]
}

# dp_multiselect VAR "Label" "default list" option...  → space-separated selection.
# Accepts: numbers ("1 3"), names, "all", plus custom names not in the list.
dp_multiselect() {
  local var="$1" label="$2" def="$3"; shift 3
  local opts=("$@") i raw out=() tok
  local saved; saved="$(dp_saved "$var")"
  [[ -n "$saved" ]] && def="$saved"
  if [[ -n "${!var:-}" ]]; then
    raw="${!var}"
  elif [[ "${DP_YES:-0}" == "1" ]]; then
    raw="$def"
  else
    printf '%s%s%s  %s%s%s  %s[%s]%s\n' \
      "$DP_C_CYN" "$DP_SYM_ASK" "$DP_C_OFF" \
      "$DP_C_B" "$label" "$DP_C_OFF" \
      "$DP_C_SLATE" "$def" "$DP_C_OFF"
    for i in "${!opts[@]}"; do
      if [[ " ${def} " == *" ${opts[$i]} "* ]]; then
        printf '%s%s%s  %s%d)%s %s%s %s%s\n' "$DP_C_SLATE" "$DP_RAIL" "$DP_C_OFF" "$DP_C_SLATE" "$((i + 1))" "$DP_C_OFF" "$DP_C_GRN" "$DP_SYM_DOT" "${opts[$i]}" "$DP_C_OFF"
      else
        printf '%s%s%s  %s%d)%s %s%s %s%s\n' "$DP_C_SLATE" "$DP_RAIL" "$DP_C_OFF" "$DP_C_SLATE" "$((i + 1))" "$DP_C_OFF" "$DP_C_SLATE" "$DP_SYM_CIR" "${opts[$i]}" "$DP_C_OFF"
      fi
    done
    printf '%s%s%s  %s(numbers or names, space-separated; '\''all'\''; custom names allowed)%s\n' \
      "$DP_C_SLATE" "$DP_RAIL" "$DP_C_OFF" "$DP_C_SLATE" "$DP_C_OFF"
    _dp_prompt_read raw
    raw="${raw:-$def}"
  fi
  raw="${raw//,/ }"
  for tok in $raw; do
    if [[ "$tok" == "all" ]]; then out=("${opts[@]}"); break; fi
    if [[ "$tok" =~ ^[0-9]+$ ]] && (( tok >= 1 && tok <= ${#opts[@]} )); then tok="${opts[$((tok - 1))]}"; fi
    [[ "$tok" =~ ^[a-z][a-z0-9-]{0,19}$ ]] || dp_die "invalid environment name '${tok}' (a-z, 0-9, -)"
    [[ " ${out[*]} " == *" ${tok} "* ]] || out+=("$tok")
  done
  (( ${#out[@]} )) || dp_die "${label}: select at least one"
  printf -v "$var" '%s' "${out[*]}"
}

# Validators
dp_v_host() { [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$1" == *.* ]]; }
dp_v_host_opt() { [[ -z "$1" ]] || dp_v_host "$1"; }
dp_v_port() { [[ "$1" =~ ^[0-9]+$ ]] && (( $1 > 0 && $1 < 65536 )); }
dp_v_slug() { [[ "$1" =~ ^[a-z][a-z0-9-]{1,30}$ ]]; }
dp_v_reldir() { [[ -n "$1" && "$1" != /* && "$1" != *..* ]]; }
dp_v_path() { [[ "$1" == /* || "$1" == "~"* ]]; }
dp_v_email() { [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; }
dp_v_nonempty() { [[ -n "$1" ]]; }

dp_expand_path() {
  local p="$1"
  case "$p" in "~/"*) p="${HOME}/${p#\~/}" ;; "~") p="$HOME" ;; esac
  printf '%s' "$p"
}

# Mask a secret for summaries.
dp_mask() { local v="$1"; (( ${#v} )) && printf '%s…(%d chars)' "${v:0:2}" "${#v}" || printf '<empty>'; }
