# protocol.jl
#
# HDLC-like sliding-window link layer (window=1, SN mod 4) over RS-232.
# Adapted from the standalone linklayer.jl; OPC handlers push into AppState
# instead of only logging.

# ── Serial port configuration ─────────────────────────────────────────────────
const DEFAULT_SERIAL_PORT = "/dev/tty.usbserial-110"
const BAUD_RATE = 9600

# ── Timing constants ──────────────────────────────────────────────────────────
const POLL_INTERVAL_MS = 100
const IDLE_TIMEOUT_MS = 5000      # silence before we warn and start probing (never disconnects)
const PROBE_INTERVAL_MS = 1000    # while silent, send a poll frame this often to catch a link reset
const REPLY_TIMEOUT_MS = 500

# ── Volume counter resolution ─────────────────────────────────────────────────
# All volume fields (trend Δv, base, run and step volume) are counts of this many
# µL. 10 µL was confirmed on an ÄKTAprime plus; an ÄKTAprime that reads 10x too
# high needs 1 µL. Set from the `volume_unit_uL` preference at startup.
const DEFAULT_VOLUME_UNIT_UL = 10.0
const VOLUME_UNIT_UL = Ref(DEFAULT_VOLUME_UNIT_UL)
_vol_mL(raw::Real)::Float64 = Float64(raw) * VOLUME_UNIT_UL[] / 1000.0

# ── Frame byte constants ──────────────────────────────────────────────────────
const FRAME_START = 0x23        # '#'
const PC_ADDR = 0x30        # '0'
const AKTA_ADDR = 0x31        # '1'
const FRAME_END = 0x0d        # CR

# ── Control byte constants ────────────────────────────────────────────────────
const CTRL_POLL = 0x53
const CTRL_CONN = 0x75
const CTRL_RR_BASE = 0x30
const CTRL_IFRAME = 0x40

# ── OPC codes ─────────────────────────────────────────────────────────────────
const OPC_IDENTITY_REQUEST = UInt16(0x1001)
const OPC_PROG_NAME = UInt16(0x8001)
const OPC_VERSION_STRING = UInt16(0x8002)
const OPC_TREND_DATA = UInt16(0x2001)
const OPC_BASE_TIME_VOL = UInt16(0x2002)
const OPC_RUN_STATE = UInt16(0x2003)
const OPC_INJECT = UInt16(0x2004)
const OPC_TUBEFEED = UInt16(0x2005)
const OPC_STEP_TIME_VOL = UInt16(0x2006)
# Method transfers (methodstore.jl): dump before a run, save to and load from the PC
const OPC_METHOD_DUMP_BEGIN = UInt16(0x2007)
const OPC_METHOD_DUMP_END = UInt16(0x2008)
const OPC_METHOD_SAVE_BEGIN = UInt16(0x2009)
const OPC_METHOD_SAVE_END = UInt16(0x2010)
const OPC_METHOD_SAVE_ACK = UInt16(0x2011)
const OPC_METHOD_LOAD = UInt16(0x2012)
const OPC_METHOD_LOAD_BEGIN = UInt16(0x2013)
const OPC_METHOD_LOAD_END = UInt16(0x2014)
const OPC_METHOD_LIST = UInt16(0x2015)
const OPC_METHOD_LIST_REPLY = UInt16(0x2016)
const OPC_METHOD_DELETE = UInt16(0x2017)
const OPC_METHOD_DELETE_REPLY = UInt16(0x2018)
const OPC_METHOD_EXISTS = UInt16(0x2019)
const OPC_METHOD_EXISTS_REPLY = UInt16(0x2020)
const OPC_DEBUG_MSG = UInt16(0x8003)
const OPC_LOG_SINGLE = UInt16(0x8004)
const OPC_LOG_BEGIN = UInt16(0x8005)
const OPC_LOG_CONT = UInt16(0x8006)
const OPC_LOG_END = UInt16(0x8007)
const OPC_METHOD_LINE = UInt16(0x8008)         # a whole line of method text
const OPC_METHOD_LINE_BEGIN = UInt16(0x8009)   # a long line: first part,
const OPC_METHOD_LINE_CONT = UInt16(0x8010)    # middle parts,
const OPC_METHOD_LINE_END = UInt16(0x8011)     # last part
const OPC_WATCHDOG = UInt16(0x3001)

# ─────────────────────────────────────────────────────────────────────────────
# LinkState — mirrors thread-local variables in thdLinklayer
# ─────────────────────────────────────────────────────────────────────────────
mutable struct LinkState
    connected::Bool
    sn::UInt8
    rn::UInt8
    pending_tx::Bool
    idle_ms::Int
    driver_enabled::Bool
    silent::Bool
    probe_ms::Int
    method::MethodTransfer   # method dump or save in progress
