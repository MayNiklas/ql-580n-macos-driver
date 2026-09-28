# Development and script guide

## Requirements

Build and test on Apple Silicon macOS. The native C filter requires CUPS headers and a compiler from Apple's developer tools. The filter and graphical setup app target macOS 26 or later and require an SDK that supports that target. Python 3 is needed for tests and the optional utilities; all Python code uses the standard library. Do not install Python packages to build this project.

```sh
make test
make
make package
```

`make test` checks the generated PPD, builds the filter, generates a small PDF fixture, and runs the unit and CUPS integration tests. `make` builds the filter and graphical setup app. `make package` creates `dist/QL-580N-macOS-Driver-v<version>-Source.zip` with source and a prebuilt filter, and `dist/QL-580N-macOS-Driver-v<version>-Setup.zip` for end users. It also writes the setup ZIP's `.sha256` file. The setup archive contains the app with installation and removal controls, README, release notes, license, and documentation. Packaging checks both archives against an exact file list and verifies the checksum. `make clean` removes the filter and setup app, but leaves archives and the generated test PDF.

`VERSION` is the only source for the release number. The app's two bundle version fields, generated PPD `FileVersion`, ZIP names, and release title use it. Tags must be `v` followed by the exact `VERSION` value, such as `v1.4.0`. The release workflow rejects a tag that does not match. Update `VERSION`, regenerate the PPD, and review both changes for a new release.

The generated PPD is committed. When editing `scripts/generate_ppd.py`, regenerate and review the PPD diff:

```sh
python3 scripts/generate_ppd.py
cupstestppd -I filters ppd/Brother-QL-580N-Native.ppd
```

PPD validation may report naming warnings for continuous and die-cut media with the same dimensions. The `-I filters` option skips checking the filter's installed path before installation.

The printer icon is original SVG artwork at `assets/ql580n-native.svg`. Its generated ICNS file is tracked so normal builds need no image tool. To regenerate it, install `rsvg-convert` for that maintenance task and run `python3 scripts/build_icon.py`. The build script uses Python's standard library to assemble the rendered icon sizes. The installed filter and PPD paths remain unchanged so older native queues can be updated.

## Where each script belongs

| Path | Purpose | Typical caller |
| --- | --- | --- |
| `Install.command` | Interactive Terminal installer for a built source tree or source/prebuilt archive | Person installing without the app |
| `Uninstall.command` | Terminal queue removal, included in the source archive | Person removing a native queue without the app |
| `scripts/install.sh` | Validates options and installs the filter, PPD, and queue as administrator | Setup app or `Install.command` |
| `scripts/uninstall.sh` | Removes a native queue and shared files when no native queues remain | Setup app or `Uninstall.command` |
| `scripts/build_setup.sh` | Compiles and assembles the graphical app bundle | `make setup` |
| `scripts/package.sh` | Builds the two distribution ZIP files | `make package` |
| `scripts/package_manifest.txt` | Lists the exact source archive files | `scripts/package.sh` |
| `scripts/check_release.py` | Checks PPD freshness, version metadata, and ZIP contents | `make test` and `make package` |
| `scripts/build_icon.py` | Regenerates the tracked ICNS file from the SVG | Maintainer |
| `scripts/generate_ppd.py` | Generates the tracked PPD from media geometry and driver options | Maintainer |
| `tests/make_test_label.py` | Generates a 62 x 50 mm PDF fixture under `build/` | `make test` |
| `tools/printer_tool.py` | Reads HTTP diagnostics or sends a prepared raster file | Advanced diagnostics |

The scripts in `scripts/` are internal build and installation components. Run them through the `make` targets or the root `.command` launchers unless you are debugging a specific step. The `tests/` directory contains fixtures and automated tests. The `tools/` directory contains optional, manually invoked diagnostics.

A Terminal install from a built tree can be run with:

```sh
./Install.command --host printer.local --name "Office Labels"
./Install.command --host printer.local --queue Brother_QL_580N_Native
```

