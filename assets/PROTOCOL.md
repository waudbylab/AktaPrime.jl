# AKTA Prime RS-232 Protocol Specification

Reverse-engineered from `p232_drv.exe`, `Orqoci.dll`, `Comiface.dll`,
`Oci.exe`, `AInstrInfo.dll`, and `Caktacal.dll`
(UNICORN AKTA Prime software stack, Windows 95 vintage).

---

## Process architecture

The UNICORN software stack involves three Windows processes and several DLLs:

```
Csyscon.exe (PrimeView GUI)
  ├── Comiface.dll   thin wrapper over Orqoci
  └── Orqoci.dll     OCI protocol client, named pipe client

Oci.exe (OCI server)
  ├── Orqoci.dll     OCI protocol, named pipe server creation
  ├── AInstrInfo.dll instrument hardware detection and parameter tables
  ├── Caktacal.dll   calibration computation
  └── Slstinfo.dll   strategy/instrument definition tables

p232_drv.exe (serial driver, child of Oci.exe)
  └── Orqoci.dll     pipe client utilities (olnOpen, olnSendData etc.)
```

`Oci.exe` creates the named pipe servers and launches `p232_drv.exe` as a
child process. `Csyscon.exe` and up to 8 other UNICORN clients connect as
pipe clients. `p232_drv.exe` also connects as a pipe client to the same
servers, forwarding RS-232 data upstream and receiving commands downstream.

### Named pipes (created by Oci.exe via olnCreate / CreateNamedPipeA)

| Pipe name | Direction | Purpose |
|---|---|---|
| `\\.\<id>\PIPE\LREQ<n>` / `\\server\PIPE\RREQ<n>` | bidirectional | Synchronous request/response |
| `\\.\<id>\PIPE\LMANUAL<n>` / `\\server\PIPE\RMANUAL<n>` | OCI→p232 | Manual/text commands |
| `\\.\<id>\PIPE\LONLINE<n>` / `\\server\PIPE\RONLINE<n>` | p232→OCI | Asynchronous event stream |

`<n>` is the system index (0-3). The `L` prefix is used by p232_drv.exe
(local), `R` by UNICORN clients (remote). Up to 8 simultaneous client
connections are supported; each has its own RREQ/RMANUAL/RONLINE triplet.

### Internal Oci.exe threads

| Thread | Pipe/queue | Role |
|---|---|---|
| `ooc_thdRequest` × 8 | RREQ server | Dispatches all OCI commands (0x44d-0x494) |
| `ooc_thdOnline` × 8 | OONLXY mailslot → RONLINE | Forwards events to each UNICORN client |
| `ooc_thdManual` × 8 | RMANUAL server | Receives manual commands from UNICORN |
| `oic_thdOnline` × 1 | LONLINE server + ONLINEX mailslot | Bridges p232_drv ↔ all client threads |
| `oic_Update` | timer | Periodic state updates |
| `oevEventEval` | event queue | Evaluates method triggers |
| `obaBackup` | timer | Periodic data backup |

### Internal p232_drv.exe threads

| Thread | Purpose |
|---|---|
| `thdRequest` | LREQ pipe -- handles 8 OCI commands from Oci.exe |
| `pocManualPipeHandler` | LMANUAL pipe -- relay stub (discards payloads for Prime) |
| `thdEvent` | ONLINEX mailslot → LONLINE -- forwards events upstream |
| `thdControl` | Connection state machine |
| `thdLinklayer` | RS-232 poll loop |
| `thdDebug` | Interactive console (debug level > 0) |

---

## Startup sequence

### Oci.exe startup (from `_main`)

1. Sets process to `HIGH_PRIORITY_CLASS`, disables priority boost.
2. Parses system index from argv (`olbGetArg`).
3. Reads `UNICORN.INI` into the `_OCI_ENVIRONMENT` shared memory block
   via `orlReadInitFile`, populating all file paths.
4. Polls `orqGetSystemTable` every 30 seconds until it finds a system table
   entry of type `"AKTAprime"` matching the system index. Waits indefinitely.
5. Verifies strategy file paths are accessible.
6. Creates startup semaphore `OCI_STARTUPSEM` to serialise multiple Oci.exe
   instances.
7. Calls `olbCopyFilesFromServer()` to sync strategy files from server to
   local path.
8. Calls `StartDriver()` which launches `p232_drv.exe <system_id> <comport>`
   as a child process.
9. Creates the STATUS mailslot `\\\\.\\MAILSLOT\\OSTAT<n>`.
10. Creates mutexes: `hmtxManual`, `hmtxRequest`, `hResFileSem`, `hFileSem`,
    `hevBackupSem`.
11. Initialises: database (`odbInit`), message list (`olmInitiateMsgList`),
    logbook (`olgInitiateLgb`), trend storage (`omnInitiateTrend`).