end
LinkState() = LinkState(false, 0x00, 0x00, false, 0, false, false, 0, MethodTransfer())

# (Re)initialise the link after a connect handshake from the Akta.
function _link_reset!(st::LinkState, tx_queue::Channel)
    st.sn = 0x00
    st.rn = 0x00
    st.pending_tx = false
    st.idle_ms = 0
    st.probe_ms = 0
    st.silent = false
    st.connected = true
    st.driver_enabled = false
    st.method = MethodTransfer()
    while isready(tx_queue)
        take!(tx_queue)
    end
    put!(tx_queue, (OPC_IDENTITY_REQUEST, UInt8[0x00]))
end

# Any valid frame from the Akta proves the link is alive.
function _link_alive!(st::LinkState, app::AppState, post)
    st.idle_ms = 0
    st.probe_ms = 0
    if st.silent
        st.silent = false
        @info "Akta responding again"
        post(() -> push_event!(app, EVT_LOG, "Link: Akta responding again"))
    end
end

# ── Frame helpers (unchanged from linklayer.jl) ───────────────────────────────

function fmt_frame(buf::AbstractVector{UInt8})::String
    hex = join(string.(buf, base=16, pad=2), " ")
    asc = String([0x20 <= b <= 0x7e ? b : UInt8('.') for b in buf])
    return "$hex  |$asc|"
end

function compute_checksum(buf::AbstractVector{UInt8}, offset::Int, len::Int)::UInt8
    s = 0x00
    for i in offset:(offset+len-1)
        s += buf[i]
    end
    return UInt8(((Int(s) + Int(s >> 6)) & 0x3f) + 0x30)
end

function validate_rx_frame(buf::AbstractVector{UInt8}, len::Int)::Bool
    len < 5 && return false
    buf[1] != FRAME_START && return false
    buf[2] != AKTA_ADDR && return false
    buf[len] != FRAME_END && return false
    expected = compute_checksum(buf, 2, len - 3)
    return buf[len-1] == expected
end

function build_poll_frame()::Vector{UInt8}
    buf = UInt8[FRAME_START, PC_ADDR, CTRL_POLL, 0x00, FRAME_END]
    buf[4] = compute_checksum(buf, 2, 2)
    return buf
end

function build_ack_frame(rn::UInt8)::Vector{UInt8}
    buf = UInt8[FRAME_START, PC_ADDR, CTRL_RR_BASE|(rn&0x03), 0x00, FRAME_END]
    buf[4] = compute_checksum(buf, 2, 2)
    return buf
end

function build_i_frame(payload::Vector{UInt8}, sn::UInt8, rn::UInt8)::Vector{UInt8}
    plen = length(payload)
    buf = Vector{UInt8}(undef, plen + 5)
    buf[1] = FRAME_START
    buf[2] = PC_ADDR
    buf[3] = UInt8((0x10 | (sn & 0x03)) << 2 | (rn & 0x03))
    buf[4:3+plen] .= payload
    buf[plen+4] = compute_checksum(buf, 2, plen + 2)
    buf[plen+5] = FRAME_END
    return buf
end

function encode_opc_payload(opc::UInt16, data::Vector{UInt8})::Vector{UInt8}
    out = UInt8[]
    nob = length(data)
    if (opc & 0x8000) == 0
        push!(out, UInt8(((nob >> 1) + 0x10) * 3 + (nob & 1) * 2))
    else
        push!(out, UInt8(nob + 0x30))
    end
    push!(out, UInt8((opc & 0x003f) + 0x30))
    push!(out, UInt8(((opc >> 6) & 0x3f) + 0x30))
    push!(out, UInt8((opc >> 12) + 0x30))
    if (opc & 0x8000) == 0
        i = 1
        while i <= nob
            if i + 1 <= nob
                b0, b1 = data[i], data[i+1]
                push!(out, UInt8((b0 & 0x3f) + 0x30))
                push!(out, UInt8(((b1 & 0x0f) << 2 | (b0 >> 6)) + 0x30))
                push!(out, UInt8((b1 >> 4) + 0x30))
                i += 2
            else
                b0 = data[i]
                push!(out, UInt8((b0 & 0x3f) + 0x30))
                push!(out, UInt8((b0 >> 6) + 0x30))
                i += 1
            end
        end
    else
        for b in data
            if b < 0x20 || b > 0x7f || b == FRAME_START
                @warn "encode_opc_payload: byte 0x$(string(b, base=16)) out of ASCII range"
                b = 0x20
            end
            push!(out, b)
        end
    end
    return out