An existing queue with a different target requires `--replace-target`. The installer will not overwrite a queue that uses another driver's PPD. The app and Terminal installer stage their payload under `/private/tmp` so an administrator process can read it when the source is in a protected directory.

The optional diagnostic tool requires an explicit printer address:

```sh
python3 tools/printer_tool.py --host printer.local status
python3 tools/printer_tool.py --host printer.local send prepared-job.bin
```

`status` reads the printer's HTTP maintenance and configuration pages. `send` transmits an existing Brother raster file to port 9100 without CUPS checks or a physical completion acknowledgement. Use `send` only for deliberate protocol testing.

## Design and test scope

macOS renders documents into CUPS raster. The filter maps raster rows into the QL-580N's 720-dot head, applies bit ordering and PackBits compression, and emits Brother commands. It validates a complete job in a temporary spool before sending any print data. The built-in CUPS socket backend transports the data.

The driver reads the QL-580N's 32-byte status packet at SNMP OID `.1.3.6.1.4.1.2435.3.3.9.1.6.1.0` through `cupsSideChannelSNMPGet`. It checks the physical page counter at Printer MIB OID `.1.3.6.1.2.1.43.10.2.1.4.1.1`. Completion based on this counter can be ambiguous if other computers print at the same time.

Automated tests decode the generated raster stream and check geometry, copying, cutting, compression, trimming, malformed input, roll selection, status failures, and completion handling. CUPS integration tests render PDFs for custom sizes and 300 x 600 DPI. The status tests use a mock side channel. These tests do not replace physical checks with a printer and each supported media type.

The project was originally verified on Apple Silicon macOS 27.0 with QL-580N firmware 1.30 and a 62 mm continuous roll. Physical checks included normal printing and cutting, fine resolution, an empty-roll failure, and recovery. macOS 26, other media types, and the trim feature need physical verification before claiming broad hardware coverage.

## Release process

GitHub Actions runs `make test` and `make package` on `xcode-27`. These events have different outcomes:

| Event | Checks and artifact | GitHub Release |
| --- | --- | --- |
| Push to a branch | Builds, tests, and uploads a setup ZIP and checksum to that workflow run | None |
| Push a tag matching `VERSION` | Builds, tests, and uploads a setup ZIP and checksum | Published after the build succeeds |
| Pull request | Builds and tests the proposed commit and uploads its setup ZIP and checksum for review | None |
| Manual workflow run on a branch | Builds, tests, and uploads its setup ZIP and checksum | None |
| Manual workflow run on a tag matching `VERSION` | Rebuilds, tests, and uploads the ZIP and checksum | Creates or updates the Release |

Pushing a matching version tag publishes a GitHub Release automatically after the build passes. Complete release checks and review the tagged commit before pushing the tag. A manual run remains available to retry a failed release: run `gh workflow run build.yml --ref vX.Y.Z` with the actual tag, or select that tag under **Actions > Build and release > Run workflow**. The release job requires the tag to match `VERSION`; it uses the tracked `RELEASE_NOTES.md` for the release body and `VERSION` for the title. The project has no Developer ID, so the app is ad-hoc signed and cannot be notarized in the current setup.

The source ZIP contains only the files in `scripts/package_manifest.txt` plus the built filter. `scripts/check_release.py` compares that list with the Git index and checks both ZIPs for unexpected files, missing payloads, stale PPDs, mismatched icons, and mismatched versions. Stage newly added files before running `make package` locally so the manifest check sees them as tracked.

The filter and project code are independently implemented. The repository does not contain the third-party reference downloads held locally in ignored `sources/` and `vendor/` directories. The printer icon is original project artwork.

## References

- [Brother QL Series Raster Command Reference](https://download.brother.com/welcome/docp000678/cv_qlseries_eng_raster_600.pdf)
- [CUPS raster driver guide](https://apple.github.io/cups/doc/raster-driver.html) and [raster API](https://apple.github.io/cups/doc/api-raster.html)
- [brother_ql_next](https://github.com/LunarEclipse363/brother_ql_next) as a network printing and raster orientation reference
