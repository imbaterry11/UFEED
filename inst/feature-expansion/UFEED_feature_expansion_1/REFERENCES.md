# Scientific references and decisions

1. Allen RG, Pereira LS, Raes D, Smith M. 1998. *Crop evapotranspiration:
   Guidelines for computing crop water requirements*. FAO Irrigation and
   Drainage Paper 56. https://www.fao.org/4/X0490E/X0490E00.htm
   - vapor pressure: equations 11-19
   - pressure and psychrometric constant: equations 7-8
   - wind adjustment to 2 m: equation 47
   - radiation: equations 21 and 35-39
   - reference ET: equation 6

2. Knauer J, El-Madany TS, Zaehle S, Migliavacca M. 2018. Bigleaf—An R
   package for physical and physiological ecosystem properties.
   *PLOS ONE* 13:e0201114. https://doi.org/10.1371/journal.pone.0201114

3. Guo D, Westra S, Peterson T. `Evapotranspiration` R package.
   https://CRAN.R-project.org/package=Evapotranspiration
   - independent FAO-56 numerical comparison; not a runtime dependency

4. Open-Meteo documentation. https://open-meteo.com/en/docs
   - daily shortwave sum is MJ m-2; standard wind variables are at 10 m

5. NASA POWER Daily API and Parameter Dictionary.
   https://power.larc.nasa.gov/docs/services/api/temporal/daily/
   https://power.larc.nasa.gov/parameters/
   - units depend on community; inspect returned metadata

## Corrections to the earlier prototype

- Explicit unit declaration and conversion replace silent numeric assumptions.
- Wind height is explicit and adjusted to 2 m.
- Daily FAO-56 saturation vapor pressure uses Tmax and Tmin.
- Mean-RH vapor pressure follows FAO-56 equation 19 and is labeled lower quality.
- Rs/Rso is constrained to 0.3-1.0 in the longwave term.
- Missing pressure/elevation no longer silently becomes sea-level conditions.
- Net radiation is not clamped to zero.
- ET0 is distinguished from actual ET and crop transpiration.
- The VPD-wind product is labeled as an interaction, not a physical flux.
