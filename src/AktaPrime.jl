module AktaPrime

using Dates
using Logging
using Printf
using Observables
using GLMakie
import CairoMakie   # used only to export plots to PDF; GLMakie stays the interactive backend
using LibSerialPort
using Preferences
import NativeFileDialog

include("types.jl")
include("csv_writer.jl")   # must come before protocol (push_event! calls write_csv_event)
include("method.jl")
include("methodstore.jl")
include("protocol.jl")
include("settings.jl")
include("runinfo.jl")
include("theme.jl")
include("gui.jl")
include("acquisition.jl")
include("workspace.jl")
include("methodeditor.jl")

export main

const GITHUB_URL = "https://github.com/waudbylab/AktaPrime.jl"

_is_logfile_arg(path::AbstractString)::Bool = endswith(lowercase(path), ".csv")

function _run_replay(filename::AbstractString)
    filename_str = String(filename)
    isfile(filename_str) || (@error "File not found: $filename_str"; return)
    @info "Replay mode - loading \"$filename_str\""

    apply_theme!(load_settings().dark_mode)
    app = AppState()
    load_csv_log!(app, filename_str)
    app.log_filename = filename_str

    # activate!: ensure the interactive backend (not CairoMakie, used for PDF export)
    GLMakie.activate!(; title="AktaPrime Viewer")
    fig = build_gui(app; viewer=true)
    screen = display(fig)
    @info "GUI opened (replay)"

    Base.exit_on_sigint(false)
    try
        while isopen(screen)
            sleep(0.05)
        end
    catch e
        e isa InterruptException || rethrow()
        @info "Interrupted"
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# run_demo — simulated Akta data stream for testing without hardware
# ─────────────────────────────────────────────────────────────────────────────
const DEMO_FRACTIONS_PER_RUN = 20

function run_demo(shutdown::Ref{Bool}, app::AppState)
    push_event!(app, EVT_CONNECT, "Demo mode — simulated Akta")

    # Repeat runs indefinitely. Each run ends after DEMO_FRACTIONS_PER_RUN
    # fractions; the next one rolls over to a fresh log file (via rolllog!),
    # exercising the automatic per-run restart of logging.
    run_index = 0
    while !shutdown[]
        run_index += 1
        run_index > 1 && rolllog!(app)   # counter restarts → new file, cleared display
        _run_demo_run(shutdown, app)
    end
end

