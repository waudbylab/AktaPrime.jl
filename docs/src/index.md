# AktaPrime.jl

**Open-source control and data logging for the GE/Cytiva ÄKTAprime and ÄKTAprime plus FPLC.**

AktaPrime.jl is a free replacement for the discontinued PrimeView software. It
connects to an ÄKTA Prime over the instrument's serial (RS-232) link and gives
you a live chromatogram, event and fraction tracking, and a plain-text log of
every run — so an instrument whose original control PC has failed, or which was
bought second-hand without usable software, can be brought back into service on
any ordinary laptop.

![The AktaPrime.jl window](assets/screenshot.png)

## What it does

- **Live monitoring** of UV, conductivity, pH, gradient %B, pressure and the set
  flow, stacked or overlaid in one plot, against time, volume or column volumes.
- **Event and fraction tracking** — valve moves, run-state changes, method steps
  and fraction-collection spans are drawn straight onto the chromatogram; your
  own **event marks** can be added during a run.
- **A live flow-path schematic and readings** — current valve positions
  (injection valve and the 8-port buffer valve), routing and measured values.
- **Inspect any moment** — a time slider (or Alt/Shift-click) shows the valve
  states and readings at any point of a run; hovering shows values under the
  mouse; the **run log** lists every event.
- **Automatic per-run logging** — every run is written to its own timestamped
  CSV file, together with its **run information** (sample, column, buffers).
- **Reopen runs and export figures** — open earlier runs in their own tabs, and
  export plots to PDF for reports and publications.
- **Method editor** — write methods on the PC; the instrument loads them with
  *Run Stored Method → PC*, and saves its own methods there too.
- **Settings** for serial port, data folder, volume unit (ÄKTAprime or
  ÄKTAprime plus), panels shown at start, dark mode and more.
- **Demo mode** — explore the whole interface with simulated data, no instrument
  required.

## Getting started

1. [Install Julia and the app](@ref Installation), and connect your instrument.
2. [Start an acquisition](@ref Acquisition).
3. [View and export your results](@ref "Viewing results").

No instrument to hand? Try [demo mode](@ref "Demo mode") first.

!!! note "About the instrument link"
    AktaPrime.jl reproduces the *monitoring* role that PrimeView performed: you
    run the separation from the ÄKTA Prime's own front panel, and the software
    watches, displays and records. This mirrors how PrimeView itself worked.
