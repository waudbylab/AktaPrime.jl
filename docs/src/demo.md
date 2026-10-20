# Demo mode

You do not need an instrument to try AktaPrime.jl. Switch on **Demo mode** on
the [Settings page](@ref Settings) and the display is fed with simulated data;
switch it off to connect to the instrument again. The setting is remembered, so
the app starts in demo mode until you switch it off.

This is useful for:

- learning your way around the interface before you are at the bench;
- teaching and demonstrations;
- producing example figures.

![AktaPrime.jl running in demo mode](assets/screenshot.png)

*Demo mode: a simulated run, with the gradient (%B), two UV peaks, changing
valve positions, and numbered fraction-collection spans — everything works
exactly as it does with a real instrument.*

## Starting demo mode

Start the app, click **Settings** in the top bar and switch on **Demo mode**. The
current log is closed, simulated data start straight away, and the status bar
shows a blue **DEMO** badge. Without demo mode and without an instrument, the app
simply waits for the instrument to be connected.

Demo data are logged to CSV exactly as a real run would be, so you can practise
the whole workflow including reopening and exporting results.

## What the demo does

The demo generates a repeating chromatogram — a gradient, a couple of peaks,
changing valve positions and fraction collection — at roughly ten times real
speed. Each simulated run ends after a number of fractions and the next one
begins automatically, which also demonstrates the
[per-run file roll-over](@ref "Multiple runs"): you will see the display clear
and a fresh log file start for each new run.

Everything else — zooming, toggling panels, switching between time and volume,
and saving figures — works just as it does with a real instrument.