end

function decode_opc_payload(enc::AbstractVector{UInt8})::Vector{Tuple{UInt16,Vector{UInt8}}}
    results = Tuple{UInt16,Vector{UInt8}}[]
    pos = 1
    remaining = length(enc)
    while remaining > 0
        remaining < 4 && break
        nob_byte = enc[pos]
        nob_byte < 0x30 && break
        nob_chars = Int(nob_byte - 0x30)
        b1, b2, b3 = enc[pos+1], enc[pos+2], enc[pos+3]
        (b1 < 0x30 || b1 > 0x6f) && break
        (b2 < 0x30 || b2 > 0x6f) && break
        (b3 < 0x30 || b3 > 0x3f) && break
        opc = UInt16(b1 - 0x30) | (UInt16(b2 - 0x30) << 6) | (UInt16(b3 - 0x30) << 12)
        pos += 4
        remaining -= 4
        data = UInt8[]
        if (opc & 0x8000) == 0
            chars_left = nob_chars
            while chars_left > 0 && remaining > 0
                if chars_left >= 3 && remaining >= 3
                    c0 = Int(enc[pos]) - 0x30
                    c1 = Int(enc[pos+1]) - 0x30
                    c2 = Int(enc[pos+2]) - 0x30
                    push!(data, UInt8(c0 | ((c1 & 0x03) << 6)))
                    push!(data, UInt8(((c1 >> 2) & 0x0f) | (c2 << 4)))
                    pos += 3
                    remaining -= 3
                    chars_left -= 3
                elseif chars_left >= 2 && remaining >= 2
                    c0 = Int(enc[pos]) - 0x30
                    c1 = Int(enc[pos+1]) - 0x30
                    push!(data, UInt8(c0 | ((c1 & 0x03) << 6)))
                    pos += 2
                    remaining -= 2
                    chars_left -= 2
                else
                    c0 = Int(enc[pos]) - 0x30
                    push!(data, UInt8(c0 & 0x3f))
                    pos += 1
                    remaining -= 1
                    chars_left -= 1
                end
            end
        else
            take = min(nob_chars, remaining)
            append!(data, enc[pos:pos+take-1])
            pos += take
            remaining -= take
        end
        push!(results, (opc, data))
    end
    return results
end

# ─────────────────────────────────────────────────────────────────────────────
# OPC handlers — push into AppState, then log
# ─────────────────────────────────────────────────────────────────────────────

const RUN_STATE_NAMES = Dict{UInt8,String}(
    0x00 => "End", 0x01 => "Run", 0x02 => "Pause", 0x03 => "Hold", 0x04 => "Continue",
)

function _handle_trend_data(data::Vector{UInt8}, app::AppState)
    length(data) < 14 && (@warn "OPC 0x2001: short payload ($(length(data)) bytes)"; return)

    inst = app.inst[]
    dt_ms = Float64(data[1]) * 10.0                # Δt: units 10 ms
    dv_mL = _vol_mL(data[2])                       # Δv: volume counts → mL
    inst.cum_time_ms += dt_ms
    inst.cum_vol_mL += dv_mL
    # The ÄKTAprime sends OPC 0x2003 only on state changes, so run time/volume
    # would otherwise freeze at the run-start value. Advance them with the trend
    # deltas during a run; the next 0x2003 overwrites them with the instrument's values.
    if inst.run_state in ("Run", "Pause", "Hold", "Continue")
        inst.run_time_ms += dt_ms
        inst.run_vol_mL += dv_mL
    end

    uv_raw = Int32(data[3]) | (Int32(data[4]) << 8) | (Int32(data[5]) << 16)
    if (data[5] & 0x80) != 0
        uv_raw |= Int32(-16777216)
    end

    cond_raw = UInt32(data[6]) | (UInt32(data[7]) << 8) | (UInt32(data[8]) << 16)
    ph_raw = Int32(data[9]) | (Int32(data[10] & 0x07) << 8)
    pctb_raw = (Int(data[10]) >> 3) | ((Int(data[11]) & 0x1f) << 5)
    pres_raw = (Int(data[11]) >> 5) | (Int(data[12]) << 3)
    temp_raw = (Int(data[13]) | ((Int(data[14]) & 0x07) << 8)) - 100

    uv = uv_raw / 1e6
    cond = cond_raw / 1e3
    ph = ph_raw / 100.0
    pctb = pctb_raw / 10.0
    pres = pres_raw / 1e3
    temp = temp_raw / 10.0

    pt = TrendPoint(inst.cum_time_ms, inst.cum_vol_mL, uv, cond, ph, pctb, pres, temp)
    push!(app.trend_data[], pt)
    notify(app.trend_data)
    write_csv_trend(app, pt)
    notify(app.inst)

    @debug @sprintf("Trend  t=%8.1fs  v=%8.4fmL  UV=%+.6f  COND=%6.3fmS/cm  %%B=%5.1f  P=%6.3f  T=%5.1f°C",
        inst.cum_time_ms / 1000, inst.cum_vol_mL,
        uv, cond, pctb, pres, temp)
