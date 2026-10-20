# settings.jl — user settings, saved with Preferences.jl (LocalPreferences.toml)
# and edited on the Settings page of the GUI.

const SERIAL_PORT_PREFERENCE_KEY = "serial_port"
const VOLUME_UNIT_PREFERENCE_KEY = "volume_unit_uL"   # 10 for ÄKTAprime plus, 1 for ÄKTAprime
const DEMO_MODE_PREFERENCE_KEY = "demo_mode"
const LOG_PREFIX_PREFERENCE_KEY = "log_prefix"
const DATA_DIR_PREFERENCE_KEY = "data_dir"
const DARK_MODE_PREFERENCE_KEY = "dark_mode"
const REFRESH_PREFERENCE_KEY = "refresh_hz"
const RUN_INFO_PREFERENCE_KEY = "run_info"
const START_PANELS_PREFERENCE_KEY = "start_panels"
const SAVE_RAW_PREFERENCE_KEY = "save_raw"
const ALL_PANELS = ["%B", "Cond", "pH", "Pressure", "Flow"]   # switchable plot panels (UV is always shown)

mutable struct Settings
    demo_mode::Bool          # simulated data instead of the instrument
    serial_port::String
    volume_unit_uL::Float64  # µL per volume count
    log_prefix::String       # CSV files are named <prefix>_<date>_<time>.csv
    data_dir::String         # folder for log files and plots; "" = current folder
    dark_mode::Bool          # dark colour theme (applied at start)
    refresh_hz::Float64      # live GUI refreshes per second
    run_info::Dict{String,String}   # sample, column, buffer names… (runinfo.jl)
    start_panels::Vector{String}    # plot panels switched on when a page opens
    save_raw::Bool                  # also save every instrument message (_raw.txt) and method dumps (.met)
end
# Defaults for the fields added later: every panel shown, no raw capture.
Settings(demo, port, unit, prefix, dir, dark, refresh, info) =
    Settings(demo, port, unit, prefix, dir, dark, refresh, info, copy(ALL_PANELS))
Settings(demo, port, unit, prefix, dir, dark, refresh, info, panels) =
    Settings(demo, port, unit, prefix, dir, dark, refresh, info, panels, false)

load_settings() = Settings(
    @load_preference(DEMO_MODE_PREFERENCE_KEY, false),
    @load_preference(SERIAL_PORT_PREFERENCE_KEY, DEFAULT_SERIAL_PORT),
    Float64(@load_preference(VOLUME_UNIT_PREFERENCE_KEY, DEFAULT_VOLUME_UNIT_UL)),
    @load_preference(LOG_PREFIX_PREFERENCE_KEY, "akta"),
    @load_preference(DATA_DIR_PREFERENCE_KEY, ""),
    @load_preference(DARK_MODE_PREFERENCE_KEY, false),
    Float64(@load_preference(REFRESH_PREFERENCE_KEY, 2.0)),
    Dict{String,String}(string(k) => string(v)
                        for (k, v) in @load_preference(RUN_INFO_PREFERENCE_KEY, Dict{String,Any}())),
    String.(@load_preference(START_PANELS_PREFERENCE_KEY, ALL_PANELS)),
    @load_preference(SAVE_RAW_PREFERENCE_KEY, false),
)

# The data folder in use: the saved one if it exists or can be created, else
# the current folder.
function data_dir(s::Settings)::String
    isempty(s.data_dir) && return pwd()
    try
        mkpath(s.data_dir)
        return s.data_dir
    catch err
        @warn "Data folder $(s.data_dir) is not usable — saving to $(pwd()) instead" exception = err
        return pwd()
    end
end

function save_settings(s::Settings)
    @set_preferences!(
        DEMO_MODE_PREFERENCE_KEY => s.demo_mode,
        SERIAL_PORT_PREFERENCE_KEY => s.serial_port,
        VOLUME_UNIT_PREFERENCE_KEY => s.volume_unit_uL,
        LOG_PREFIX_PREFERENCE_KEY => s.log_prefix,
        DATA_DIR_PREFERENCE_KEY => s.data_dir,
        DARK_MODE_PREFERENCE_KEY => s.dark_mode,
        REFRESH_PREFERENCE_KEY => s.refresh_hz,
        RUN_INFO_PREFERENCE_KEY => s.run_info,
        START_PANELS_PREFERENCE_KEY => s.start_panels,
        SAVE_RAW_PREFERENCE_KEY => s.save_raw,
    )
end
