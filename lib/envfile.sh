#!/usr/bin/env bash
# KEY=VALUE file helpers (.env, state, secrets). Values are read back exactly as
# written; quoting rules are in _dp_quote.

dp_env_value() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 0
  awk -v k="$key" '
    index($0, k "=") == 1 {
      sub(/^[^=]*=/, "")
      if ($0 ~ /^'"'"'.*'"'"'$/) { print substr($0, 2, length($0) - 2); exit }
      if ($0 ~ /^".*"$/) {
        s = substr($0, 2, length($0) - 2); out = ""
        for (i = 1; i <= length(s); i++) { c = substr(s, i, 1); if (c == "\\" && i < length(s)) { i++; c = substr(s, i, 1) } out = out c }
        print out; exit
      }
      sub(/[ \t]+#.*$/, ""); sub(/[ \t]+$/, "")   # unquoted: drop inline comment
      print; exit
    }' "$file"
}

dp_env_has() { [[ -f "$1" ]] && grep -q "^$2=" "$1"; }

# Plain when safe; single quotes (literal for phpdotenv and compose) when the value
# has spaces/#/$/quotes; double quotes with escapes only if it contains a single quote.
_dp_quote() {
  local v="$1"
  if [[ ! "$v" =~ [[:space:]\#\"\'\$\`\\] ]]; then
    printf '%s' "$v"
  elif [[ "$v" != *"'"* ]]; then
    printf "'%s'" "$v"
  else
    v="${v//\\/\\\\}"; v="${v//\"/\\\"}"
    printf '"%s"' "$v"
  fi
}

# Replace KEY=… in place (or append). Keeps inode, permissions and unknown keys.
dp_env_set() {
  local file="$1" key="$2" value tmp
  value="$(_dp_quote "$3")"
  [[ -f "$file" ]] || { install -m 600 /dev/null "$file"; }
  tmp="$(mktemp)"
  KEY="$key" VALUE="$value" awk '
    BEGIN { k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; done = 0 }
    index($0, k "=") == 1 { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" >"$tmp"
  cat "$tmp" >"$file"
  rm -f "$tmp"
}

# Set only when the value differs; report the change (never the value when secret=1).
dp_env_sync() {
  local file="$1" key="$2" want="$3" secret="${4:-0}" have
  have="$(dp_env_value "$file" "$key")"
  if [[ "$have" != "$want" ]] || ! dp_env_has "$file" "$key"; then
    dp_env_set "$file" "$key" "$want"
    if [[ "$secret" == "1" ]]; then
      echo "    ${key}: updated"
    else
      echo "    ${key}: ${have:-<unset>} → ${want}"
    fi
  fi
}

# Load KEY=VALUE pairs into variables with a prefix (no command execution).
dp_env_load_prefixed() {
  local file="$1" prefix="$2" line key val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]] || continue
    key="${BASH_REMATCH[1]}"
    val="$(dp_env_value "$file" "$key")"
    printf -v "${prefix}${key}" '%s' "$val"
  done <"$file"
}