# One simulated chromatographic run: streams until shutdown or until
# DEMO_FRACTIONS_PER_RUN fractions have been collected, then ends the run.
function _run_demo_run(shutdown::Ref{Bool}, app::AppState)
    app.inst[].run_state = "Run"
    notify(app.inst)
    push_event!(app, EVT_RUN_STATE, "Run state: Run  inject=IV_LOAD")

    # 2 s of simulated time per step, 0.2 s sleep → 10× real-time speedup.
    # Flow rate varies between 0.5–2.0 mL/min so time and volume axes diverge visibly.
    step = 0
    cum_vol = 0.0      # accumulated volume in mL (not derived from fixed flow)
    while !shutdown[]
        sleep(0.2)
        step += 1
        t_ms = step * 2_000.0          # 2 s per step (fixed time)
        t_min = t_ms / 60_000

        # Flow rate: 1 mL/min baseline with a slow sinusoidal variation ±0.5 mL/min
        flow_mL_per_min = 1.0 + 0.5 * sin(t_min * 0.8)
        flow_mL_per_ms = flow_mL_per_min / 60_000
        cum_vol += flow_mL_per_ms * 2_000.0  # Δv for this 2 s step
        v_mL = cum_vol

        uv = 0.02 + 1.2 * exp(-((t_min - 4.0)^2) / (2 * 0.4^2)) +
             0.5 * exp(-((t_min - 6.5)^2) / (2 * 0.2^2))
        cond = 10.0 + 2.0 * sin(t_min * 0.5)
        ph = 7.0 + 0.4 * sin(t_min * 0.3)
        pctb = clamp(t_min < 3.0 ? 5.0 : 5.0 + 30.0 * (t_min - 3.0), 5.0, 100.0)
        pres = 0.40 + 0.02 * sin(t_min * 2.0)

        # Keep InstrumentState accumulators in sync so push_event! timestamps events correctly.
        s = app.inst[]
        s.cum_time_ms = t_ms
        s.cum_vol_mL = v_mL

        pt = TrendPoint(t_ms, v_mL, uv, cond, ph, pctb, pres, 22.0)
        push!(app.trend_data[], pt)
        notify(app.trend_data)
        write_csv_trend(app, pt)

        s.run_time_ms = t_ms
        s.run_vol_mL = v_mL
        notify(app.inst)

        # Cycle inject state every 40 demo steps: UNKNOWN -> LOAD -> INJECT -> WASTE.
        if (step - 1) % 40 == 0
            valves = (IV_UNKNOWN, IV_LOAD, IV_INJECT, IV_WASTE)
            idx = mod((step - 1) ÷ 40, length(valves)) + 1
            new_valve = valves[idx]
            app.inst[].inject_value = new_valve
            notify(app.inst)
            push_event!(app, EVT_INJECT, "Valve → $(_inject_label(new_valve)) (demo)")
        end

        # Cycle fraction size every 30 steps, including zero (= route to waste).
        if (step - 1) % 30 == 0
            sizes = (0.0, 0.5, 1.0, 2.0)
            idx = mod((step - 1) ÷ 30, length(sizes)) + 1
            new_size = sizes[idx]
            app.inst[].fraction_vol_mL = new_size
            if update_fraction_state!(app)
                notify(app.fractions)
            end
            notify(app.inst)
            push_event!(app, EVT_LOG, @sprintf("Fraction size %.1f ml", new_size))
        end

        # Advance fraction number periodically only when fraction collection is active.
        if step % 20 == 0 && app.inst[].fraction_vol_mL > 0
            app.inst[].fraction_number += 1
            if update_fraction_state!(app)
                notify(app.fractions)
            end
            notify(app.inst)
            push_event!(app, EVT_TUBEFEED, "Feed Tube Nr $(app.inst[].fraction_number)")

            # End this run once enough fractions have been collected.
            if app.inst[].fraction_number >= DEMO_FRACTIONS_PER_RUN
                app.inst[].run_state = "End"
                notify(app.inst)
                push_event!(app, EVT_RUN_STATE, "Run state: End  inject=IV_LOAD")
                sleep(1.0)   # brief pause so the ended run is visible before restart
                return
            end
        end
    end
end

# ─────────────────────────────────────────────────────────────────────────────
# main application — window with tabs; the live source is chosen in Settings
# ─────────────────────────────────────────────────────────────────────────────
function _run_live(serial_override::Union{Nothing,AbstractString}=nothing)
    global_logger(ConsoleLogger(stderr, Logging.Info))

    # The file dialog (GTK) would otherwise print messages about desktop GTK modules
    # that are not installed here, and about the accessibility bridge.
    delete!(ENV, "GTK_MODULES")
    get!(ENV, "NO_AT_BRIDGE", "1")

    settings = load_settings()
    if !isnothing(serial_override)
        settings.serial_port = String(serial_override)
        save_settings(settings)
    end
    apply_theme!(settings.dark_mode)
    GUI_REFRESH_S[] = 1 / settings.refresh_hz
    _print_banner(settings)
    # Ask for the prefix before anything is recorded; the last one is the default.
    settings.log_prefix = _prompt_log_prefix(settings.log_prefix)
    save_settings(settings)

    app = AppState()
    acq = start!(Acquisition(app, settings))

    # activate!: ensure the interactive backend (not CairoMakie, used for PDF export)
    GLMakie.activate!(; title="AktaPrime")
    ws = Workspace(acq)
    live = add_page!((topbar, on_screen) ->
            build_gui(app; topbar, on_screen, status=acq.status, start_panels=settings.start_panels),
        ws, "Live"; closable=false)
    show_page!(ws, live)
    ws.screen = display(live.fig)
    # Below this size the layout gets too cramped; it still fits a 1366×768 screen.
    try
        GLMakie.GLFW.SetWindowSizeLimits(ws.screen.glscreen, 1100, 680, -1, -1)
    catch err
        @debug "Could not set a minimum window size" exception = err
    end
    @info "GUI opened"
    # Build the Settings page in the background, so its first opening is quick.
    @async (sleep(2); _later(() -> prepare_settings!(ws), ws))

    # ── Run until the window is closed or Ctrl-C ──────────────────────────────
    Base.exit_on_sigint(false)
    try
        while isopen(ws.screen)
            sleep(0.05)
        end
    catch e
        e isa InterruptException || rethrow()
        @info "Interrupted"
    finally
        stop!(acq)                 # applies everything still queued, then closes the files
        _report_output(app)
    end
