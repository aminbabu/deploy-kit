#!/usr/bin/env bash
# Standalone bootstrap — run on a fresh server:
#   bash <(curl -fsSL https://raw.githubusercontent.com/aminbabu/deploy-kit/main/install.sh)
#   (or, from a checkout) bash deploy/install.sh
#
# It optionally clones the repository (asking URL, target path, branch, and can create
# a read-only deploy key), then runs <repo>/deploy/setup.sh with the same arguments.
set -euo pipefail

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR\033[0m %s\n' "$*" >&2; exit 1; }
ask() { # var label default
  local v; read -r -p "$2${3:+ [$3]}: " v || true
  printf -v "$1" '%s' "${v:-$3}"
}
yes_no() { local a; read -r -p "$1 [${2:-y}]: " a || true; [[ "${a:-${2:-y}}" =~ ^[Yy] ]]; }

(( BASH_VERSINFO[0] >= 4 )) || die "bash >= 4 required"
# git + ssh-keygen with whichever package manager this distro has (setup.sh asks the OS family later).
for c in git ssh-keygen; do
  command -v "$c" >/dev/null 2>&1 && continue
  if command -v apt-get >/dev/null 2>&1; then sudo apt-get update -qq && sudo apt-get install -y -qq git openssh-client
  elif command -v dnf >/dev/null 2>&1; then sudo dnf install -y -q git openssh-clients
  elif command -v yum >/dev/null 2>&1; then sudo yum install -y -q git openssh-clients
  elif command -v zypper >/dev/null 2>&1; then sudo zypper --non-interactive --quiet install git openssh-clients
  elif command -v pacman >/dev/null 2>&1; then sudo pacman -S --needed --noconfirm git openssh
  else die "please install ${c}"; fi
done

REPO_PATH=""
if yes_no "Clone the application repository now?" y; then
  ask REPO_URL "Git repository URL (SSH or HTTPS)" ""
  [[ -n "$REPO_URL" ]] || die "repository URL required"
  name="$(basename "${REPO_URL%.git}")"
  ask REPO_PATH "Clone into" "${HOME}/${name}/repo"
  REPO_PATH="${REPO_PATH/#\~/$HOME}"
  ask BRANCH "Branch to check out" "main"

  ssh_cmd=""
  if [[ "$REPO_URL" =~ ^(git@|ssh://) ]]; then
    host="$(sed -E 's#^(ssh://)?([^@]+@)?([^:/]+).*#\3#' <<<"$REPO_URL")"
    if ! GIT_SSH_COMMAND="ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new" git ls-remote "$REPO_URL" >/dev/null 2>&1; then
      say "No SSH access to ${REPO_URL} yet."
      if yes_no "Create a dedicated read-only deploy key for this repository?" y; then
        key="${HOME}/.ssh/${name}_deploy_ed25519"
        mkdir -p "${HOME}/.ssh" && chmod 700 "${HOME}/.ssh"
        [[ -f "$key" ]] || ssh-keygen -q -t ed25519 -N "" -C "${name}-deploy@$(hostname)" -f "$key"
        echo; echo "Add this public key as a read-only Deploy key on ${host} (repo Settings → Deploy keys):"; echo
        cat "${key}.pub"; echo
        read -r -p "Press Enter once the key is added… " _ || true
        ssh_cmd="ssh -i ${key} -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
      fi
    fi
  fi

  if [[ -d "${REPO_PATH}/.git" ]]; then
    say "Existing checkout at ${REPO_PATH}; fetching ${BRANCH}"
    GIT_SSH_COMMAND="${ssh_cmd:-ssh}" git -C "$REPO_PATH" fetch --prune origin "$BRANCH"
    git -C "$REPO_PATH" checkout -f -B "$BRANCH" "origin/${BRANCH}"
  else
    [[ ! -e "$REPO_PATH" || -z "$(ls -A "$REPO_PATH" 2>/dev/null)" ]] || die "${REPO_PATH} exists and is not an empty directory or git checkout"
    mkdir -p "$(dirname "$REPO_PATH")"
    say "Cloning ${REPO_URL} (${BRANCH}) → ${REPO_PATH}"
    GIT_SSH_COMMAND="${ssh_cmd:-ssh}" git clone --branch "$BRANCH" "$REPO_URL" "$REPO_PATH"
  fi
  # Make later fetches (deploy.sh --pull, CI) use the same key.
  [[ -n "$ssh_cmd" ]] && git -C "$REPO_PATH" config core.sshCommand "$ssh_cmd"
else
  ask REPO_PATH "Path of the existing checkout" "$(pwd)"
  REPO_PATH="${REPO_PATH/#\~/$HOME}"
fi

[[ -f "${REPO_PATH}/deploy/setup.sh" ]] || die "${REPO_PATH}/deploy/setup.sh not found — is this the right repository/branch?"
say "Starting setup from ${REPO_PATH}"
exec bash "${REPO_PATH}/deploy/setup.sh" "$@"
