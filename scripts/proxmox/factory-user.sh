#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $(id -un) == arbor ]] || { echo 'Run as the factory guest arbor user.' >&2; exit 1; }
[[ -f /var/lib/arbor-factory-system-ready ]] || { echo 'System bootstrap is not ready.' >&2; exit 1; }
[[ $# == 2 ]] || { echo 'Usage: factory-user.sh REPO_URL FULL_COMMIT_SHA' >&2; exit 1; }
repo_url=$1
revision=$2
[[ $repo_url == https://* || $repo_url == http://* ]] || { echo 'Use an HTTP(S) clone URL.' >&2; exit 1; }
[[ $repo_url != *'@'* && $repo_url != *$'\n'* ]] || { echo 'Do not embed credentials in URLs.' >&2; exit 1; }
[[ $revision =~ ^[0-9a-f]{40}$ ]] || { echo 'Pin a full commit SHA.' >&2; exit 1; }
export TMPDIR="$HOME/.arbor/tmp"
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
export ERL_FLAGS='+S 12:12'
mkdir -p "$HOME/code" "$TMPDIR"
if [[ ! -e "$HOME/code/arbor" ]]; then
  git clone -- "$repo_url" "$HOME/code/arbor"
fi
cd "$HOME/code/arbor"
[[ $(git remote get-url origin) == "$repo_url" ]] || { echo 'Clone origin mismatch.' >&2; exit 1; }
[[ -z $(git status --porcelain) ]] || { echo 'Existing checkout is dirty; refusing mutation.' >&2; exit 1; }
if [[ -e "$HOME/.arbor/factory-revision" ]]; then
  [[ $(< "$HOME/.arbor/factory-revision") == "$revision" && $(git rev-parse HEAD) == "$revision" ]] || {
    echo 'Existing factory revision differs; use a new guest or an explicit reviewed upgrade.' >&2; exit 1;
  }
else
  git fetch origin "$revision"
  git checkout --detach "$revision"
  printf '%s\n' "$revision" > "$HOME/.arbor/factory-revision"
fi
mise trust "$PWD"
mise install
mise use --global node@24
./bin/mix local.hex --force --if-missing
./bin/mix local.rebar --force --if-missing
./bin/mix deps.get
./bin/mix arbor.setup
printf '%s\n' "Source and tools ready at $PWD ($revision)." \
  'Next: install a reviewed ACP CLI, authenticate providers on THIS guest,' \
  'build/activate the Linux dependency baseline, and run dispatch readiness.' \
  'No credentials were copied, no model requests sent, no cluster joined.'