12. Calls `olbInit(&strategy_path)`:
    - `olbLoadStrategy`: loads method/strategy file from disk.
    - `ostLoadDb`: loads instrument database from `AInstrInfo.dll`.
    - `ostAppendStrategy`: merges strategy into instrument database.
    - `omnPrepareTrend`: allocates trend curve storage.
    - `omnSetXUnits`: sets time/volume X-axis units.
    - `ostSetupCurves`: configures data curve descriptors.
    - `oflLoadSpec`: loads saved instrument settings (CONFIG file),
      calling `oflLoadDefaults` to build the `_OCI_MAN_INSTR` list
      from the instrument database filter table.
    - `oflExecuteSpec`: applies settings to instrument via `orsSubmitMC`.
13. Launches 8 × (`ooc_thdManual`, `ooc_thdOnline`, `ooc_thdRequest`).
14. Launches `oic_thdOnline`.
15. **Sleeps 7 seconds** to allow `p232_drv.exe` to initialise.
16. Launches `oic_Update`, `oevEventEval`, `obaBackup`, `serverAccessCheck`.
17. Enters the main status loop reading STATUS mailslot event codes.

### p232_drv.exe startup

1. Parses system index and COM port from argv.
2. Opens COM port at 9600/8N1 via `openSerialPort`.
3. Connects to Oci.exe's named pipe servers via `olnOpen` (CreateFileA):
   LREQ, LMANUAL, LONLINE.
4. Starts threads: `thdRequest`, `pocManualPipeHandler`, `thdEvent`,
   `thdControl`, `thdLinklayer`.
5. `thdLinklayer` begins polling the COM port with RR frames `#0S<cs>\r`.

### Instrument connection

The connection process involves three threads -- `thdLinklayer`,
`thdControl`, and `mainControlLoop` -- communicating via mailslots.

**Step 1 -- `thdLinklayer`: SNRM/UA exchange**

`thdLinklayer` sends SNRM frames `#0S5\r` at ~100ms intervals until the
instrument replies with UA `#1uX\r`. On receiving a valid 5-byte frame with
ctrl byte `0x75`:

```
sn = 0; rn = 0; connected = true; pending_tx = 0; idle_ms = 0
write status 2 → RX_UPLOADX mailslot
```

**Step 2 -- `thdControl`: linklayer-connected response**

`thdControl` reads status `2` from RX_UPLOADX:

```
DAT_00418068 = 1           (linklayer active flag)
write status 0x11 → STATUSX mailslot
write {OPC=0x1001, nob=1, data=0x00} → TX_DWNLOADX   ← disconnect (bVar2=false)
```

The `0x1001/{0x00}` is a disconnect command. `bVar2` is `false` by default
so the first frame after UA is always a disconnect. The instrument ignores
it as it is not yet connected.

**Step 3 -- `mainControlLoop`: gate check**

`mainControlLoop` reads status `0x11` (AKTAprime connected) from STATUSX.
It then evaluates a gate -- all of these must be true before proceeding:
manual pipe connected, request pipe connected, event pipe connected,
linklayer connected, Prime connected, AND system control connected
(`local_2fc`, set when command `0x486` is received from Oci.exe). If the
gate passes:

```
write status 4 → RX_UPLOADX   (connect signal)
```

**Step 4 -- `thdControl`: real connect**

`thdControl` reads status `4` from RX_UPLOADX:

```
bVar2 = true
write {OPC=0x1001, nob=1, data=0x01} → TX_DWNLOADX   ← real connect
```

**Step 5 -- `thdLinklayer`: transmit connect I-frame**

On the next loop iteration, `buildTxFrame` reads the `0x1001/{0x01}` message
from TX_DWNLOADX, encodes it as an I-frame, and `writeFrameReadReply`
transmits it. The instrument responds with `0x8001` (program name) and
`0x8002` (version). `thdControl` then posts STATUS event `0x11` (AKTAprime
connected) and writes event `0x3ed/7/0` to the ONLINEX mailslot to signal
upstream to Oci.exe that the instrument is ready.

**Summary: two `0x1001` frames are sent after UA:**

```
PC → instrument: 0x1001/{0x00}  (immediate, ignored by instrument)
PC → instrument: 0x1001/{0x01}  (after all pipes ready, triggers response)
```

**For a standalone Julia driver** (no Oci.exe pipe infrastructure), the
gate condition is never checked -- simply send `0x1001/{0x01}` directly
after receiving UA, with no preceding disconnect frame needed.

### UNICORN client connection (PrimeView)

PrimeView (`Csyscon.exe`) is a **monitoring-only client**. It calls
`comConnectSystem` and `comStartEventReciever` to receive data, but never
calls `comAppendManualString`, `comSetSystemState`, `comSetSystemSettings`,
or any other command-sending function. The only instrument command it ever
sends is `comSubmitManualCommand(2, 0, 0, NULL, "Run started")` -- and only
in the specific case of connecting in AKTAxpress run mode, which is
not normal monitoring. In all normal use, PrimeView sends nothing to the
instrument and only receives events.

