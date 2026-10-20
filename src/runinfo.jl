# runinfo.jl — run documentation: sample, user, column, buffer names per buffer
# valve port, notes. Kept as a setting (the next run usually uses the same column
# and buffers) and written into every log as EVT_INFO events ("Sample: …"), so a
# CSV documents itself and an opened old run shows its own information.

const RUN_INFO_FIELDS = ["Sample", "User", "Column", "Column volume (mL)", "Buffer B",
    "Port 1", "Port 2", "Port 3", "Port 4", "Port 5", "Port 6", "Port 7", "Port 8", "Notes"]

# Latest value of every field recorded in `events`.
function run_info(events::AbstractVector{AktaEvent})::Dict{String,String}
    info = Dict{String,String}()
    for e in events
        e.kind == EVT_INFO || continue
        key, _, value = _split_once(e.text, ": ")
        isempty(value) || (info[key] = value)
    end
    return info
end
_split_once(s::AbstractString, sep) = (i = findfirst(sep, s); isnothing(i) ? (s, "", "") :
                                                            (s[1:prevind(s, first(i))], sep, s[nextind(s, last(i)):end]))

# Column volume in mL from the run information, or 0 when not given.
column_volume(info::AbstractDict) =
    max(0.0, something(tryparse(Float64, replace(get(info, "Column volume (mL)", ""), ',' => '.')), 0.0))

# Record `info` in the current log; `only_changed` skips fields already recorded.
function log_run_info!(app::AppState, info::AbstractDict; only_changed::Bool=false)
    recorded = only_changed ? run_info(app.events[]) : Dict{String,String}()
    for key in RUN_INFO_FIELDS
        value = strip(get(info, key, ""))
        (isempty(value) || get(recorded, key, "") == value) && continue
        push_event!(app, EVT_INFO, "$key: $value")
    end
end
