#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo 'Usage: dev-install.sh [--release-fast] [--bin-dir directory]'
    echo 'Build and install nib-dev from committed local dev.'
}

fail() {
    echo "nib-dev: $*" >&2
    exit 1
}

mode=Debug
bin_dir=
while (( $# )); do
    case $1 in
        --release-fast) mode=ReleaseFast; shift ;;
        --bin-dir)
            [[ $# -ge 2 && -n $2 ]] || fail '--bin-dir needs a directory'
            bin_dir=$2; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; fail "unknown argument: $1" ;;
    esac
done

# Ignore any repository overrides inherited from a Git hook or another checkout.
for var in $(git rev-parse --local-env-vars); do unset "$var"; done
export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
commit=$(git -C "$script_dir" rev-parse --verify --quiet 'refs/heads/dev^{commit}') ||
    fail 'cannot resolve local refs/heads/dev in the script repository (no fallback)'
objects=$(git -C "$script_dir" rev-parse --path-format=absolute --git-path objects)
object_format=$(git -C "$script_dir" rev-parse --show-object-format)

bin_dir=${bin_dir:-$HOME/.local/bin}
case $bin_dir in /*) ;; *) bin_dir=$PWD/$bin_dir ;; esac
printf 'Source: local dev (%s)\nBuild:  %s\nTarget: %s/nib-dev\n' "$commit" "$mode" "${bin_dir%/}"

staged=
tmp_parent=$(cd -- "${TMPDIR:-/tmp}" && pwd -P)
tmp=$(mktemp -d "$tmp_parent/nib-dev.XXXXXXXX")
cleanup() {
    if [[ -n $staged ]]; then rm -f -- "$staged"; fi
    rm -rf -- "$tmp"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

(
    # Borrow objects read-only; the scratch checkout has its own HEAD, index and config.
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git init -q --template= --object-format="$object_format" "$tmp/source"
    printf '%s\n' "$objects" > "$tmp/source/.git/objects/info/alternates"
    cd -- "$tmp/source"
    git -c core.attributesFile=/dev/null checkout --quiet --detach "$commit"
    zig build "-Doptimize=$mode" --cache-dir "$tmp/cache" --prefix "$tmp/out"
)

mkdir -p -- "$bin_dir"
staged=$(mktemp "$bin_dir/.nib-dev.XXXXXXXX")
cp -- "$tmp/out/bin/nib" "$staged"
chmod 755 "$staged"
version=$("$staged" --version) || fail 'staged executable failed --version'
[[ $version == 'nib '?* ]] || fail 'unexpected --version output from staged executable'

# Rename over the destination, never into it (including a symlink to a directory).
python3 -c 'import os, sys; os.replace(*sys.argv[1:])' "$staged" "$bin_dir/nib-dev"
printf 'Installed %s/nib-dev (%s)\n' "${bin_dir%/}" "$version"
