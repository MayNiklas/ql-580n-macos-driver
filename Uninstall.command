#!/bin/bash
set -euo pipefail

root_dir=$(cd "$(dirname "$0")" && pwd)
if [[ $# -eq 0 ]]; then
    echo "Installed printer queues:"
    LC_ALL=C lpstat -v
    read -r -p "Queue name to remove: " queue
    if [[ -z "$queue" ]]; then
        echo "No queue selected."
        exit 1
    fi
    arguments=(--queue "$queue")
else
    arguments=("$@")
fi
staging=$(mktemp /private/tmp/ql580n-uninstall.XXXXXX)
trap 'rm -f "$staging"' EXIT
cp "$root_dir/scripts/uninstall.sh" "$staging"
sudo /bin/bash "$staging" "${arguments[@]}"
