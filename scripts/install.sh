#!/bin/bash
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

usage() {
    echo "Usage: $0 --host HOST [--queue QUEUE] [--name DISPLAY_NAME] [--replace-target] [--dry-run]" >&2
}

host=
queue=
name='QL-580N macOS Driver'
replace_target=0
dry_run=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --host|--queue|--name)
            if [[ $# -lt 2 || -z "$2" ]]; then usage; exit 2; fi
            case "$1" in
                --host) host=$2 ;;
                --queue) queue=$2 ;;
                --name) name=$2 ;;
            esac
            shift 2 ;;
        --replace-target) replace_target=1; shift ;;
        --dry-run) dry_run=1; shift ;;
        *) usage; exit 2 ;;
    esac
done

# The address becomes part of a CUPS URI, so accept only DNS names and IPv4.
if [[ -z "$host" || ${#host} -gt 253 || ! "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ || "$host" == *..* ]]; then
    echo "Invalid printer address. Enter an IPv4 address or DNS hostname without a scheme or port." >&2
    exit 2
fi
IFS=. read -r -a labels <<< "$host"
for label in "${labels[@]}"; do
    if [[ ${#label} -gt 63 || "$label" == -* || "$label" == *- ]]; then
        echo "Invalid printer address: malformed DNS label." >&2
        exit 2
    fi
done
if [[ "$host" =~ ^[0-9.]+$ ]]; then
    if [[ ${#labels[@]} -ne 4 ]]; then echo "Invalid IPv4 address." >&2; exit 2; fi
    for label in "${labels[@]}"; do
        if [[ ${#label} -gt 3 || $((10#$label)) -gt 255 ]]; then
            echo "Invalid IPv4 address." >&2
            exit 2
        fi
    done
fi
if [[ -z "$queue" ]]; then
    suffix=${host//./_}
    suffix=${suffix//-/_}
    queue="Brother_QL_580N_$suffix"
fi
if [[ ${#queue} -gt 127 || ! "$queue" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "Invalid queue name. Use up to 127 letters, numbers, dots, underscores or hyphens." >&2
    exit 2
fi
if [[ ${#name} -gt 127 || "$name" == *$'\n'* || "$name" == *$'\r'* || "$name" == *$'\t'* ]]; then
    echo "Invalid printer display name." >&2
    exit 2
fi
device="socket://$host:9100/?waiteof=false"
if [[ "$dry_run" -eq 1 ]]; then
    printf 'host=%s\nqueue=%s\nname=%s\ndevice=%s\n' "$host" "$queue" "$name" "$device"
    exit 0
fi

if [[ $(id -u) -ne 0 ]]; then
    echo "Run this installer as administrator: sudo scripts/install.sh --host HOST" >&2
    exit 1
fi
root_dir=$(cd "$(dirname "$0")/.." && pwd)
filter_source="$root_dir/build/rastertoql580n"
ppd_source="$root_dir/ppd/Brother-QL-580N-Native.ppd"
icon_source="$root_dir/assets/ql580n-native.icns"
install_dir=/Library/Printers/QL580NNative
if [[ ! -x "$filter_source" ]]; then
    echo "Missing built filter. Run make before installing." >&2
    exit 1
fi
if [[ ! -f "$ppd_source" ]]; then
    echo "Missing native PPD: $ppd_source" >&2
    exit 1
fi
if [[ ! -f "$icon_source" ]]; then
    echo "Missing project printer icon: $icon_source" >&2
    exit 1
fi
if ! LC_ALL=C lpstat -r >/dev/null 2>&1; then
    echo "CUPS is unavailable. Start the print service before installing." >&2
    exit 1
fi

# An explicit queue can update its target only when it already uses our PPD.
existing=$(LC_ALL=C lpstat -v "$queue" 2>/dev/null || true)
if [[ -n "$existing" ]]; then
    old_ppd="/etc/cups/ppd/$queue.ppd"
    if [[ ! -f "$old_ppd" ]] ||
       { ! grep -Fq '*NickName: "QL-580N macOS Driver CUPS Raster"' "$old_ppd" &&
         ! grep -Fq '*NickName: "Brother QL-580N Native CUPS Raster"' "$old_ppd"; }; then
        echo "Queue $queue already exists but does not use the native QL-580N PPD." >&2
        exit 1
    fi
    existing_device=${existing#*: }
    if [[ "$existing_device" != "$device" && "$replace_target" -ne 1 ]]; then
        echo "Queue $queue targets $existing_device. Pass --replace-target to change its address." >&2
        exit 1
    fi
    queue_exists=1
    saved_options=()
    for option in PageSize Resolution AutoCut QLHalftone QLMedia QLStatus QLTrim; do
        value=$(awk -v key="*Default$option:" '$1 == key { print $2; exit }' "$old_ppd")
        if [[ "$option" == PageSize ]]; then
            case "$value" in
                w62l42|w62l181) value=w62l50 ;;
            esac
        fi
        if [[ -n "$value" ]]; then saved_options+=(-o "$option=$value"); fi
    done
else
    queue_exists=0
fi
install -d -o root -g wheel -m 755 "$install_dir"
install -o root -g wheel -m 755 "$filter_source" "$install_dir/rastertoql580n"
install -o root -g wheel -m 644 "$ppd_source" "$install_dir/Brother-QL-580N-Native.ppd"
install -o root -g wheel -m 644 "$icon_source" "$install_dir/ql580n-native.icns"
rm -f "$install_dir/ql580n-printer.icns"
if [[ "$queue_exists" -eq 0 ]]; then
    lpadmin -p "$queue" -E -v "$device" \
        -P "$install_dir/Brother-QL-580N-Native.ppd" \
        -D "$name" -o PageSize=w62l50 \
        -o printer-is-shared=false -o printer-error-policy=stop-printer
    echo "Installed and enabled $queue on $device."
else
    lpadmin -p "$queue" -v "$device" -P "$install_dir/Brother-QL-580N-Native.ppd" \
        -D "$name" "${saved_options[@]}" -o printer-error-policy=stop-printer
    echo "Updated $queue on $device and preserved its print defaults."
fi
