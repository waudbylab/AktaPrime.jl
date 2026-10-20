# types.jl — shared data structures for the Akta application

"""One trend data sample with cumulative time/volume coordinates."""
struct TrendPoint
    cum_time_ms::Float64   # cumulative run time from base, ms
    cum_vol_mL::Float64   # cumulative run volume from base, mL
    uv::Float64   # UV absorbance, AU
    cond_mScm::Float64   # conductivity, mS/cm
    ph::Float64   # pH (dimensionless; raw ÷ 100 — scaling documented, unconfirmed on hardware)
    pctb::Float64   # gradient %B (0–100)
    pres_MPa::Float64   # pressure, MPa (raw ÷ 1000)
    temp_degC::Float64   # temperature, °C
end

"""A fraction collection period with start/end time and volume."""
struct Fraction
    fraction_number::Int
    start_time_ms::Float64   # cumulative run time when fraction started
    start_vol_mL::Float64    # cumulative run volume when fraction started
    end_time_ms::Union{Float64,Nothing}   # cumulative run time when fraction stopped (if completed)
    end_vol_mL::Union{Float64,Nothing}    # cumulative run volume when fraction stopped (if completed)
end

@enum EventKind begin
    EVT_CONNECT
    EVT_DISCONNECT
    EVT_RUN_STATE
    EVT_INJECT
    EVT_TUBEFEED
    EVT_LOG
    EVT_STEP
    EVT_MARK     # user event mark, added during a run
    EVT_INFO     # run documentation ("Sample: …", "Port 3: …"), not drawn in plots
end

@enum InjectValue begin
    IV_LOAD
    IV_INJECT
    IV_WASTE
    IV_UNKNOWN
end

"""A discrete instrument event tagged with run coordinates."""
struct AktaEvent
    cum_time_ms::Float64
    cum_vol_mL::Float64
    kind::EventKind
    text::String
end

"""Live instrument status — mutated in place, then notify(app.inst) called."""
mutable struct InstrumentState
    run_state::String
    cum_time_ms::Float64
    cum_vol_mL::Float64
    run_time_ms::Float64
    run_vol_mL::Float64
    inject_value::InjectValue
    prog_name::String
    version::String
    step_time_ms::Float64
    step_vol_mL::Float64
    fraction_number::Int
    fraction_vol_mL::Float64
    current_fraction_idx::Union{Int,Nothing}  # index into app.fractions[] of active fraction, or nothing if idle
    buffer_port::Int           # buffer valve inlet port 1–8 feeding the A side
    buffer_port_known::Bool    # false until a "Buffer Valve Pos N" message confirms buffer_port
end
# The buffer valve is only reported when it moves, so start from the standard
# port 1 and mark it as assumed until the first report.
InstrumentState() = InstrumentState("---", 0.0, 0.0, 0.0, 0.0, IV_UNKNOWN, "", "", 0.0, 0.0, 1, 0.0, nothing,
    1, false)

"""
Application-wide shared state.  Passed to OPC handlers and the CSV writer.
The three Observables are the source of truth for the GUI; they are notified
from the link-layer @async task (single OS thread, cooperative scheduling).
"""
mutable struct AppState
    # Observables observed by the GUI
    trend_data::Observable{Vector{TrendPoint}}
    events::Observable{Vector{AktaEvent}}
    inst::Observable{InstrumentState}
    fractions::Observable{Vector{Fraction}}
    iszoomed::Observable{Bool}

    # multi-frame log message buffer (OPC 0x8005–0x8007)
    log_buf::String

    # open CSV file (nothing until the user confirms a filename)
    csv_io::Union{IO,Nothing}

    # log filename shown in the GUI status panel
    log_filename::String

    # base name for rolled-over log files ("<prefix>_<timestamp>.csv" per run)
    log_prefix::String

    # folder for log files and exported plots ("" = current folder)
    log_dir::String
end

AppState() = AppState(
    Observable(TrendPoint[]),
    Observable(AktaEvent[]),
    Observable(InstrumentState()),
    Observable(Fraction[]),
    Observable(false),
    "",
    nothing,
    "",
    "akta",
    "",
)

