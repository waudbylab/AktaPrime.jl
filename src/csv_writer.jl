# csv_writer.jl — CSV logging, flushed after every row

const CSV_HEADER = "wall_time,cum_time_ms,cum_vol_mL,type," *
                   "uv_AU,cond_mScm,ph,pctb_pct,pres_MPa,temp_degC,message\n"

"""Open (or create) a CSV log file and write the header."""
function init_csv(filename::String)::IO
    io = open(filename, "w")
    write(io, "# Akta PRIME data log started $(Dates.now())\n")
    write(io, CSV_HEADER)
    flush(io)
    @info "Logging to $filename"
    return io
end

"""Timestamped log-file path for the app's prefix and folder: `<dir>/<prefix>_<stamp>.csv`."""
function newlogname(app::AppState)::String
    prefix = isempty(app.log_prefix) ? "akta" : app.log_prefix
    joinpath(app.log_dir, "$(prefix)_$(Dates.format(Dates.now(), "yyyymmdd_HHMMSS")).csv")
end

"""
Start a fresh log file for a new run: close the current CSV, open a new
timestamped one and clear the display.  A no-op (returning `false`) when the
current log holds no trend data yet, so back-to-back run-start signals and the
first run after connecting do not spawn empty files.
"""
# Called with the app whenever a new log file is started (acquisition.jl sets it
# to record the run information at the top of every log).
const ON_NEW_LOG = Ref{Function}(app -> nothing)

function rolllog!(app::AppState)::Bool
    isempty(app.trend_data[]) && return false
    isnothing(app.csv_io) || close(app.csv_io)
    name = newlogname(app)
    app.csv_io = init_csv(name)
    app.log_filename = name
    resetrun!(app)
    ON_NEW_LOG[](app)
    @info "New run detected — logging to $name"
    return true
end

function write_csv_trend(app::AppState, pt::TrendPoint)
    isnothing(app.csv_io) && return
    io = app.csv_io
    t = Dates.now()
    @printf(io, "%s,%.1f,%.6f,TREND,%.8f,%.4f,%.2f,%.2f,%.4f,%.2f,\n",
        t, pt.cum_time_ms, pt.cum_vol_mL,
        pt.uv, pt.cond_mScm, pt.ph, pt.pctb, pt.pres_MPa, pt.temp_degC)
    flush(io)
end

function write_csv_event(app::AppState, ev::AktaEvent)
    isnothing(app.csv_io) && return
    io = app.csv_io
    t = Dates.now()
    msg = replace(ev.text, ',' => ';', '\n' => ' ')
    @printf(io, "%s,%.1f,%.6f,%s,,,,,,,\"%s\"\n",
        t, ev.cum_time_ms, ev.cum_vol_mL, string(ev.kind), msg)
    flush(io)
end

# ── CSV log reader ────────────────────────────────────────────────────────────

const _EVENT_KIND_MAP = Dict(
    "EVT_CONNECT" => EVT_CONNECT,
    "EVT_DISCONNECT" => EVT_DISCONNECT,
    "EVT_RUN_STATE" => EVT_RUN_STATE,
    "EVT_INJECT" => EVT_INJECT,
    "EVT_TUBEFEED" => EVT_TUBEFEED,
    "EVT_LOG" => EVT_LOG,
    "EVT_STEP" => EVT_STEP,
    "EVT_MARK" => EVT_MARK,
    "EVT_INFO" => EVT_INFO,
)

"""
Replay events in order to rebuild the fractions list from scratch.
Scans EVT_LOG and EVT_TUBEFEED text for "Fraction size" and "Feed Tube Nr" patterns.
"""
function _rebuild_fractions!(app::AppState)
    inst = app.inst[]
    inst.fraction_number = 1
    inst.fraction_vol_mL = 0.0
    inst.current_fraction_idx = nothing
    empty!(app.fractions[])

    for ev in app.events[]
        inst.cum_time_ms = ev.cum_time_ms
        inst.cum_vol_mL = ev.cum_vol_mL

        changed = false
        if ev.kind == EVT_LOG || ev.kind == EVT_TUBEFEED
            if (m = match(r"Fraction size\s+([0-9]+(?:\.[0-9]+)?)\s+ml"i, ev.text)) !== nothing
                inst.fraction_vol_mL = parse(Float64, m.captures[1])
                changed = true
            end
            if (m = match(r"Feed Tube Nr\s+(\d+)"i, ev.text)) !== nothing
                inst.fraction_number = max(1, parse(Int, m.captures[1]))
                changed = true
            end
        end
        changed && update_fraction_state!(app)
    end
end

"""
Parse an Akta CSV log file and populate `app` with trend points, events, and
reconstructed fractions.  The app is left with `csv_io = nothing` (read-only).
"""
function load_csv_log!(app::AppState, filename::String)
    trend = TrendPoint[]
    events = AktaEvent[]

    open(filename, "r") do io
        for line in eachline(io)
            startswith(line, '#') && continue
            startswith(line, "wall_time") && continue
            isempty(strip(line)) && continue

            # Limit to 11 fields; the 11th is the (possibly quoted) message
            parts = split(line, ','; limit=11)
            length(parts) < 4 && continue

            cum_time_ms = tryparse(Float64, parts[2])
            cum_vol_mL = tryparse(Float64, parts[3])
            (isnothing(cum_time_ms) || isnothing(cum_vol_mL)) && continue

            row_type = strip(parts[4])

            if row_type == "TREND"
                length(parts) < 10 && continue
                uv = something(tryparse(Float64, parts[5]), 0.0)
                cond = something(tryparse(Float64, parts[6]), 0.0)
                ph = something(tryparse(Float64, parts[7]), 0.0)
                pctb = something(tryparse(Float64, parts[8]), 0.0)
                pres = something(tryparse(Float64, parts[9]), 0.0)
                temp = something(tryparse(Float64, parts[10]), 0.0)
                push!(trend, TrendPoint(cum_time_ms, cum_vol_mL,
                    uv, cond, ph, pctb, pres, temp))
            elseif haskey(_EVENT_KIND_MAP, row_type)
                kind = _EVENT_KIND_MAP[row_type]
                msg = length(parts) >= 11 ? strip(strip(parts[11]), '"') : ""
                push!(events, AktaEvent(cum_time_ms, cum_vol_mL, kind, msg))
            end
        end
    end

    app.trend_data[] = trend
    app.events[] = events
    notify(app.trend_data)
    notify(app.events)

    _rebuild_fractions!(app)
    notify(app.fractions)

    @info "Loaded $(length(trend)) trend points and $(length(events)) events from \"$filename\""
end