end

function _handle_base_time_vol(data::Vector{UInt8}, app::AppState)
    length(data) < 8 && (@warn "OPC 0x2002: short payload"; return)
    base_time_ms = Float64(UInt32(data[1]) | (UInt32(data[2]) << 8) |
                           (UInt32(data[3]) << 16) | (UInt32(data[4]) << 24)) * 10.0
    base_vol_mL = _vol_mL(UInt32(data[5]) | (UInt32(data[6]) << 8) |
                          (UInt32(data[7]) << 16) | (UInt32(data[8]) << 24))
    inst = app.inst[]
    # A base that jumps backwards means the instrument's run counter has
    # restarted — a new run. Roll to a fresh log so traces do not overlap.
    if base_time_ms < inst.cum_time_ms
        rolllog!(app)
        inst = app.inst[]
    end
    inst.cum_time_ms = base_time_ms
    inst.cum_vol_mL = base_vol_mL
    notify(app.inst)
    @info @sprintf("Base time/vol:  t=%.1fs  v=%.4fmL", base_time_ms / 1000, base_vol_mL)
end

_inject_from_runstate(raw::UInt8) = raw == 0x00 ? IV_LOAD : IV_INJECT

# A genuine new run: entering "Run" from an ended or idle state (not a resume
# from Pause/Hold/Continue, which stay within the same run).
_is_run_start(prev::AbstractString, now::AbstractString) =
    now == "Run" && (prev == "End" || prev == "---")

function _set_inject_from_log!(text::String, inst::InstrumentState)::Bool
    msg = lowercase(strip(text))
    if msg == "injection valve load"
        inst.inject_value = IV_LOAD
        return true
    elseif msg == "injection valve inj"
        inst.inject_value = IV_INJECT
        return true
    elseif msg == "injection valve waste"
        inst.inject_value = IV_WASTE
        return true
    end
    return false
end

# "Buffer Valve Pos 3"; a change made on the front panel is prefixed "Manual Set; ".
function _set_buffer_valve_from_log!(text::String, inst::InstrumentState)::Bool
    m = match(r"^(?:Manual Set;\s*)?Buffer Valve Pos\s+([1-8])$"i, strip(text))
    m === nothing && return false
    inst.buffer_port = parse(Int, m.captures[1])
    inst.buffer_port_known = true
    return true
end

function _set_fraction_from_log!(text::String, inst::InstrumentState, app::AppState)::Bool
    msg = strip(text)
    changed = false
    if (m = match(r"^Fraction size\s+([0-9]+(?:\.[0-9]+)?)\s+ml$"i, msg)) !== nothing
        inst.fraction_vol_mL = parse(Float64, m.captures[1])
        changed = true
    end
    if (m = match(r"^Feed Tube Nr\s+(\d+)$"i, msg)) !== nothing
        inst.fraction_number = max(1, parse(Int, m.captures[1]))
        changed = true
    end

    # Update fraction state machine if anything changed
    if changed
        if update_fraction_state!(app)
            notify(app.fractions)
        end
    end

    return changed
end

function _handle_run_state(data::Vector{UInt8}, app::AppState)
    length(data) < 10 && (@warn "OPC 0x2003: short payload"; return)
    run_time_raw = UInt32(data[1]) | (UInt32(data[2]) << 8) | (UInt32(data[3]) << 16)
    run_vol_raw = UInt32(data[5]) | (UInt32(data[6]) << 8) | (UInt32(data[7]) << 16)
    state = data[9]
    inject = _inject_from_runstate(data[10])

    state_name = get(RUN_STATE_NAMES, state, "Unknown(0x$(string(state, base=16)))")
    run_time_ms = run_time_raw / 10.0
    run_vol_mL = _vol_mL(run_vol_raw)

    inst = app.inst[]
    changed = inst.run_state != state_name || inst.inject_value != inject

    # Roll to a fresh log on a new run before recording anything for it, so the
    # run-start event and its trend data land in the new file.
    if _is_run_start(inst.run_state, state_name)
        rolllog!(app)
        inst = app.inst[]
        # The method dump arrives just before the run starts; record it in the new log.
        if !isnothing(PENDING_METHOD_EVENT[])
            push_event!(app, EVT_LOG, PENDING_METHOD_EVENT[])
            PENDING_METHOD_EVENT[] = nothing
        end
    end

    inst.run_state = state_name
    inst.run_time_ms = run_time_ms
    inst.run_vol_mL = run_vol_mL
    inst.inject_value = inject
    notify(app.inst)

    if changed
        txt = "Run state: $state_name  inject=$(string(inject))"
        @info txt
        push_event!(app, EVT_RUN_STATE, txt)
    end
