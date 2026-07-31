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