```
comConnectSystem(server, system_name)
  → orqPipeAssignSystem
    → olnOpen(RREQ)     connects to ooc_thdRequest in Oci.exe
    → olnOpen(RMANUAL)  connects to ooc_thdManual
    → olnOpen(RONLINE)  connects to ooc_thdOnline
    → SendData(0x468, computer_name)  stored by ooc_thdRequest
    → SendData(0x468, system_name)    stored by ooc_thdRequest

comStartEventReciever(hwnd)
  → comEventReceiverThread (loops forever)
    → orqPipeReceiveEvent reads RONLINE
    → dispatches to UNICORN window as Windows messages:
        0x3eb → PostMessage(0x83eb)   sensor reading
        0x3ea → PostMessage(0x83ec)   run info event
        0x3ed/3 → PostMessage(0x83ed) run state update
        0x3ed/7 → PostMessage(0x83f0) system availability
```

---

## Trend channel monitoring setup (command 0x484)

Sent by `orsSetCurveInformation` immediately after linklayer connects.
Fixed 16-entry table (0x160 bytes), entries 9-16 are instrument-specific:

| Index | Channel ID | Signal name | Scale code |
|---|---|---|---|
| 0 | 0 | `UV` | 6 |
| 1 | 1 | `COND` | 3 |
| 2 | 2 | `PH` | 2 |
| 3 | 5 | `B` | 1 |
| 4 | 3 | `PRESS` | 3 |
| 5 | 4 | `TEMP` | 1 |
| 6 | 0x3f3 | `INJECT` | — |
| 7 | 0x3f4 | `TUBEFEED` | — |
| 8-15 | 0xffff | instrument-specific | — |

Each entry is `(threshold: int16, name: char[8], padding: int16)` = 11 bytes.
Channel IDs are database object IDs used internally by Oci.exe.

---

## OCI command dispatch (ooc_thdRequest complete table)

`ooc_thdRequest` serves all UNICORN client requests. Commands that need the
RS-232 link are proxied to p232_drv.exe via hPipeLRequest when
`DAT_004908c6 == 1` (driver connected); otherwise error 8 is returned.

| Code | Name | Handled by |
|---|---|---|
| `0x44d` | LoadCalibration | `orsLoadCalib` (Oci.exe, from Caktacal.dll data) |
| `0x44e` | StoreCalibration | `orsStoreCalib` |
| `0x44f` | LoadSpec | `orsLoadSpec` (instrument settings from CONFIG file) |
| `0x450` | StoreSpec | `orsStoreSpec` |
| `0x453` | GetStrategyPath | returns local strategy path string |
| `0x454` | GetLocalFiles | `orsGetLocalFiles` |
| `0x455` | GetCurveData | `orsLoadCurve` |
| `0x456` | GetAllNumData | `orsGetDataBase` |
| `0x458` | GetCURunStatus | `orsGetCURunStatus` |
| `0x459` | GetNetStatus | `orsGetNetStatus` |
| `0x45a` | GetActiveAlarms | `orsGetActiveAlarms` |
| `0x45b` | AcknowledgeAlarm | `orsSetAckAlarm` |
| `0x45c` | SetSystemState | `orsSetSystemState` → proxied to p232_drv if connected |
| `0x45d` | GetSystemState | `orsGetSystemState` → serves cached `_OCI_STATE` at `DAT_0049101e` |
| `0x45e` | GetNodeDescr | `orsGetNodeDescr` |
| `0x45f` | ChangeStrategy | `orsChangeStrategy` |
| `0x460` | GetDriverInfo | proxied to p232_drv |
| `0x462` | ManInstrList | `orsManInstrList` → serves `_OCI_MAN_INSTR` list from memory |
| `0x463` | GetCurrentSubMethod | `orsGetCurrentSubMethod` |
| `0x464` | GetCurrentRunNotes | `orsGetCurrentRunNotes` |
| `0x465` | SetRunNotes | `orsSetRunNotes` |
| `0x466` | SetBackupInterval | `orsSetBackupInterval` |
| `0x467` | RecoverData | `orsRecoverData` |
| `0x468` | Handshake | stores computer name + system name (two calls) |
| `0x469` | Disconnect | clears client registration, broadcasts disconnect |
| `0x46a` | SetRunInfo | `orsSetRunInfo` |
| `0x46b` | GetRunInfo | `orsGetRunInfo` |
| `0x46c` | Shutdown | `olbByeBye` (shuts down Oci.exe) |
| `0x46e` | GetMethodStrings | `orsGetMethodStrings` |
| `0x46f` | AcknowledgeError | `orsSetAckError` |
| `0x470` | GetCurrentUsers | `orsGetCurrentUsers` |
| `0x471`-`0x476` | Audit trail operations | `oauRenewSystemLogFile` etc. |
| `0x477` | GetInstrumentStatus | `orsGetInstrumentStatus` |
| `0x478` | AppendManualString | `orsAppendManualString` → text command to instrument |
| `0x479` | ExclCompListChanged | `orsExclCompListChanged` |
| `0x47a`-`0x47e` | GetEventList/Units/PosNames/InstrList/Groups | various `ors*` |
| `0x47f` | GetTuneList | `orsGetTuneList` |
| `0x480` | GetMultinetCalibList | `orsGetMultinetCalibrationList` |
| `0x481` | GetAKTACalibList | `orsGetAKTACalibrationList` (from strategy struct) |
| `0x482` | GetGlobalStruct | `orsGetGlobalStruct` |
| `0x483` | GetNetStatus (alt) | proxied to p232_drv |
| `0x484` | not served here | (sent downstream to p232_drv by Oci.exe internally) |
| `0x485` | GetInstrumentIdentity | proxied to p232_drv |
| `0x487` | SetMsgConfirmed | `orsSetMsgConfirmed` |
| `0x488` | GetIsDriverCU950 | `orsGetIsDriverCU950` |
| `0x48a`-`0x48d` | Various proxied requests | proxied to p232_drv |
| `0x48e` | GetIsDataUploading | `orsGetIsDataUploading` |
| `0x48f` | GetTopSubMethod | `orsGetTopSubMethod` |
| `0x490` | RemoveMsg | `olmRemoveMsg` |
| `0x491` | GetAuthorizeMessages | `orsGetAuthorizeMessages` |
| `0x492` | GetIsConnectionUSB | `orsGetIsConnectionUSB` |
| `0x493` | EnableStoringArray | `oic_EnableStoringArray` |
| `0x494` | SetManInstConfirmed | `orsSetManInstConfirmed` |