end

function _handle_step_time_vol(data::Vector{UInt8}, app::AppState)
    length(data) < 8 && (@warn "OPC 0x2006: short payload"; return)
    step_time_ms = Float64(UInt32(data[1]) | (UInt32(data[2]) << 8) |
                           (UInt32(data[3]) << 16) | (UInt32(data[4]) << 24)) * 10.0
    step_vol_mL = _vol_mL(UInt32(data[5]) | (UInt32(data[6]) << 8) |
                          (UInt32(data[7]) << 16) | (UInt32(data[8]) << 24))
    inst = app.inst[]
    inst.step_time_ms = step_time_ms
    inst.step_vol_mL = step_vol_mL
    notify(app.inst)
    txt = @sprintf("Step t=%.1fs  v=%.4fmL", step_time_ms / 1000, step_vol_mL)
    @info txt
    push_event!(app, EVT_STEP, txt)
end

function _handle_debug_message(data::Vector{UInt8}, app::AppState)
    s = replace(String(copy(data)), '~' => '\r', '}' => '\n')
    @info "Debug: $(repr(s))"
end

function _handle_log_message(opc::UInt16, data::Vector{UInt8}, app::AppState)
    text = String(copy(data))
    if opc == OPC_LOG_SINGLE
        inst = app.inst[]
        changed = _set_inject_from_log!(text, inst) | _set_buffer_valve_from_log!(text, inst) |
                  _set_fraction_from_log!(text, inst, app)
        changed && notify(app.inst)
        @info "Log: $text"
        push_event!(app, EVT_LOG, text)
    elseif opc == OPC_LOG_BEGIN
        app.log_buf = text
    elseif opc == OPC_LOG_CONT
        app.log_buf *= text
    elseif opc == OPC_LOG_END
        full = app.log_buf * text
        app.log_buf = ""
        inst = app.inst[]
        changed = _set_inject_from_log!(full, inst) | _set_buffer_valve_from_log!(full, inst) |
                  _set_fraction_from_log!(full, inst, app)
        changed && notify(app.inst)
        @info "Log: $full"
        push_event!(app, EVT_LOG, full)
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# dispatch_rx_opc
# ─────────────────────────────────────────────────────────────────────────────
# ─────────────────────────────────────────────────────────────────────────────
# Raw capture — material for decoding undocumented messages
# ─────────────────────────────────────────────────────────────────────────────
# Every received OPC except trend data and the watchdog is appended to the raw
# log, as are the method messages sent to the Akta (marked TX), and each method
# dump is saved as the instrument sent it, still escaped, to <log>_method_N.met.
const RAW_IO = Ref{Union{Nothing,IO}}(nothing)
const METHOD_COUNT = Ref(0)

_printable(data) = String(map(b -> 0x20 <= b <= 0x7e ? b : UInt8('.'), data))

function _capture_opc(opc::UInt16, data::Vector{UInt8}; tx::Bool=false)
    io = RAW_IO[]
    if !isnothing(io) && opc != OPC_TREND_DATA && opc != OPC_WATCHDOG
        println(io, Dates.format(now(), "HH:MM:SS.sss"), tx ? "  TX 0x" : "  0x", string(opc, base=16, pad=4),
            "  n=", length(data), "  ", bytes2hex(data), "  |", _printable(data), "|")
        flush(io)
    end
end

# A method dump has arrived (escaped text, see methodstore.jl).
function _method_dump_received!(app::AppState, raw::Vector{UInt8})
    if !isnothing(RAW_IO[])           # saved only with "Save raw instrument data" on
        METHOD_COUNT[] += 1
        path = replace(app.log_filename, r"\.csv$" => "_method_$(METHOD_COUNT[]).met")
        write(path, raw)
        @info "Saved method transfer ($(length(raw)) bytes) to $path"
    end
    try
        apply_method_dump!(app, parse_method_dump(raw))
    catch err
        @warn "Could not decode method dump" exception = err
    end
end

