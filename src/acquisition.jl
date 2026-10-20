# acquisition.jl — the live data source (instrument link or demo), which can be
# stopped and restarted with new settings while the window stays open.

mutable struct Acquisition
    app::AppState
    settings::Settings
    status::Observable{String}   # connection state, shown in the top bar
    shutdown::Ref{Bool}
    task::Union{Nothing,Task}
    consumer::Union{Nothing,Task}
end
Acquisition(app::AppState, settings::Settings) =
    Acquisition(app, settings, Observable(""), Ref(false), nothing, nothing)

# A fresh log file name; never reuses an existing file (two starts in one second).
function _unique_logname(app::AppState)::String
    name = newlogname(app)
    n = 1
    while isfile(name)
        n += 1
        name = replace(newlogname(app), r"\.csv$" => "_$n.csv")
    end
    return name
end

# Close the current log. One that never received data (e.g. no instrument came)
# is deleted together with its raw capture.
function _close_log!(app::AppState)
    raw = replace(app.log_filename, r"\.csv$" => "_raw.txt")
    isnothing(RAW_IO[]) || (close(RAW_IO[]); RAW_IO[] = nothing)
    isnothing(app.csv_io) && return
    close(app.csv_io)
    app.csv_io = nothing
    has_data = !isempty(app.trend_data[]) ||
               any(e -> e.kind ∉ (EVT_CONNECT, EVT_INFO) && !startswith(e.text, "Link:"), app.events[])
    if !has_data
        rm(app.log_filename; force=true)
        rm(raw; force=true)
        @info "Discarded $(app.log_filename): no data recorded"
    end
end

function start!(acq::Acquisition)
    app, s = acq.app, acq.settings
    VOLUME_UNIT_UL[] = s.volume_unit_uL
    app.log_prefix = s.log_prefix
    app.log_dir = data_dir(s)
    METHOD_DIR[] = method_dir(app.log_dir)
    app.inst[] = InstrumentState()          # nothing is known about the new source yet
    resetrun!(app)
    app.log_filename = _unique_logname(app)
    app.csv_io = init_csv(app.log_filename)
    # Every log, including the new file started for each run, opens with the run information.
    ON_NEW_LOG[] = a -> log_run_info!(a, s.run_info)
    ON_NEW_LOG[](app)
    acq.shutdown = Ref(false)

    if s.demo_mode
        @info "Starting demo mode"
        acq.status[] = "Demo mode — simulated data"
        acq.consumer = nothing
        acq.task = @async Base.invokelatest(run_demo, acq.shutdown, app)
    else
        @info "Connecting to Akta at $(s.serial_port)"
        s.save_raw && (RAW_IO[] = open(replace(app.log_filename, r"\.csv$" => "_raw.txt"), "w"))
        acq.status[] = "Opening $(s.serial_port) …"
        # The link polls on its own thread, so a busy GUI cannot silence it; what
        # it receives is applied here on the main thread (see run_linklayer).
        rx_actions = Channel{Function}(Inf)
        acq.consumer = @async for action in rx_actions
            try
                Base.invokelatest(action)
            catch err
                @error "Error handling Akta data" exception = (err, catch_backtrace())
            end
        end
        # Unbounded: the link thread queues a method load (dozens of messages) itself,
        # so a bounded queue could fill up and block the only task that empties it.
        tx_queue = Channel{Tuple{UInt16,Vector{UInt8}}}(Inf)
        task = Threads.@spawn :default Base.invokelatest(run_linklayer, tx_queue, acq.shutdown,
            app, s.serial_port; rx_actions, status=acq.status)
        # Once the link has stopped, let the consumer finish what is still queued.
        @async (try wait(task) catch end; close(rx_actions))
        acq.task = task
    end
    return acq
end

function stop!(acq::Acquisition)
    acq.shutdown[] = true
    for t in (acq.task, acq.consumer)
        isnothing(t) || try wait(t) catch end
    end
    acq.task = acq.consumer = nothing
    _close_log!(acq.app)
    acq.status[] = "Stopped"
    return acq
end

restart!(acq::Acquisition) = (stop!(acq); start!(acq))
