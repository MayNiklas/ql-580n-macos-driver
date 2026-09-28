# Tested media and features

This table separates physical printer checks from automated output checks. "Supported" in the README means the driver accepts the size; it does not mean every roll has been tested on hardware.

| Media or feature | Automated check | Physical QL-580N check |
| --- | --- | --- |
| 62 mm continuous, 50 mm length | Raster geometry, copying, cutting, custom length, and both resolutions | Printed and cut at 300 x 300 and 300 x 600 DPI |
| 62 mm continuous, other lengths from 19 to 1000 mm | Selected custom lengths and trim behavior | Not yet checked |
| 29 mm continuous | Automatic roll selection and media mismatch behavior | Not yet checked |
| 12, 38, 50, and 54 mm continuous | Geometry defined from the published command reference | Not yet checked |
| 29 x 90 mm die-cut | Printable rows, fine resolution, and no trimming | Not yet checked |
| Other listed rectangular die-cut sizes | Geometry defined from the published command reference | Not yet checked |
| Empty roll and recovery | Simulated status and completion cases | Empty-roll job blocked; printing resumed after reloading |
| Blank-space trimming | Software checks at both resolutions, including blank and die-cut pages | Not yet checked |

The physical observations were made on Apple Silicon macOS 27.0 with QL-580N firmware 1.30 and a 62 mm continuous roll. A successful print at another size or firmware version is useful evidence, but should be reported with the exact media, resolution, macOS version, and driver commit or release tag.