Commands served entirely from Oci.exe memory (no RS-232 needed):
`0x44d`-`0x45b`, `0x45d`-`0x46b`, `0x46c`-`0x481`, `0x487`-`0x494`.

---

## State and calibration data sources

### `_OCI_STATE` (0xce bytes, cached at `DAT_0049101e`)

Updated in-place by `oevDispatchEvent` processing `0x3ea` events from
p232_drv.exe. `orsGetSystemState` (command `0x45d`) serves this cached
value directly without any RS-232 transaction. The state reflects the most
recent `0x2003` RunState frame received from the instrument.

### `_OCI_RUNINFO` (0x3c7 bytes)

Built from `0x3ea` events and stored in the strategy global struct.
`orsGetRunInfo` (command `0x46b`) serves from the same cache.

### `_OCI_MAN_INSTR` list (0x79c bytes/node, linked list)

Built by `oflLoadDefaults` from the instrument filter table (populated by
`AInstrInfo.dll` via `ostLoadDb`). Each node describes one controllable
instrument parameter. Layout:

| Offset | Size | Field |
|---|---|---|
| 0x00 | 2 | control type (0=strategy instr, 2=CU setting) |
| 0x02 | 4 | instruction ID (strategy instr ID, or 0x9c3e for filter) |
| 0x0c | 12×0x0c | parameter slots (type, value, modifier, handle each) |
| 0xb4 | 2 | parameter count |
| 0xb6 | 1757 | display name string |
| 0x774 | 30 | pipe/target name string |
| 0x792 | 2 | status flags |
| 0x794 | 4 | current value handle |
| 0x798 | 4 | next pointer |

`orsManInstrList` (command `0x462`) streams this list to the client.

### `_sliCALIB2` calibration list (0x2ce bytes/node)

Stored at strategy global offset `0x1dc3`. Built by `oflLocalCalib` and
`oflExecuteCalib` during `olbInit`. Each node layout (from `Caktacal.dll`
`CalibParameters`):

| Offset | Size | Field |
|---|---|---|
| 0x00 | 2 | type (calib_type + 10) |
| 0x02 | 2 | channel_id |
| 0x04 | 30 | channel_name string |
| 0x22 | 20 | calibration date string |
| 0x36 | 20 | calibration time string |
| 0x4a | 30 | operator name string |
| 0x5e | 2 | calibration method (0=factory, 1=user) |
| 0x60 | 4 | float: low reference value |
| 0x64 | 4 | float: high reference value |
| 0x86 | 8 | double: coefficient A (slope) |
| 0x8e | 8 | double: coefficient B (offset) |
| 0x96 | 8 | double: coefficient C (quadratic term, if used) |
| 0x1c6 | 4 | heap pointer to channel name string |
| 0x2c6 | 4 | next pointer |

Calibration type values (`_sliCALIB2[0x89]`, from `Caktacal.dll`):

| Type | Sensor |
|---|---|
| 2 | UV/conductivity single-point (slope only) |
| 3 | UV two-point (offset + slope) |
| 4 | Conductivity two-point variant |
| 5 | Pressure |
| 6 | pH |
| 7 | Temperature |
| 8 | Fraction collector sensor |

