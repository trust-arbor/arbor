#!/usr/bin/env bash
set -euo pipefail
umask 077
[[ $(id -un) == arbor ]] || { echo 'Run inside the factory as arbor.' >&2; exit 1; }
[[ $# == 1 && $1 =~ ^(worker|baseline|start)$ ]] || {
  echo 'Usage: factory-runtime.sh worker|baseline|start' >&2; exit 1;
}
export TMPDIR="$HOME/.arbor/tmp"
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$PATH"
export HEX_CACERTS_PATH=/etc/ssl/certs/ca-certificates.crt
export ERL_FLAGS='+S 12:12'
cd "$HOME/code/arbor"
[[ $(git rev-parse HEAD) == "$(< "$HOME/.arbor/factory-revision")" ]] || {
  echo 'Factory source revision changed; review an upgrade before continuing.' >&2; exit 1;
}
case $1 in
  worker)
    # Exact bytes observed from xAI's official HTTPS distribution on 2026-09-07.
    # This pin is not a vendor signature. Review version+digest together on upgrade.
    version=0.2.118
    digest=c192282e62abd24a9be64750363ff827d806ba613918399a8c69c815b1da08f6
    binary="$TMPDIR/grok-linux-$version"
    [[ $(uname -m) == x86_64 ]] || { echo 'This worker pin is linux/amd64 only.' >&2; exit 1; }
    if [[ ! -f $binary ]]; then
      curl --fail --location --proto '=https' --proto-redir '=https' --max-time 300 \
        "https://x.ai/cli/grok-$version-linux-x86_64" -o "$binary"
    fi
    printf '%s  %s\n' "$digest" "$binary" | sha256sum -c -
    sudo install -o root -g root -m 0755 "$binary" /usr/local/bin/grok
    grok --version
    ;;
  baseline)
    [[ -z $(git status --porcelain) ]] || { echo 'Baseline requires a clean tree.' >&2; exit 1; }
    from=$(awk '$1 == "FROM" {print $2}' images/validation-runtime/Containerfile)
    [[ $from =~ ^debian:bookworm-slim@sha256:[0-9a-f]{64}$ ]] || {
      echo 'Unexpected validation base; review the Containerfile.' >&2; exit 1;
    }
    podman pull "docker.io/library/$from"
    log="$HOME/.arbor/factory-baseline-build.log"
    ./bin/mix arbor.baseline.build 2>&1 | tee "$log"
    digest=$(sed -n 's/^  tree_digest=\([0-9a-f]\{64\}\)$/\1/p' "$log")
    [[ $digest =~ ^[0-9a-f]{64}$ ]] || { echo 'Missing unique build digest.' >&2; exit 1; }
    [[ $(git rev-parse HEAD) == "$(< "$HOME/.arbor/factory-revision")" && -z $(git status --porcelain) ]] || {
      echo 'Source changed during build; refusing activation.' >&2; exit 1;
    }
    ./bin/mix arbor.baseline.activate "$digest"
    ./bin/mix arbor.baseline.status
    echo 'A running node must be explicitly restarted to adopt this baseline.'
    ;;
  start)
    [[ -f .env ]] || { echo 'Run factory-user.sh first.' >&2; exit 1; }
    for entry in "TMPDIR=$TMPDIR" 'ARBOR_NODE_HOST=127.0.0.1' 'ARBOR_DEFAULT_PROVIDER=ollama'; do
      key=${entry%%=*}
      if ! grep -q "^$key=" .env; then
        printf '\n%s\n' "$entry" >> .env
      fi
    done
    ./bin/mix arbor.start
    ;;
esac
