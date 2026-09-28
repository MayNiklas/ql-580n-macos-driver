# QL-580N macOS Driver

Print from the macOS print dialog to a networked Brother QL-580N. The driver uses an Apple Silicon CUPS filter, with no Rosetta, Homebrew, Python runtime, or Brother binary needed for printing.

This community project is independent of Brother. It targets Apple Silicon on macOS 26 or later, with network printing over TCP port 9100 and printer status over read-only SNMP on UDP port 161. The driver has been tested on macOS 27; macOS 26 still needs a physical print test. USB and IPv6 setup are not supported.

## Why this driver exists

Brother has not published an updated macOS printer driver for the QL-580N in several macOS releases. The older driver stopped working on the tested Apple Silicon Mac after upgrading to macOS 27. Brother's [macOS 27 support table](https://support.brother.com/g/b/oscontents.aspx?c=us&lang=en&ossid=52) does not list printer-driver or AirPrint support for this model. This project restores printing from the normal macOS print dialog.

## How it was developed

The old driver no longer printed on the tested Mac with macOS 27, so this replacement was written using Brother's [QL Series Raster Command Reference](https://download.brother.com/welcome/docp000678/cv_qlseries_eng_raster_600.pdf) and the [CUPS raster driver guide](https://apple.github.io/cups/doc/raster-driver.html) and [raster API](https://apple.github.io/cups/doc/api-raster.html). [brother_ql_next](https://github.com/LunarEclipse363/brother_ql_next) provided another reference for network printing. Automated tests and prints on a physical QL-580N with a 62 mm roll were used to check the result. See the [development guide](docs/DEVELOPING.md) for technical details.

## Install

Download `QL-580N-macOS-Driver-v<version>-Setup.zip` from a release, extract it, and open **QL-580N macOS Driver Setup.app**. The archive also contains release notes, the README, and the license. A matching `.sha256` file is available with the ZIP. To check the download before extraction, put both files in the same folder and run `shasum -a 256 -c *.sha256` from that folder.

1. Select a discovered QL-580N or enter its IPv4 address or hostname.
2. Choose the name to show in the print dialog.
3. Select **Install Printer** and approve the macOS administrator prompt.

Allow **Local Network** access if macOS asks. If a connection check completes before permission is granted, select **Check Connection** again. The printer must accept raw printing on TCP 9100 and read-only SNMP on UDP 161 with community `public`. **Check Connection** checks the model, loaded roll, status access, and printing port without printing a label. An empty roll does not prevent installation.

The app can update an existing native queue and preserves its saved print defaults. It creates a separate queue from any other Brother driver and does not change the default printer. Reopen applications or print dialogs that were already open if the new printer does not appear.

The app is ad-hoc signed and is not notarized because the project has no Developer ID. After trying to open it, macOS may require **System Settings > Privacy & Security > Open Anyway**. Follow [Apple's instructions for opening an app from an unknown developer](https://support.apple.com/guide/mac-help/open-a-mac-app-from-an-unknown-developer-mh40616/mac) and only proceed when you trust the downloaded release.

To remove a printer, reopen the setup app, choose its queue under **Installed driver queues**, and select **Remove Selected Printer**. The app confirms the queue name and asks for administrator authentication. Shared driver files remain if another native QL-580N queue uses them. The source archive also has a Terminal uninstaller; see the [development and script guide](docs/DEVELOPING.md).

## Print labels

Select **QL-580N macOS Driver** in an application's print dialog, unless you chose another display name during setup. The default is a 62 mm continuous roll with a 50 mm label length, 300 x 600 DPI fine resolution, automatic cutting, and printer status checks. Use a document page size that matches the intended label, then print at Actual Size or 100%.

The driver's options appear under **Printer Features**. **Roll Selection** defaults to **Use selected paper size** and blocks a job when the loaded roll does not match. **Automatic (fit to loaded roll)** adapts to detected media, centering the artwork and reducing its size if needed. It does not enlarge artwork. For continuous rolls, **Trim Blank Space** can shorten the label without scaling the artwork; it is off by default. Turn it off when the physical length must match the selected paper size. **Halftone** defaults to Ordered; Threshold may suit crisp black-and-white artwork.

For continuous rolls, create a custom paper size in the print dialog to use a length from 19 to 1000 mm. Set the width to the roll's physical width. For a 62 mm roll, the printable margins are approximately 1.52 mm left/right and 2.96 mm top/bottom. A 54 mm roll needs approximately 1.95 mm left/right. The driver crops to the print head's usable area. Save a printer-specific print preset for frequently used custom sizes. Some applications, including Preview, may show an output paper size that differs from the PDF's own page size, so inspect the print preview for clipping.

For Terminal printing, find the queue name with `lpstat -p` and substitute it below:

```sh
lp -d Brother_QL_580N_printer_local -o PageSize=w62l50 label.pdf
lp -d Brother_QL_580N_printer_local -o PageSize=Custom.62x75mm label.pdf
lp -d Brother_QL_580N_printer_local -n 2 -o PageSize=w62l50 label.pdf
lp -d Brother_QL_580N_printer_local -o AutoCut=Off -o QLTrim=On label.pdf
```

The driver supports continuous widths of 12, 29, 38, 50, 54, and 62 mm. Built-in continuous lengths are 30, 50, 100, 150, and 200 mm. Rectangular die-cut sizes are 17x54, 17x87, 23x23, 29x90, 38x90, 39x48, 52x29, 62x29, and 62x100 mm. Round labels are not supported. Output is black and white with grayscale halftoning at 300 x 300 or 300 x 600 DPI.

## Printer status and failed jobs

The driver checks the loaded roll and printer errors before sending print data. It reports conditions such as an empty roll, open cover, and cutter jam through CUPS. After transmission, it waits for the printer's page counter and idle status to confirm completion. This is counter-based confirmation, not a job-specific acknowledgement. Avoid sending simultaneous jobs to the same device from other computers or queues.

Missing status, errors, or 120 seconds without progress fail the job. The queue stops to avoid replaying an uncertain job. Check the physical labels, cancel the failed job if needed, fix the printer problem, and resume the queue in Print Center. Some labels may already have printed. Cancellation cannot retract data already accepted by the printer. CUPS may also show a generic `Filter failed` message alongside the specific printer reason.

Status is checked while a job is active, so an idle queue may not immediately show a printer problem. Offline raster conversion is available with both `QLMedia=Manual` and `QLStatus=Off`; it cannot check media or confirm physical completion.

## Scope and reliability

The 62 mm continuous roll has been physically tested. Other supported media use Brother's published print-area geometry and selected automated tests. Blank-space trimming has software test coverage, but its physical output has not yet been checked. See the [tested-media matrix](docs/TESTED_MEDIA.md). The driver uses the classic CUPS PPD/filter interface, so future macOS compatibility depends on that interface remaining available.

The printer and setup app use an original teal label-printer icon from `assets/ql580n-native.svg`. See [development and script guide](docs/DEVELOPING.md) for build instructions, tests, implementation notes, and references. Project files are licensed under [MIT](LICENSE). The repository excludes local build artifacts and third-party reference downloads.