**Important:** the AKTA Prime instrument applies calibration internally in
its own firmware. The values arriving in `0x2001` TrendDelta frames are
already in calibrated engineering units (mAU, mS/cm, MPa, °C etc.) --
confirmed by the fact that PrimeView displays the same values as the
instrument's own LCD panel without applying any further transformation.
The `scale_code` values (6/3/2/1) in `0x3eb` events indicate only the
number of implied decimal places for display purposes, not a calibration
factor. The `_sliCALIB2` data held by Oci.exe is used only by the
UNICORN calibration wizard UI and is not part of the monitoring data path.

---

## Hardware detection (AInstrInfo.dll)

Called during `ostLoadDb` to enumerate physically connected modules.
Sends command `0x1a` (26) via `comSubmitManualCommand` with 5 `_OCI_MAN_PARM`
elements. Module type codes in parameter[4]:

| Code | Module |
|---|---|
| 4 | Pump P-900 |
| 5 | UV-900 (UV detector variant) |
| 6 | UV detector |
| 0x17 | Valve |
| 100 | Additional module (CU950 only) |
| 0x65-0x69 | Further CU950 module slots |

Instrument responds with OPC `0x514` (1300) in the RS-232 I-frame, carrying
firmware version strings. `aiiDecodeInstrAnswer` parses these and stores
them in the instrument descriptor struct at various `CString` fields
(offset `+0x44` for UV, `+0x48` for pump, `+0x50` for CU identity etc.).

For a standalone AKTA Prime driver, hardware detection can be skipped --
the instrument begins sending trend data after receiving `0x1001` connect
and `0x484` channel setup regardless.

---

## Data flow: RS-232 to PrimeView display

```
AKTA Prime  ──OPC 0x2001 I-frame──►  thdLinklayer (p232_drv.exe)
                                          │ decodes 6-bit payload
                                          │ calls handleTrendData
                                          │ calls packageSensorReading
                                          ▼
                                      ONLINEX mailslot (0x3eb, 0x11a bytes)
                                          │
                                          ▼
                                      thdEvent (p232_drv.exe)
                                          │ reads ONLINEX
                                          │ forwards via LONLINE pipe
                                          ▼
                                      oic_thdOnline (Oci.exe)
                                          │ oic_ProcessMessage
                                          │ omnAddContSamples (database)
                                          │ checks queue depth < 600
                                          ▼
                                      OONLXY mailslot per client (0x3eb)
                                          │
                                          ▼
                                      ooc_thdOnline × N (Oci.exe)
                                          │ reads OONLXY
                                          │ writes via RONLINE pipe
                                          ▼
                                      orqPipeReceiveEvent (Orqoci.dll)
                                          │ in comEventReceiverThread
                                          ▼
                                      PostMessage(0x83eb) → PrimeView window
```

---

## RS-232 physical layer

- **Baud rate:** 9600
- **Format:** 8N1
- **Flow control:** none
- **Port:** COM1-COM4
- **Write timeout:** 30ms + 2ms/byte
- **Read timeout:** 500ms

---

## RS-232 frame format

All frames are printable ASCII. Every frame:

```
# <addr> <ctrl> <payload...> <checksum> CR
```

- `#` (0x23): start
- `addr` (1 byte): `'0'` (0x30) in PC-originated frames; `'1'` (0x31) in instrument-originated frames
- `ctrl` (1 byte): frame type and sequence numbers
- `checksum`: see below
- `CR` (0x0d): end

### Checksum

Computed over all bytes between `#` and the checksum byte (i.e. `addr`,
`ctrl`, and any payload bytes -- excluding `#` itself and the trailing
checksum+CR). For a 5-byte frame `[# addr ctrl cs CR]` this is 2 bytes.

The accumulator is `UInt8` -- addition wraps at 8 bits throughout, with no
sign extension and no widening to 16 or 32 bits before the shift.

```
sum::UInt8 = Σ(bytes)                  # wrapping uint8 addition
checksum = ((sum + (sum >> 6)) & 0x3f) + 0x30
```

In Julia: `((sum(bytes) % UInt8 + (sum(bytes) % UInt8 >> 6)) & 0x3f) + 0x30`

Validation (`validateRxFrame`): checksum covers `len - 3` bytes starting at
position 1 of the received buffer (addr onward, excluding `#`, checksum, CR).

**Worked examples:**

PC SNRM: `0x30 + 0x53 = 0x83`; `(0x83 + 0x02) & 0x3f + 0x30 = 0x35` = `'5'`

Instrument UA: `0x31 + 0x75 = 0xa6`; `(0xa6 + 0x02) & 0x3f + 0x30 = 0x58` = `'X'`

### Frame types (ctrl byte before +0x30 encoding)

| ctrl | Type | Originator | Description |
|---|---|---|---|
| `0x53` (`'S'`) | SNRM | PC | PC sends this continuously until instrument replies. |
| `0x75` (`'u'`) | UA | Instrument | Instrument sends in reply to SNRM. Both sides reset SN=RN=0. |
| `(ctrl & 0xfc) == 0x30` | RR | PC | Receive Ready / ack. `RN = ctrl & 0x03`. |
| `(ctrl & 0xf0) == 0x40` | I-frame | Either | Data. `SN = (ctrl>>2) & 0x03`, `RN = ctrl & 0x03`. |