# ── helpers ──────────────────────────────────────────────────────────────────

"""
Update fraction state based on current instrument state.
Detects transitions: fraction_vol_mL going 0→>0 (start), >0→0 (stop), or fraction_number change (new tube).
Returns true if fractions Observable should be notified.
"""
function update_fraction_state!(app::AppState)::Bool
    inst = app.inst[]
    fracs = app.fractions[]
    changed = false

    # Determine if we should be collecting (fraction_vol_mL > 0 = active)
    collecting = inst.fraction_vol_mL > 0

    if collecting && isnothing(inst.current_fraction_idx)
        # ── Start new fraction (transition 0→>0) ──
        frac = Fraction(
            inst.fraction_number,
            inst.cum_time_ms,
            inst.cum_vol_mL,
            nothing,
            nothing
        )
        push!(fracs, frac)
        inst.current_fraction_idx = length(fracs)
        changed = true
        @debug "Started fraction #$(inst.fraction_number) at t=$(inst.cum_time_ms/1000)s v=$(inst.cum_vol_mL)mL"

    elseif collecting && !isnothing(inst.current_fraction_idx)
        idx = inst.current_fraction_idx
        if idx <= length(fracs)
            current = fracs[idx]
            # Check if fraction_number changed (means new tube, so close old and start new)
            if current.fraction_number != inst.fraction_number
                # Close current fraction
                fracs[idx] = Fraction(
                    current.fraction_number,
                    current.start_time_ms,
                    current.start_vol_mL,
                    inst.cum_time_ms,
                    inst.cum_vol_mL
                )
                @debug "Stopped fraction #$(current.fraction_number) at t=$(inst.cum_time_ms/1000)s v=$(inst.cum_vol_mL)mL"

                # Start new fraction
                frac = Fraction(
                    inst.fraction_number,
                    inst.cum_time_ms,
                    inst.cum_vol_mL,
                    nothing,
                    nothing
                )
                push!(fracs, frac)
                inst.current_fraction_idx = length(fracs)
                @debug "Started fraction #$(inst.fraction_number) at t=$(inst.cum_time_ms/1000)s v=$(inst.cum_vol_mL)mL"
                changed = true
            end
        end

    elseif !collecting && !isnothing(inst.current_fraction_idx)
        # ── Stop fraction (transition >0→0) ──
        idx = inst.current_fraction_idx
        if idx <= length(fracs)
            current = fracs[idx]
            fracs[idx] = Fraction(
                current.fraction_number,
                current.start_time_ms,
                current.start_vol_mL,
                inst.cum_time_ms,
                inst.cum_vol_mL
            )
            @debug "Stopped fraction #$(current.fraction_number) at t=$(inst.cum_time_ms/1000)s v=$(inst.cum_vol_mL)mL"
        end
        inst.current_fraction_idx = nothing
        changed = true
    end

    return changed
end

"""
Clear all per-run state so a fresh run starts from an empty display: empties
the trend, event and fraction collections and resets the instrument
accumulators (keeping programme name and version).  Notifies every observable.
"""
function resetrun!(app::AppState)
    empty!(app.trend_data[])
    empty!(app.events[])
    empty!(app.fractions[])

    inst = app.inst[]
    inst.cum_time_ms = 0.0
    inst.cum_vol_mL = 0.0
    inst.run_time_ms = 0.0
    inst.run_vol_mL = 0.0
    inst.step_time_ms = 0.0
    inst.step_vol_mL = 0.0
    inst.fraction_number = 1
    inst.fraction_vol_mL = 0.0
    inst.current_fraction_idx = nothing

    notify(app.trend_data)
    notify(app.events)
    notify(app.fractions)
    notify(app.inst)
end

function push_event!(app::AppState, kind::EventKind, text::String)
    inst = app.inst[]
    ev = AktaEvent(inst.cum_time_ms, inst.cum_vol_mL, kind, text)
    push!(app.events[], ev)
    notify(app.events)
    write_csv_event(app, ev)
    @info "[$kind] $text"
end
