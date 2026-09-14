# UFEED 0.1.2

Patch release.

## Changed

- Updated the `power_ee` pathway so `WD2M` is derived from ERA5-Land daily
  10 m U/V wind components instead of retaining the NASA POWER value.
- Preserved the existing `WD2M` column name and meteorological convention
  (0 degrees = North, 90 = East, 180 = South, and 270 = West).

# UFEED 0.1.1

Patch release.

## Fixed

- Suppressed expected current-year data-lag warnings inside
  `UFEED_present()` while retaining them for explicit historical downloads.
- Prevented duplicate current-year lag warnings from nested NASA POWER calls
  in the `power_open_meteo` workflow.

# UFEED 0.1.0

Initial public release.

## Included

- Historical and present-season weather-data acquisition
- Core environmental feature computation
- Soil feature extraction
- High-level and modular UFEED workflows
- Support for user-supplied weather-station data

## Under development

- Atmospheric-demand feature expansion
- Surface-energy and radiation feature expansion