I-frame ctrl: `((SN & 3) | 0x10) << 2 | (RN & 3)`
RR ctrl: `(RN & 3) | 0x30`

**Non-standard RN convention.** The RN field encodes the SN of the
**last successfully received** I-frame, NOT the next expected SN as in
standard HDLC. After receiving an I-frame with SN=1, the correct ACK is
RN=1 (not RN=2). The instrument likewise acknowledges the PC's connect
I-frame (SN=0) by sending RN=0 in its first response frame.

From `thdLinklayer` (confirmed in `buildAckFrame`):
```
# rn tracks the SN of the last received I-frame
if received_SN == (rn + 1) & 3:
    rn = received_SN           # update to last-received
# ACK sends rn directly -- not rn+1
RR ctrl = (rn & 3) | 0x30

# PC's pending_tx clears when instrument's RN matches PC's last-sent SN
if sn == (received_ctrl & 3):
    pending_tx = 0
```

Sequence numbers are mod-4.

Predefined frames (with computed checksums):
- **SNRM** (PC→instrument): `#0S5\r` (`23 30 53 35 0D`)
- **UA** (instrument→PC): `#1uX\r` (`23 31 75 58 0D`)
- **RR/Poll** (PC→instrument): `#0<RN+0x30><cs>\r` where cs covers `0x30` and the ctrl byte

### 6-bit ASCII payload encoding

```
encoded = (value & 0x3f) + 0x30
```

Multi-byte integers, little-endian, 3 chars per 2 bytes:
```
c[0] = ( byte[0]        & 0x3f) + 0x30
c[1] = ((byte[1] & 0x0f) << 2 | byte[0] >> 6) + 0x30
c[2] = ( byte[1]        >> 4 ) + 0x30
```

### OPC message header (4 encoded chars at start of I-frame payload)

| Char | Field |
|---|---|
| 0 | nob-derived: binary OPC: `((nob>>1)+0x10)*3 + (nob&1)*2`; ASCII OPC: `nob+0x30` |
| 1 | `(OPC & 0x3f) + 0x30` |
| 2 | `((OPC>>6) & 0x3f) + 0x30` |
| 3 | `(OPC>>12) + 0x30` |

---

## Method store

Verified 2026-10 from the disassembly of UNICORN 5.31's `Bin/p232_drv.exe`
("ÄKTAprime Driver", build 743); implemented in `src/methodstore.jl`. The table
rows `0x2007`–`0x2020` and `0x8008`–`0x8011` below replace earlier guesses.

The PC is a numbered file store for the instrument's "save to PC" and "Run
Stored Method → PC". Method n is the text file `PrimeMeth_NNN.txt` (n = 1–999).
All numbers are little-endian.

- **Text messages** carry at most 34 characters. A load sends each line of the
  file without its line end, skipping empty lines: `0x8008` for a whole line,
  otherwise `0x8009`, `0x8010`…, `0x8011`. A line over 99 characters aborts the
  load with `0x2014 [02]`.
- **Escaping** (all method text; `#` would start a frame): `zy` = `#`;
  `z`+c = c for c in `z { | } ~`; `~` = CR; `}` = CR LF; `|`+n = n spaces and
  `{`+n = n `*` (n = count + `'0'`, runs of 2–60).
- **Save**: `0x2009 [n]`, text, `0x2010` → `0x2011 [1]`. The decoded text is the
  file. **Dump**: `0x2007`, text, `0x2008` — same text format, not stored.
- **List** `0x2015 [start, dir]` → `0x2016`: the first ten existing numbers from
  `start` up or down; a start outside 1–999 lists nothing.

---

## Instrument opcodes

### Host → instrument

| OPC | nob | Name |
|---|---|---|
| `0x1001` | 1 | Connect: `{0x01}`=connect, `{0x00}`=disconnect |
| `0x2011` | 1 | Method save result: 1 saved, 0 not saved |
| `0x2013` | 0 | Method load begins (lines follow as `0x8008`–`0x8011`) |
| `0x2014` | 1 | Method load end: 0 OK, 1 no such method, 2 error |
| `0x2016` | 20 | Method list: 10 × u16 method numbers, `0xFFFF` = empty slot |
| `0x2018` | 1 | Method delete result: 1 deleted, 0 not |
| `0x2020` | 1 | Method exists: 1 yes, 0 no |
| `0x8008`–`0x8011` | n | Method text of a load (see *Method store* below) |
| `0x8003` | n | Text command (ASCII, see encoding below) |

### Instrument → host