function dispatch_rx_opc(opc::UInt16, data::Vector{UInt8}, tx_queue::Channel, app::AppState)
    _capture_opc(opc, data)
    if opc == OPC_PROG_NAME
        name = rstrip(String(copy(data[1:min(100, end)])), '\0')
        @info "Programme name: $name"
        app.inst[].prog_name = name
        notify(app.inst)

    elseif opc == OPC_VERSION_STRING
        ver = rstrip(String(copy(data[1:min(20, end)])), '\0')
        @info "Version: $ver"
        app.inst[].version = ver
        notify(app.inst)

    elseif opc == OPC_TREND_DATA
        _handle_trend_data(data, app)
    elseif opc == OPC_BASE_TIME_VOL
        _handle_base_time_vol(data, app)
    elseif opc == OPC_RUN_STATE
        _handle_run_state(data, app)

    elseif opc == OPC_INJECT
        txt = "Inject event ($(length(data)) bytes)"
        @info txt
        push_event!(app, EVT_INJECT, txt)

    elseif opc == OPC_TUBEFEED
        inst = app.inst[]
        if length(data) >= 10
            tube_no = Int(UInt16(data[9]) | (UInt16(data[10]) << 8))
            inst.fraction_number = max(1, tube_no)
        else
            inst.fraction_number += 1
        end

        # Update fraction state machine
        if update_fraction_state!(app)
            notify(app.fractions)
        end
        notify(app.inst)

        txt = "Tubefeed event ($(length(data)) bytes)"
        @info txt
        push_event!(app, EVT_TUBEFEED, txt)

    elseif opc == OPC_STEP_TIME_VOL
        _handle_step_time_vol(data, app)

    elseif is_method_opc(opc)
        # answered on the link thread (_method_opc!)
        @debug "Method OPC 0x$(string(opc, base=16, pad=4)): $(length(data)) bytes"

    elseif opc == OPC_DEBUG_MSG
        _handle_debug_message(data, app)

    elseif opc == OPC_LOG_SINGLE || opc == OPC_LOG_BEGIN ||
           opc == OPC_LOG_CONT || opc == OPC_LOG_END
        _handle_log_message(opc, data, app)

    elseif opc == OPC_WATCHDOG
        # silently drop

    else
        @info "Unknown OPC 0x$(string(opc, base=16, pad=4)): $(length(data)) bytes"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# parse_rx_data_frame — decodes payload and dispatches each OPC
# ─────────────────────────────────────────────────────────────────────────────
# Decoding and the driver-enable handshake happen on the link thread; handling
# each OPC (state, CSV, GUI) is posted to the main thread.
function parse_rx_data_frame(frame::AbstractVector{UInt8}, len::Int,
    tx_queue::Channel, st::LinkState, app::AppState, post)
    len < 6 && return
    payload = @view frame[4:len-2]
    for (opc, data) in decode_opc_payload(payload)
        if opc == OPC_VERSION_STRING && !st.driver_enabled
            st.driver_enabled = true
            put!(tx_queue, (OPC_IDENTITY_REQUEST, UInt8[0x01]))
            @info "Queued driver-enable (OPC 0x1001/0x01)"
        end
        post(() -> dispatch_rx_opc(opc, data, tx_queue, app))
        is_method_opc(opc) && _method_opc!(st, opc, data, tx_queue, app, post)
    end
end

# Method store requests are answered here on the link thread, so the reply never
# waits for a busy GUI (the Akta gives up after about 2 s); the run log and a
# finished method dump are handled on the main thread.
function _method_opc!(st::LinkState, opc::UInt16, data::Vector{UInt8}, tx_queue::Channel,
    app::AppState, post)
    action = try
        handle_method_opc!(st.method, opc, data, METHOD_DIR[])
    catch err
        @error "Error handling method OPC 0x$(string(opc, base=16, pad=4))" exception = (err, catch_backtrace())
        nothing
    end
    isnothing(action) && return
    foreach(m -> put!(tx_queue, m), action.replies)
    replies, note, dump = action.replies, action.note, action.dump
    isempty(replies) || post(() -> foreach(((o, d),) -> _capture_opc(o, d; tx=true), replies))
    if !isnothing(note)
        @info note
        post(() -> push_event!(app, EVT_LOG, note))
    end
    isnothing(dump) || post(() -> _method_dump_received!(app, dump))
    if opc in (OPC_METHOD_SAVE_END, OPC_METHOD_DELETE, OPC_METHOD_LOAD)
        loaded = opc == OPC_METHOD_LOAD && last(replies) == (OPC_METHOD_LOAD_END, UInt8[0x00]) ? _u16(data) : 0
        post(() -> (loaded > 0 && (LAST_LOADED_METHOD[] = loaded); METHODS_CHANGED[] += 1))
    end