end

# Only the method editor: no serial link and no log file, e.g. to prepare methods
# away from the instrument (AktaPrime.sh --methods).
function _run_method_editor()
    global_logger(ConsoleLogger(stderr, Logging.Info))
    delete!(ENV, "GTK_MODULES")
    get!(ENV, "NO_AT_BRIDGE", "1")
    settings = load_settings()
    apply_theme!(settings.dark_mode)
    METHOD_DIR[] = method_dir(data_dir(settings))
    @info "Method editor — methods in $(METHOD_DIR[])"
    ws = Workspace(Acquisition(AppState(), settings); editor_only=true)   # never started
    GLMakie.activate!(; title="AktaPrime — Methods")
    page = open_methods!(ws)
    ws.screen = display(page.fig)
    Base.exit_on_sigint(false)
    try
        while isopen(ws.screen)
            sleep(0.05)
        end
    catch e
        e isa InterruptException || rethrow()
    end
end

function _print_banner(s::Settings)
    bar = "─"^64
    println()
    println(bar)
    println("  AktaPrime.jl — Akta PRIME logger")
    println("  $GITHUB_URL")
    println(bar)
    println()
    println(s.demo_mode ? "  DEMO MODE — simulated data (switch off under Settings)." :
                          "  Serial port: $(s.serial_port) (change under Settings).")
    println()
    println("  Data are saved as CSV files in the data folder (change in Settings):")
    println("      $(data_dir(s))")
    println("  Methods the Akta saves to or loads from the PC are in")
    println("      $(method_dir(data_dir(s)))")
    println("  named <prefix>_<date>_<time>.csv. A new file is started for every")
    println("  run; logs without any data are discarded.")
    println()
    println("  The prefix is a label to help you find these files later, such as")
    println("  a sample name or your initials. It can also be changed in Settings.")
    println(bar)
    println()
end

function _prompt_log_prefix(default_prefix::AbstractString)::String
    print("  Log-file prefix  (press ENTER for \"$default_prefix\"): ")
    input = eof(stdin) ? "" : strip(readline())
    println()
    return isempty(input) ? String(default_prefix) : String(input)
end

function _report_output(app::AppState)
    bar = "─"^64
    println()
    println(bar)
    @info "Logging stopped — $(length(app.trend_data[])) trend points in the final run"
    println()
    println("  Data saved in:")
    println("      $(isempty(app.log_dir) ? pwd() : app.log_dir)")
    println()
    println("  Files this session are named:")
    println("      $(app.log_prefix)_<date>_<time>.csv")
    println()
    println("  Most recent run: $(basename(app.log_filename))")
    println(bar)
end

function main()
    _run_live(nothing)
end

function main(arg::AbstractString)
    arg == "--methods" && return _run_method_editor()
    if _is_logfile_arg(arg)
        global_logger(ConsoleLogger(stderr, Logging.Info))
        _run_replay(arg)
        return
    end
    _run_live(arg)
end

function main(args::Vector{String})
    if isempty(args)
        return main()
    elseif length(args) == 1
        return main(args[1])
    end
    @error "Usage: AktaPrime [serial_port|logfile.csv|--methods]"
    return
end

function (@main)(args)
    main(collect(args))
end

include("precompile.jl")

end # module