| OPC | nob | Name |
|---|---|---|
| `0x2001` | 14 | TrendDelta |
| `0x2002` | 8 | TrendAbsolute (base time/volume) |
| `0x2003` | 10 | RunState |
| `0x2004` | 8 | Inject event |
| `0x2005` | 10 | TubeFeed event |
| `0x8001` | n | Program name |
| `0x8002` | n | Program version |
| `0x2007` / `0x2008` | 0 / 1 | Method dump begin / end (method report before a run) |
| `0x2009` | 2 | Method save begin: u16 method number |
| `0x2010` | 0 | Method save end (host answers `0x2011`) |
| `0x2012` | 2 | Load method: u16 number (host answers `0x2013` … `0x2014`) |
| `0x2015` | 3 | List methods: u16 start number, u8 direction (≠0 = up), start inclusive (host answers `0x2016`) |
| `0x2017` | 2 | Delete method: u16 number (host answers `0x2018`) |
| `0x2019` | 2 | Does method exist: u16 number (host answers `0x2020`) |
| `0x8008` | n | Method text: one whole line (dump, save) |
| `0x8009`/`0x8010`/`0x8011` | n | Method text: first / middle / last part of a long line |
| `0x800b`/`0x800c` | n | Log message chunks |
| `0x514` | n | Hardware detection response |
| `0xfffd` | n | Debug text |

---

## Payload decoding

All offsets from the start of decoded binary payload data.
Multi-byte integers are little-endian.

### OPC `0x2002` -- TrendAbsolute (8 payload bytes)

| Bytes | Field | Units |
|---|---|---|
| 0..3 | base_time (uint32) | ×10ms ticks |
| 4..7 | base_volume (uint32) | ×0.1µl |

### OPC `0x2001` -- TrendDelta (14 payload bytes)

| Bytes | Channel | Extraction | Scale | Engineering unit |
|---|---|---|---|---|
| 0 | time_delta | uint8, add to base_time | — | ×10ms |
| 1 | volume_delta | uint8, add to base_volume | — | ×0.1µl |
| 2..4 | UV | `(p[4]<<16\|p[3]<<8\|p[2])` sign-extended from bit 23 | 6 | AU (÷1,000,000) |
| 5..7 | Conductivity | `p[7]<<16\|p[6]<<8\|p[5]` (unsigned) | 3 | mS/cm (÷1,000) |
| 8..9 | pH | `(p[9]&0x07)<<8\|p[8]` | 2 | pH (÷100) |
| 9..10 | Temperature | `(p[10]&0x1f)<<5\|(p[9]>>3)` | 1 | °C (÷10) |
| 10..11 | Pressure | `p[11]*8 + (p[10]>>5)` | 3 | MPa (÷1,000) |
| 12..13 | Flow/inject | `(p[13]&0x07)<<8\|p[12]` minus 100 | 1 | ml/min (÷10) |

Scale code = implied decimal places: divide raw by `10^scale` for SI unit.
Entries 8-15 in the channel table may provide additional channels
depending on instrument hardware configuration.

### OPC `0x2003` -- RunState (10 payload bytes)

| Bytes | Field | Extraction |
|---|---|---|
| 0..2 | run_time | `(p[2]<<16\|p[1]<<8\|p[0]) / 10` → ms |
| 3..5 | run_volume | `(p[5]<<16\|p[4]<<8\|p[3]) / 10` → µl |
| 6 | state | 0=End, 1=Run, 2=Pause, 3=Hold, 4=Continue |
| 7..9 | second_volume | `(p[9]<<16\|p[8]<<8\|p[7]) / 10` → µl |
| 13 (byte offset) | inject_active | non-zero if inject valve open |

### OPC `0x2004` -- Inject (8 bytes)

| Bytes | Field | Extraction |
|---|---|---|
| 0..3 | inject_time | `(p[3]<<24\|p[2]<<16\|p[1]<<8\|p[0]) / 10` → ms |
| 4..7 | inject_volume | `(p[7]<<16\|p[6]<<8\|p[5]) / 10` → µl |

### OPC `0x2005` -- TubeFeed (10 bytes)

| Bytes | Field | Extraction |
|---|---|---|
| 0..3 | feed_time | `(p[3]<<24\|p[2]<<16\|p[1]<<8\|p[0]) / 10` → ms |
| 4..7 | feed_volume | `(p[7]<<16\|p[6]<<8\|p[5]) / 10` → µl |
| 8..9 | tube_params | `p[9]<<8\|p[8]` |

---

## Text command encoding (OPC `0x8003`)

Pre-processing before 6-bit encoding:

| Input | Wire | Meaning |
|---|---|---|
| `\r` | `~` | Command terminator |
| `\n` | `}` | Line feed |
| `#` | `zy` | Escaped frame delimiter |
| N spaces | `\|N` | Run-length (N ≤ 60) |
| N `*` | `{N` | Run-length |
| char ≥ `z` | `z` + char | Escape |

---

## Upstream event stream (0x3ea, 0x3eb, 0x3ed)

### `0x3eb` -- sensor reading (0x11a bytes)

Written by `packageSensorReading`, forwarded by `thdEvent` and `oic_thdOnline`.