end

# On its own thread the link must sleep with OS sleeps: Julia's `sleep` is woken
# by the event loop, which a busy main thread (GUI) does not service, so the link
# would stall with it. On the main thread an OS sleep would freeze the GUI instead.
const LINK_OWN_THREAD = Ref(false)
# GC-safe: other threads' garbage collection need not wait for this sleep to end
# (Libc.systemsleep blocks it, which would stall the GUI for up to the poll interval).
_os_sleep(s::Real) = Sys.iswindows() ?
    (@ccall gc_safe = true "kernel32".Sleep(round(UInt32, s * 1e3)::UInt32)::Cvoid) :
    (@ccall gc_safe = true usleep(round(UInt32, s * 1e6)::UInt32)::Cint; nothing)
_link_sleep(s::Real) = LINK_OWN_THREAD[] ? _os_sleep(s) : sleep(s)

# ─────────────────────────────────────────────────────────────────────────────
# write_frame_read_reply (unchanged from linklayer.jl)
# ─────────────────────────────────────────────────────────────────────────────
function write_frame_read_reply(sp::SerialPort, frame::Vector{UInt8})::Vector{UInt8}
    n = length(frame)
    @debug "TX $(fmt_frame(frame))"
    write(sp, frame[1:n-2])
    sp_flush(sp, SP_BUF_INPUT)
    write(sp, frame[n-1:n])

    reply = UInt8[]
    in_frame = false
    deadline = time() + REPLY_TIMEOUT_MS / 1000.0
    while time() < deadline
        if bytesavailable(sp) > 0
            b = read(sp, UInt8)
            if b == FRAME_START
                reply = UInt8[b]
                in_frame = true
            elseif in_frame
                b = (b == 0x0a) ? FRAME_END : b
                push!(reply, b)
                b == FRAME_END && break
                length(reply) > 999 && (reply = UInt8[]; in_frame = false)
            end
        else
            _link_sleep(0.001)
        end
    end
    isempty(reply) || @debug "RX $(fmt_frame(reply))"
    return reply
end

