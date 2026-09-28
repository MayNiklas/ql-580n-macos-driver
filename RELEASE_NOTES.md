# QL-580N macOS Driver

An independent Apple Silicon CUPS driver for networked Brother QL-580N label printers. It prints through the standard macOS print dialog without Rosetta, Homebrew, or a Brother printing binary.

Version 1.5.0 lowers the setup app and print filter minimum from macOS 27 to macOS 26. It builds against the macOS 27 SDK and has been tested on macOS 27. Physical printing on macOS 26 still needs verification.

## Included

- A graphical setup app with printer discovery, connection checks, queue updates, and removal.
- Continuous and rectangular die-cut label sizes, 300 x 300 and 300 x 600 DPI, cutting, halftoning, and optional blank-space trimming.
- Roll checks and printer error reporting through CUPS. The driver waits for page-counter progress before reporting completion.
- An original label-printer icon and source code under the MIT license.

## Requirements and limits

Apple Silicon macOS 26 or later and a QL-580N reachable on TCP port 9100 and read-only SNMP UDP port 161 are required. Physical printing has been verified on macOS 27 with a 62 mm continuous roll; macOS 26 and other listed media need hardware verification. USB and IPv6 setup are not supported.

The setup app is ad-hoc signed and not notarized. macOS may require **Open Anyway** in System Settings > Privacy & Security after the first launch attempt. See the included README for installation, printing, and failed-job guidance.
