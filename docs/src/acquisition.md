# Acquisition

## Starting the software

Start the app from a terminal (see [Opening a terminal](@ref) if you are not sure
how to get a command prompt). If you have already set your serial port, just run:

```bash
AktaPrime
```

To use a specific serial port — or the first time you connect a new
instrument — give the port name:

```bash
AktaPrime /dev/tty.usbserial-110     # macOS
AktaPrime /dev/ttyUSB0               # Linux
AktaPrime COM3                       # Windows
```

The port you give is remembered for next time; it can also be changed later on
the [Settings page](@ref Settings).

When running from a copy of the source code, `./AktaPrime.sh` (Linux/macOS)
starts the app with the recommended options, and uses the
[system image](@ref "Faster start (system image)") when one has been built.

## Setting up the log files

When it starts, the app prints a short summary and asks for a **log-file
prefix**:

```
  Log-file prefix  (press ENTER for "akta"):
```

The prefix is just a label to help you find your files later — a sample name or
your initials work well. Press **ENTER** to keep the prefix you used last time.
Each run is then written to its own file in the **data folder**, named:

```
<prefix>_<date>_<time>.csv
```

for example `lysozyme_20260714_142530.csv`. The data folder is the folder you
started the app from, unless you choose another one under
[Settings](@ref Settings). Log files that never received any data (for example
when no instrument connected) are deleted automatically.

## The window

The window opens straight away and waits for the instrument. The **status bar**
at the bottom always shows:

- the **connection**: green when connected, amber while waiting for the
  instrument, red when the serial port is missing, blue in demo mode;
- whether data are being **recorded** (a blinking red **REC**), with the log
  file name and run time.

If the cable is unplugged or the instrument stops answering, the app keeps
trying and reconnects by itself — there is no need to restart it.

## Running the instrument

Operate the ÄKTA Prime from its **own front panel** as usual — AktaPrime.jl
watches and records, it does not drive the separation. As the run proceeds you
will see:

- the live chromatogram (UV, %B, conductivity, pH, pressure and the set flow);
- event markers and shaded, numbered fraction-collection spans;
- on the right, the **Run** and **Readings** cards and a live **flow-path
  schematic** with the injection valve and the 8-port buffer valve.

At the start of each run the instrument sends its method to the PC; the app
reads the starting state from it (for example which buffer-valve port is in
use), and later valve moves are reported by the instrument as they happen.

### Methods stored on the PC

While the app is connected, the instrument can use the PC as its method
store, as it did with PrimeView: save a method to the PC, and choose
**Run Stored Method → PC** to load one. Methods are kept in the `methods`
folder inside the data folder, one file per method number
(`PrimeMeth_001.txt` … `PrimeMeth_999.txt`, the same files PrimeView used), so
they can be copied between PCs. A method the instrument overwrites or deletes
is moved to `methods/old/` rather than lost. Saves, loads and deletions are
recorded in the run log.

### Method editor

Click **Methods** in the top bar to see the stored methods and edit them. The
list marks methods the instrument cannot load and the one it loaded last.

- **Name**: give a method a name to find it in the list. Names stay on the PC
  (in `methods/names.txt`) and are not sent to the instrument, which shows
  methods by number only.
- **Settings and breakpoints**: method and fraction base, pressure limit and
  alarm, and per breakpoint the volume, %B, flow, fraction size, buffer port,
  injection valve, peak threshold, autozero and event mark. Click a choice
  (ml/min, Load/Inj/Waste, Y/N) to step through its options; **+** adds a
  breakpoint below, **×** removes one.
- **The last breakpoint is the end of the method**; 99999.9 runs until stopped.
  A method needs at least two breakpoints, the first at 0.0, in increasing
  order. Bad values are outlined in red and listed under the table; a method
  is saved only when the instrument can load it.
- **Save** writes the method under its number, **Save as** under another one
  (replacing an existing number asks first), **Revert** discards changes.
  **New**, **Duplicate** and **Delete** work on the list; replaced and deleted
  versions are kept in `methods/old/`.
- To run a saved method, choose **Run Stored Method → PC** and its number on
  the instrument.

To prepare methods without the instrument, start only the editor (no serial
connection, no log file): `./AktaPrime.sh --methods`, or
`julia --project=. -m AktaPrime --methods`.

### Event marks

To note something during a run ("sample loaded", "changed buffer bottle"), type
a note in the box next to **Mark** (optional) and press **Mark** or Enter. The
mark is drawn into the plots and saved in the log.

## Run information

Click **Run info** in the top bar to record the sample, user, column and its
volume, the name of buffer B and of the buffers on each buffer-valve port, and
notes. **Save** records them in the log of the current run; they are kept for
the next runs, and every new log file starts with them. Buffer names appear in
the flow-path card, and the column volume enables plotting against
[column volumes](@ref "Choosing what to show").

## Settings

Click **Settings** in the top bar. Changes take effect immediately and are
remembered:

| Setting | |
|---|---|
| Demo mode | Simulated data instead of the instrument (see [Demo mode](@ref)). |
| Serial port | Device name, e.g. `/dev/ttyUSB0` or `COM3`; press Enter to reconnect. |
| Volume unit | **1 µL per count for an ÄKTAprime, 10 µL for an ÄKTAprime plus** — if volumes (and so flow rates) are 10× off, this is the setting to change. |
| Log file prefix | Prefix for new log files. |
| Data folder | Where log files and exported figures are saved. |
| Dark mode | Dark colour theme, from the next start. |
| Display refresh | How often live plots redraw (lower is lighter on the computer; data are always recorded in full). |
| Panels shown at start | Which plots are switched on when the app starts or a run is opened — e.g. untick pH without a pH electrode. |
| Save raw instrument data | For troubleshooting: also save every instrument message (`_raw.txt`) and method dumps (`.met`). |

## Multiple runs

You do not need to restart the app between runs. **When a new run begins, the
app automatically starts a fresh log file and clears the display**, so
successive runs never overwrite or draw over one another. Each run's data ends
up in its own `<prefix>_<date>_<time>.csv` file.

## Stopping

To stop, simply **close the window** (or press `Ctrl-C` in the terminal). The
current log file is closed cleanly, and the app prints where your data was
saved:

```
  Data saved in:
      /Users/you/akta_runs

  Most recent run: lysozyme_20260714_142530.csv
```
