# Scientific references

1. STICS Project Team. *STICS soil-crop model: conceptual framework,
   equations and uses*. https://stics.inrae.fr/eng/resources/documentation-and-tutorials
   - establishes why weather is forcing rather than a complete plant/soil state

2. Brisson N et al. 2003. An overview of the crop model STICS.
   *European Journal of Agronomy* 18:309-332.
   https://doi.org/10.1016/S1161-0301(02)00110-7

3. Wang E, Engel T. 1998. Simulation of phenological development of wheat
   crops. *Agricultural Systems* 58:1-24.
   https://doi.org/10.1016/S0308-521X(98)00028-6
   - normalized nonlinear cardinal-temperature response

4. Monteith JL. 1977. Climate and the efficiency of crop production in
   Britain. *Philosophical Transactions of the Royal Society B* 281:277-294.
   https://doi.org/10.1098/rstb.1977.0140
   - biomass proportionality to intercepted radiation under nonlimiting conditions

5. Monsi M, Saeki T. 1953. Über den Lichtfaktor in den Pflanzengesellschaften
   und seine Bedeutung für die Stoffproduktion. *Japanese Journal of Botany*
   14:22-52. English translation: 2005, *Annals of Botany* 95:549-567.
   https://doi.org/10.1093/aob/mci052
   - exponential canopy light attenuation

6. Kiniry JR et al. 1989. Radiation-use efficiency in biomass accumulation
   prior to grain-filling for five grain-crop species. *Field Crops Research*
   20:51-64. https://doi.org/10.1016/0378-4290(89)90023-3

7. Demetriades-Shah TH, Fuchs M, Kanemasu ET, Flitcroft I. 1992. A note of
   caution concerning the relationship between cumulated intercepted solar
   radiation and crop growth. *Agricultural and Forest Meteorology* 58:193-207.
   https://doi.org/10.1016/0168-1923(92)90061-8

8. Bonhomme R. 2000. Beware of comparing RUE values calculated from PAR vs
   solar radiation or absorbed vs intercepted radiation.
   *Field Crops Research* 68:247-252.
   https://doi.org/10.1016/S0378-4290(00)00120-9

## Deliberate exclusions

- Farquhar photosynthesis: daily weather alone lacks leaf/canopy state,
  biochemical capacity, CO2 at the relevant scale, and subdaily radiation.
- Actual transpiration: requires canopy and aerodynamic resistances plus soil
  water supply and root uptake.
- Water and nitrogen stress: require stateful soil profiles and plant demand.
- Phenological stage: requires a crop-cycle origin and calibrated stage
  requirements; expansion 2 reports normalized development opportunity only.
- Yield and organ allocation: require source-sink and cultivar parameters.