# ─────────────────────────────────────────────────────────────────────────────
# run_linklayer — main link-layer loop
# ─────────────────────────────────────────────────────────────────────────────
# Run it on its own thread (Threads.@spawn) so polling never waits for the GUI:
# the Akta resets the link when the PC stays silent for a few seconds. Anything
# that touches AppState is then passed as a closure through `rx_actions` and run
# by the main thread, since Makie and the app state are not thread-safe.
# Without `rx_actions` everything runs inline (single-task use and tests).
function run_linklayer(tx_queue::Channel, shutdown::Ref{Bool}, app::AppState,
    serial_port::AbstractString=DEFAULT_SERIAL_PORT; rx_actions::Union{Nothing,Channel}=nothing,
    status::Union{Nothing,Observable{String}}=nothing)
    post = isnothing(rx_actions) ? (f -> f()) : (f -> put!(rx_actions, f))
    say(txt) = isnothing(status) || post(() -> status[] = txt)   # connection state for the GUI
    LINK_OWN_THREAD[] = Threads.threadid() != 1
    @info "Link layer on thread $(Threads.threadid())" * (LINK_OWN_THREAD[] ? "" : " (shared with the GUI)")

    # One session per connection: open the port (retrying while it is missing),
    # then poll. If the port fails (cable pulled, adaptor reset: "Input/output
    # error"), the session ends and a new one starts — the link never just stops.
    while !shutdown[]
        # A missing or unplugged adaptor is retried until it appears, not fatal.
        sp = nothing
        warned = false
        while isnothing(sp) && !shutdown[]
            try
                sp = LibSerialPort.open(serial_port, BAUD_RATE)
            catch err
                warned || @warn "Serial port $serial_port not available — retrying" exception = err
                warned || say("Serial port $serial_port not available — retrying")
                warned = true
                _link_sleep(2.0)
            end
        end
        isnothing(sp) && break
        @info "Opened $serial_port at $BAUD_RATE baud"
        say("Waiting for Akta on $serial_port")
        set_flow_control(sp; rts=SP_RTS_ON, cts=SP_CTS_IGNORE, dtr=SP_DTR_ON, dsr=SP_DSR_IGNORE)

        st = LinkState()
        poll_frame = build_poll_frame()
        cur_frame = poll_frame
        t_last = time_ns()

        @info "Link layer started; polling for Akta"

        try
            while !shutdown[]
                t_now = time_ns()
                elapsed_ms = Int((t_now - t_last) ÷ 1_000_000)
                delay_ms = elapsed_ms < POLL_INTERVAL_MS ? POLL_INTERVAL_MS - elapsed_ms : 1
                _link_sleep(delay_ms / 1000.0)
                t_now = time_ns()
                elapsed_ms = Int((t_now - t_last) ÷ 1_000_000)
                t_last = t_now

                probing = false
                if !st.connected
                    while isready(tx_queue)
                        take!(tx_queue)
                    end
                    cur_frame = poll_frame

                else
                    st.idle_ms += elapsed_ms
                    # While the Akta is silent, interleave poll frames: if it has
                    # reset its link it answers with CTRL_CONN and we resync below.
                    if st.idle_ms > IDLE_TIMEOUT_MS
                        st.probe_ms += elapsed_ms
                        if st.probe_ms >= PROBE_INTERVAL_MS
                            st.probe_ms = 0
                            probing = true
                        end
                    end
                    if !probing && !st.pending_tx
                        if isready(tx_queue)
                            opc, data = take!(tx_queue)
                            payload = encode_opc_payload(opc, data)
                            st.sn = (st.sn + 0x01) & 0x03
                            cur_frame = build_i_frame(payload, st.sn, st.rn)
                            st.pending_tx = true
                        else
                            cur_frame = build_ack_frame(st.rn)
                        end
                    end
                end

                # cur_frame is kept intact while probing so a pending I-frame is retransmitted later
                reply = write_frame_read_reply(sp, probing ? poll_frame : cur_frame)
                rx_len = length(reply)

                if rx_len > 0 && validate_rx_frame(reply, rx_len)
                    ctrl = reply[3]

                    if !st.connected
                        if rx_len == 5 && ctrl == CTRL_CONN
                            @info "Akta connected"
                            _link_reset!(st, tx_queue)
                            post(() -> push_event!(app, EVT_CONNECT, "Akta connected"))
                            say("● Connected on $serial_port")
                        else
                            @warn "Unexpected frame while disconnected: ctrl=0x$(string(ctrl, base=16))"
                        end

                    else
                        st.silent && say("● Connected on $serial_port")
                        _link_alive!(st, app, post)

                        if rx_len == 5 && ctrl == CTRL_CONN
                            # The Akta restarted its side of the link: resync rather than drop out
                            @warn "Akta re-established the link — resynchronising"
                            _link_reset!(st, tx_queue)
                            post(() -> push_event!(app, EVT_LOG, "Link: Akta re-established the link"))

                        elseif (ctrl & 0xf0) == CTRL_IFRAME
                            received_sn = (ctrl >> 2) & 0x03
                            if received_sn == (st.rn + 0x01) & 0x03
                                st.rn = received_sn
                                parse_rx_data_frame(reply, rx_len, tx_queue, st, app, post)
                            elseif received_sn == st.rn
                                @warn "LinkLayer: duplicate I-frame SN=$received_sn"
                            else
                                # Frames were lost; accept this one and resync, otherwise the
                                # Akta retransmits it forever and nothing more is recorded.
                                @warn "LinkLayer: SN error — expected $((st.rn+1)&3), got $received_sn; resynchronising"
                                st.rn = received_sn
                                parse_rx_data_frame(reply, rx_len, tx_queue, st, app, post)
                            end
                            if st.sn == (ctrl & 0x03)
                                st.pending_tx = false
                            else
                                @warn "LinkLayer: RN mismatch in I-frame ctrl"
                            end

                        elseif (ctrl & 0xfc) == CTRL_RR_BASE
                            if st.sn == (ctrl & 0x03)
                                st.pending_tx = false
                            else
                                @warn "LinkLayer: RN mismatch in RR frame"
                            end

                        else
                            @warn "LinkLayer: unexpected ctrl 0x$(string(ctrl, base=16))"
                        end
                    end
                end

                # Never disconnect on silence: keep the link and the log open and just report it
                if st.connected && !st.silent && st.idle_ms > IDLE_TIMEOUT_MS
                    st.silent = true
                    @warn "No response from Akta for $(st.idle_ms ÷ 1000) s — staying connected, probing"
                    post(() -> push_event!(app, EVT_LOG, "Link: no response from Akta — waiting"))
                    say("No response from Akta on $serial_port — waiting")
                end
            end

        catch err
            err isa InterruptException && rethrow()
            @warn "Serial connection lost — reconnecting" exception = err
            post(() -> push_event!(app, EVT_LOG, "Link: serial connection lost — reconnecting"))
            say("Connection to $serial_port lost — reconnecting")
        finally
            try
                LibSerialPort.close(sp)
            catch
            end
        end
        shutdown[] || _link_sleep(2.0)
    end
    @info "Link layer shutting down"
end
