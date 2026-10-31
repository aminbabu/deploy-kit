#!/usr/bin/env bash
# Prompt helpers for the deploy wizard.
#
# Precedence for every answer: value already in the environment (answers file,
# exported var) > saved state (S_<VAR>, see state.sh) > built-in default.
# DP_YES=1 accepts defaults without asking (fails if a required value has none).

if [[ -t 1 ]]; then
  DP_C_B=$'\e[1m' DP_C_DIM=$'\e[2m' DP_C_RED=$'\e[31m' DP_C_GRN=$'\e[32m' DP_C_YEL=$'\e[33m' DP_C_CYN=$'\e[36m' DP_C_OFF=$'\e[0m'
else
  DP_C_B='' DP_C_DIM='' DP_C_RED='' DP_C_GRN='' DP_C_YEL='' DP_C_CYN='' DP_C_OFF=''
fi

dp_info() { printf '%s==>%s %s\n' "$DP_C_CYN" "$DP_C_OFF" "$*"; }
dp_ok() { printf '%s ok%s %s\n' "$DP_C_GRN" "$DP_C_OFF" "$*"; }
dp_warn() { printf '%sWARN%s %s\n' "$DP_C_YEL" "$DP_C_OFF" "$*" >&2; }
dp_die() { printf '%sERROR%s %s\n' "$DP_C_RED" "$DP_C_OFF" "$*" >&2; exit 1; }
dp_section() { printf '\n%s=== %s ===%s\n' "$DP_C_B" "$*" "$DP_C_OFF"; }

# Saved value for VAR (from state), empty if none.
dp_saved() { local s="S_$1"; printf '%s' "${!s:-}"; }

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
        read -r -p "${label} [${def}]: " val || true
        val="${val:-$def}"
      else
        read -r -p "${label}: " val || true
      fi
      if [[ -n "$check" ]] && ! "$check" "$val"; then
        echo "  invalid value, try again" >&2
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
    local hint="empty=skip"
    [[ "$gen" == "1" ]] && hint="empty=generate"
    [[ -n "$saved" ]] && hint="Enter=keep current"
    read -r -s -p "${label} (${hint}): " val || true
    echo
    [[ -z "$val" ]] && val="$saved"
  fi
  if [[ -z "$val" && "$gen" == "1" ]]; then
    val="$(dp_gen_secret)"
    echo "  → generated ${var} (shown once after apply)"
    DP_GENERATED+=" ${var}"
  fi
  printf -v "$var" '%s' "$val"
}

# dp_choose VAR "Label" default opt1 opt2 ...
dp_choose() {
  local var="$1" label="$2" def="$3"; shift 3
  local opts=("$@") o
  _dp_in_list() { local x; for x in "${opts[@]}"; do [[ "$x" == "$1" ]] && return 0; done; return 1; }
  dp_ask "$var" "${label} (${opts[*]// /|})" "$def" _dp_in_list
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
    read -r -p "${q} [$( [[ $def == y ]] && echo Y/n || echo y/N )]: " ans || true
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
    echo "${label}:"
    for i in "${!opts[@]}"; do echo "  $((i + 1))) ${opts[$i]}"; done
    echo "  (numbers or names, space-separated; 'all'; custom names allowed)"
    read -r -p "Select [${def}]: " raw || true
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
