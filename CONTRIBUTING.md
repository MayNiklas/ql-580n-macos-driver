# Contributing

Thanks for helping improve the QL-580N driver. Read the [development and script guide](docs/DEVELOPING.md) before changing the filter, installer, PPD, or release archives.

For a code change, describe the printer model, macOS version, media type, and expected behavior. Include `make test` results. If the change affects printed output or installation, state whether it was checked on physical hardware. Do not include printer addresses, serial numbers, local diagnostic files, or third-party driver assets in a contribution.

Generate the tracked PPD with `python3 scripts/generate_ppd.py` when changing media or print options. Keep source files, scripts, tests, and public documentation aligned.

Contributions are released under the project's [MIT license](LICENSE).