| Offset | Size | Field |
|---|---|---|
| 0x00 | 2 | threshold (from SetTrendChannels) |
| 0x02 | n | signal_name (null-terminated, e.g. `UV\0`) |
| 0x16 | 2 | has_scale (1 if scale_code ≠ 0) |
| 0x1c | 2 | scale_code |
| 0x1e | 4 | current_time (base+deltas / 10, 100ms units) |
| 0x2a | 4 | raw_value |
| 0x2e | 4 | current_volume (base+deltas / 10, µl) |

### `0x3ea` -- run/inject/state event (0xda bytes)

Written by `handleRunState`, `handleInjectTubefeed`.

| Offset | Size | Field |
|---|---|---|
| 0x00 | 4 | system_id |
| 0x02 | 2 | run_active (1 if run in progress) |
| 0x04 | 2 | padding |
| 0x06 | 4 | oci_state_code (6=End, 2=Run, 3=Pause, 4=Hold, 5=Continue) |
| 0x08 | 2 | oci_state_flags |
| 0x0a | 4 | inject_active |
| 0x0e | 4 | run_time_ms |
| 0x28 | 4 | run_volume_ul |

### `0x3ed` -- system state (0x7b7 bytes)

First uint32 of payload is sub-type:

| Sub-type | Meaning |
|---|---|
| 7 | System availability/connection state (value[1]: 0=connected, 1=disconnected) |
| 3 | Run info update |
| 0xc | Log message with timestamps |
| 0x14 | System control disconnected |
| 0x1c | AKTA Prime result initiation |

---

## p232_drv.exe command-line syntax

```
P232_drv <system> [<port>] [<debug>] [<filedebug>]

  system    0-3    system index
  port      com1-4 (default: com1)
  debug     0-9    console verbosity
  filedebug 0-9    file verbosity (Prime\PrimeDebug.txt)
```

### Debug levels

| Level | Content |
|---|---|
| 1 | Errors |
| 2 | Status |
| 3 | Instrument debug messages |
| 4 | All instrument messages |
| 5 | Trend data |
| 6 | Linklayer OPC and data |
| 7 | Frame data (no poll) |
| 8 | All frame data |
| 9 | Raw RS-232 bytes |

---

## Julia implementation notes

For a **standalone Julia driver** (no UNICORN interoperability needed):

1. Open COM port at 9600/8N1.
2. Transmit SNRM frames `#0S5\r` (`23 30 53 35 0D`) at ~100ms intervals
   until the instrument responds with UA `#1uX\r` (`23 31 75 58 0D`).
   Validate: `#` start, address byte `'1'` (0x31), length 5, ctrl `0x75`,
   checksum. Reset SN=RN=0.
3. Send `0x1001/{0x01}` connect command as an I-frame (nob=1, data=`[0x01]`).
   In the full UNICORN stack this is preceded by a `0x1001/{0x00}` disconnect
   frame, but for a standalone driver that can be omitted.

   **Exact byte sequence** for `0x1001/{0x01}` with SN=0, RN=0:

   ```
   23 30 40 32 31 30 31 31 30 47 0D
   #  0  @  2  1  0  1  1  0  G  CR
   ```

   Derivation:
   - ctrl = `(0 | 0x10) << 2 | 0` = `0x40` = `@`
   - OPC header: nob=1 → char[0]=`0x32`, OPC bits: `0x31 0x30 0x31`
   - Data byte 0x01, nob=1 (odd): `0x31 0x30`
   - Checksum over 8 bytes `30 40 32 31 30 31 31 30`: sum=`0x95`,
     `(0x95 + 0x02) & 0x3f + 0x30` = `0x47` = `G`
4. After receiving `0x8001` and `0x8002` (program name/version), instrument is ready.
5. Send `0x484` channel setup with desired channels (use table above).
6. Poll at ~100ms with RR frames. Decode incoming I-frames.
7. Maintain `base_time` and `base_volume` accumulators:
   - Reset on each `0x2002` frame.
   - Increment by delta bytes on each `0x2001` frame.
8. Apply `scale_code`: `engineering_value = raw / 10^scale_code`.
   The instrument firmware applies its own internal calibration before
   transmitting, so values in `0x2001` frames are already in engineering
   units (mAU, mS/cm, MPa, °C) -- the same values shown on the
   instrument's own LCD. No additional calibration step is needed.
9. To send instrument commands, encode as ASCII text and send OPC `0x8003`.

For a **full UNICORN-compatible replacement** (serving named pipes):

1. Implement the three named pipe servers (RREQ, RMANUAL, RONLINE)
   using the `ooc_thdRequest` command table above.
2. Serve `_OCI_STATE` from your own cached state, updated from `0x2003` events.
3. Serve `_OCI_MAN_INSTR` list from a static table derived from `AInstrInfo.dll`.
4. Serve `_sliCALIB2` calibration list from your own calibration data.
5. The named pipe format and OLN message framing are documented in the
   OLN message framing section above.