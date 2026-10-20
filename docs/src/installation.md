# Installation

## Hardware requirements

You need three things:

1. A working **ÄKTA Prime plus** instrument.
2. A **computer** — any reasonably modern Windows, macOS or Linux machine.
3. A **USB-to-serial cable** to connect the two.

### The cable — get the chipset right

This is the single most important thing to get right, and the most common cause
of trouble.

The ÄKTA Prime is controlled over an **RS-232 serial** link through a 9-pin
(DB-9) port on the instrument. Modern computers no longer have a serial port, so
you connect through a **USB-to-serial (USB-to-RS-232) cable**.

!!! warning "Buy an FTDI cable, not a Prolific one"
    Use a cable built around the **FTDI FT232RL** chipset. **Avoid cables that
    use the PL2303 (Prolific) chipset** — they are cheaper but unreliable with
    this instrument and can be very difficult to get working, especially on
    Windows.

A cable confirmed to work well:

- **DTECH USB to Serial Adapter Cable with FTDI FT232RL Chipset, DB9 RS232 Male
  Port.**

This is a single cable — USB at the computer end, a 9-pin (DB-9) connector at
the instrument end. No separate serial cable or null-modem adaptor is needed.

The link runs at 9600 baud, 8 data bits, no parity, 1 stop bit; AktaPrime.jl
configures this for you.

### The computer

Any ordinary desktop or laptop is fine. A small, inexpensive mini-PC works well
and is easy to leave next to the instrument. A tested example:

- **Dell OptiPlex 3060** (8th-generation Intel Core i3-8100T, 8 GB RAM, 128 GB
  SSD) running **Windows 11 Pro** — works perfectly.

## Installing Julia

AktaPrime.jl runs on [Julia](https://julialang.org) version 1.12 or newer.

1. Install Julia — the easiest way is [`juliaup`](https://github.com/JuliaLang/juliaup),
   or download an installer from [julialang.org/downloads](https://julialang.org/downloads/).
2. Make sure the Julia application folder is on your `PATH`, so that installed
   apps can be run by name.

   **On macOS/Linux**, add this to your shell profile (`~/.bashrc`,
   `~/.zshrc`, …):

   ```bash
   export PATH="$HOME/.julia/bin:$PATH"
   ```

   **On Windows**, the folder is `%USERPROFILE%\.julia\bin` (for example
   `C:\Users\yourname\.julia\bin`). Add it to your PATH via **Start menu →
   "Edit environment variables for your account" → Path → New**, then paste that
   folder. Close and reopen any terminal window afterwards so the change takes
   effect.

## Installing AktaPrime

Start Julia, press `]` to enter the package manager, and install the app:

```julia
pkg> app add AktaPrime
```

This puts an `AktaPrime` command on your `PATH`. You can now run it from any
terminal. To update or remove it later:

```julia
pkg> app up AktaPrime
pkg> app rm AktaPrime
```

## Opening a terminal

AktaPrime.jl is started by typing a command in a terminal.

- **Windows** — open the **Start** menu, type `cmd`, and press Enter to open the
  **Command Prompt** (PowerShell works too). File paths on Windows use
  backslashes and a drive letter, e.g. `C:\Users\yourname\Documents`. To move
  into a folder, use `cd`, and if the folder is on a different drive, switch
  drive first:

  ```bat
  D:
  cd D:\akta_runs
  ```
- **macOS** — open **Terminal** (Applications → Utilities → Terminal).
- **Linux** — open your terminal application.

To check the app is installed and on your PATH, type `AktaPrime` and press Enter.

## Finding and setting the serial port

AktaPrime.jl talks to the instrument through a named serial port. You tell it
which port to use once, and it remembers your choice.

### Windows

1. Plug in the USB-to-serial cable and switch the instrument on.
2. Open **Device Manager** (Start menu → type "Device Manager").
3. Expand **Ports (COM & LPT)**. Your FTDI cable appears as something like
   **USB Serial Port (COM3)** — note the `COM` number.
   - If it does not appear, or shows a warning icon, install the FTDI driver
     (search for "FTDI VCP driver"). Genuine FTDI FT232RL cables normally work
     with the driver Windows installs automatically.
4. In a Command Prompt, start the app with that port:

   ```bat
   AktaPrime COM3
   ```

### Linux

1. Plug in the adaptor, then list serial devices:

   ```bash
   ls /dev/ttyUSB*      # USB-to-serial adaptors
   ls /dev/ttyS*        # built-in serial ports
   ```

   If unsure which appeared, run `dmesg | tail` right after plugging it in.
2. Start the app with that device:

   ```bash
   AktaPrime /dev/ttyUSB0
   ```

   If you get a permissions error, add yourself to the `dialout` group
   (`sudo usermod -a -G dialout $USER`) and log out and back in.

### macOS

1. List serial devices:

   ```bash
   ls /dev/tty.usbserial-*
   ```
2. Start the app with that device:

   ```bash
   AktaPrime /dev/tty.usbserial-XXXX
   ```

Once set, the port is saved as a preference, so on subsequent runs you can just
type `AktaPrime`. It can also be changed at any time on the
[Settings page](@ref Settings).

## Faster start (system image)

Julia compiles code the first time it is used, so the first start of the app —
and the first use of some features — takes a while (around 20–30 s to a usable
window). When running from a copy of the source code, a **system image** with
everything precompiled cuts this to a few seconds:

```bash
julia --project=sysimage sysimage/build.jl     # once; takes 10–20 minutes
./AktaPrime.sh                                 # then start the app with it
```

`AktaPrime.sh` uses the image automatically. Rebuild it after updating the code
or packages: if the code is newer than the image, `AktaPrime.sh` says so and
starts without it, so changes are never silently ignored.
