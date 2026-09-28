#!/bin/bash
set -euo pipefail
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

if [[ $# -ne 2 || "$1" != --queue ]]; then
    echo "Usage: $0 --queue QUEUE" >&2
    exit 2
fi
queue=$2
if [[ ${#queue} -gt 127 || ! "$queue" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "Invalid queue name." >&2
    exit 2
fi
if [[ $(id -u) -ne 0 ]]; then
    echo "Run this uninstaller as administrator: sudo scripts/uninstall.sh --queue QUEUE" >&2
    exit 1
fi
if ! LC_ALL=C lpstat -r >/dev/null 2>&1; then
    echo "CUPS is unavailable. Start the print service before uninstalling." >&2
    exit 1
fi
if ! LC_ALL=C lpstat -v "$queue" >/dev/null 2>&1; then
    echo "Queue $queue does not exist." >&2
    exit 1
fi
ppd="/etc/cups/ppd/$queue.ppd"
if [[ ! -f "$ppd" ]] ||
   { ! grep -Fq '*NickName: "QL-580N macOS Driver CUPS Raster"' "$ppd" &&
     ! grep -Fq '*NickName: "Brother QL-580N Native CUPS Raster"' "$ppd"; }; then
    echo "Queue $queue does not use the native QL-580N PPD." >&2
    exit 1
fi
lpadmin -x "$queue"
echo "Removed queue $queue."

# Keep the shared filter while another queue still refers to this driver.
for ppd in /etc/cups/ppd/*.ppd; do
    if [[ -f "$ppd" ]] &&
       { grep -Fq '*NickName: "QL-580N macOS Driver CUPS Raster"' "$ppd" ||
         grep -Fq '*NickName: "Brother QL-580N Native CUPS Raster"' "$ppd"; }; then
        echo "Kept shared driver files for another native QL-580N queue."
        exit 0
    fi
done
install_dir=/Library/Printers/QL580NNative
rm -f "$install_dir/rastertoql580n" "$install_dir/Brother-QL-580N-Native.ppd" \
    "$install_dir/ql580n-printer.icns" "$install_dir/ql580n-native.icns"
if [[ -d "$install_dir" ]]; then rmdir "$install_dir" 2>/dev/null || true; fi
echo "Removed the native QL-580N driver files."
