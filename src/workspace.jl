# workspace.jl — the application window: a top bar with tabs (live data, opened
# runs, settings) and menu buttons, above the page of the active tab. Every page
# is its own Figure; switching tabs displays that Figure in the same window.


mutable struct Page
    title::String
    fig::Figure
    closable::Bool
    listeners::Vector{Any}       # its top bar's subscriptions, released when it closes
    on_screen::Observable{Bool}  # live pages pause their refresh while not shown
end

mutable struct Workspace
    acq::Acquisition
    screen::Any                  # the GLMakie window, once displayed
    pages::Vector{Page}
    active::Union{Nothing,Page}
    tabs_changed::Observable{Int}
    notice::Observable{String}   # last error of a menu action, shown in the top bar
    settings_page::Union{Nothing,Page}   # built once (ahead of time) and reused
    editor_only::Bool            # only the method editor (--methods): no menu buttons
end
Workspace(acq::Acquisition; editor_only::Bool=false) =
    Workspace(acq, nothing, Page[], nothing, Observable(0), Observable(""), nothing, editor_only)

# Runs `f` after the current GUI callback returns: a tab button must not delete
# itself, or replace the figure it belongs to, from inside its own click handler.
# Errors in such a background task would vanish silently, so they are logged and,
# when `ws` is given, shown in the top bar.
_later(f, ws=nothing) = @async begin
    yield()
    try
        f()
    catch err
        @error "GUI action failed" exception = (err, catch_backtrace())
        isnothing(ws) || (ws.notice[] = "Error: " * first(sprint(showerror, err), 120))
    end
end

# Builds the top bar into `pos`; every page has its own copy, kept in sync.
function _topbar(ws::Workspace, listeners::Vector{Any})
    return function (pos)
        bar = GridLayout(pos; tellwidth=false)
        tabs = GridLayout(bar[1, 1]; halign=:left)
        Label(bar[1, 2], ws.notice; halign=:right, fontsize=FS_BODY, color=ui().err,
            tellwidth=false)            # also pushes the menu buttons to the right edge
        if !ws.editor_only
            open_btn = Button(bar[1, 3]; label="Open run…", fontsize=13)
            info_btn = Button(bar[1, 4]; label="Run info", fontsize=13)
            meth_btn = Button(bar[1, 5]; label="Methods", fontsize=13)
            set_btn = Button(bar[1, 6]; label="Settings", fontsize=13)
        end
        colgap!(bar, 10)

        # Flat tabs: title (+ close ×) on the bar colour, the active one in bold
        # accent with an accent underline. No outlines, which clip at the edges.
        tab_items = Any[]
        rebuild() = batch_layout(_rebuild, pos.layout)
        function _rebuild()
            foreach(delete!, tab_items)
            empty!(tab_items)
            trim!(tabs)
            p = ui()
            col = 0
            within = Int[]                    # column gaps between a title and its ×
            for page in ws.pages
                active = page === ws.active
                style = (fontsize=FS_BODY, strokewidth=0, cornerradius=4,
                    buttoncolor=p.bg, buttoncolor_hover=p.accent_soft, buttoncolor_active=p.accent_soft,
                    labelcolor=active ? p.accent : p.text, labelcolor_hover=p.text)
                first_col = col + 1
                b = Button(tabs[1, col+=1]; label=page.title, font=active ? :bold : :regular, style...)
                on(_ -> _later(() -> show_page!(ws, page), ws), b.clicks)
                push!(tab_items, b)
                if page.closable
                    push!(within, col)
                    x = Button(tabs[1, col+=1]; label="×", padding=(4, 8, 5, 5), style...)
                    on(_ -> _later(() -> close_page!(ws, page), ws), x.clicks)
                    push!(tab_items, x)
                end
                push!(tab_items, Box(tabs[2, first_col:col]; height=2, strokevisible=false,
                    color=active ? p.accent : RGBAf(0, 0, 0, 0)))
            end
            for c in 1:col-1
                colgap!(tabs, c, c in within ? Fixed(0) : Fixed(10))
            end
            rowgap!(tabs, 0)
        end
        push!(listeners, on(_ -> rebuild(), ws.tabs_changed))
        rebuild()

        ws.editor_only && return
        on(_ -> _later(() -> open_run!(ws), ws), open_btn.clicks)
        on(_ -> _later(() -> open_settings!(ws), ws), set_btn.clicks)
        on(_ -> _later(() -> open_runinfo!(ws), ws), info_btn.clicks)
        on(_ -> _later(() -> open_methods!(ws), ws), meth_btn.clicks)
    end
end

# `build(topbar, on_screen)` returns the page's Figure. With `tab=false` the page
# is built but only gets a tab when first shown (used to prepare Settings).
function _new_page(build, ws::Workspace, title::String, closable::Bool)::Page
    listeners = Any[]
    on_screen = Observable(false)
    return Page(title, build(_topbar(ws, listeners), on_screen), closable, listeners, on_screen)
end

function add_page!(build, ws::Workspace, title::String; closable::Bool=true)::Page
    page = _new_page(build, ws, title, closable)
    push!(ws.pages, page)
    return page
end

function show_page!(ws::Workspace, page::Page)
    page in ws.pages || push!(ws.pages, page)
    ws.active = page
    for p in ws.pages
        p.on_screen[] == (p === page) || (p.on_screen[] = p === page)
    end
    ws.tabs_changed[] += 1
    isnothing(ws.screen) || display(ws.screen, page.fig)
end

function close_page!(ws::Workspace, page::Page)
    page.closable || return
    filter!(p -> p !== page, ws.pages)
    page.on_screen[] = false
    page === ws.settings_page || foreach(off, page.listeners)   # Settings is kept for reuse
    ws.active === page ? show_page!(ws, first(ws.pages)) : (ws.tabs_changed[] += 1)
end

# ── Open run… ────────────────────────────────────────────────────────────────
function open_run!(ws::Workspace)
    ws.notice[] = ""
    path = NativeFileDialog.pick_file(data_dir(ws.acq.settings); filterlist="csv")
    @debug "File dialog returned: $(repr(path))"
    isempty(path) && return
    isfile(path) || error("$path is not a file")
    title = basename(path)
    existing = findfirst(p -> p.title == title, ws.pages)
    isnothing(existing) || return show_page!(ws, ws.pages[existing])

    # Parse the file on a worker thread; this task waits without blocking the
    # window. The new AppState has no listeners yet, so filling it there is safe.
    # The serial link permanently occupies one worker thread, so a second one is
    # needed; without it the load would wait for the link and is done here instead.
    app = AppState()
    Threads.nthreads(:default) >= 2 ? fetch(Threads.@spawn load_csv_log!(app, path)) :
                                      load_csv_log!(app, path)
    app.log_filename = path
    app.log_dir = dirname(path)        # plots exported from this tab go next to the CSV,
    app.log_prefix = replace(basename(path), r"\.csv$"i => "")   # named after the run
    @info "Opened $path"
    show_page!(ws, add_page!((topbar, on_screen) ->
            build_gui(app; viewer=true, topbar, on_screen, status=ws.acq.status,
                start_panels=ws.acq.settings.start_panels), ws, title))
end

# ── Settings ─────────────────────────────────────────────────────────────────
const REFRESH_HZ = [1.0, 2.0, 4.0, 10.0]
const REFRESH_OPTIONS = ["1× per second", "2× per second", "4× per second", "10× per second"]
_refresh_label(hz) = REFRESH_OPTIONS[something(findfirst(==(hz), REFRESH_HZ), 2)]

const VOLUME_UNIT_OPTIONS = ["1 µL per count (ÄKTAprime)", "10 µL per count (ÄKTAprime plus)"]

# ── Run info ─────────────────────────────────────────────────────────────────
function open_runinfo!(ws::Workspace)
    existing = findfirst(p -> p.title == "Run info", ws.pages)
    isnothing(existing) || return show_page!(ws, ws.pages[existing])
    show_page!(ws, add_page!((topbar, _) -> _runinfo_figure(ws, topbar), ws, "Run info"))
end

function _runinfo_figure(ws::Workspace, topbar)::Figure
    acq, s = ws.acq, ws.acq.settings
    fig = Figure(size=(1440, 900))
    fig.layout.block_updates = true     # one layout solve once the page is built
    topbar(fig[1, 1])
    g = GridLayout(fig[2, 1]; halign=:left, valign=:top, tellwidth=false, tellheight=false,
        alignmode=Outside(40))
    Label(g[1, 1:4], "Run info"; halign=:left, fontsize=20, font=:bold)
    Label(g[2, 1:4], "Recorded in the log of the current run and kept for the next runs. " *
                     "Name the buffers on the buffer valve ports you use.";
        halign=:left, fontsize=FS_BODY, color=ui().muted)
    boxes = Dict{String,Textbox}()
    # Two columns: run details left, buffer names right.
    left_fields = ["Sample", "User", "Column", "Column volume (mL)", "Buffer B", "Notes"]
    right_fields = ["Port $i" for i in 1:8]
    for (col, fields) in ((1, left_fields), (3, right_fields)), (r, key) in enumerate(fields)
        Label(g[r+2, col], key == "Port 1" ? "Port 1 (A)" : key == "Port 8" ? "Port 8 (sample)" : key;
            halign=:right, fontsize=FS_BODY)
        boxes[key] = Textbox(g[r+2, col+1]; stored_string=get(s.run_info, key, ""),
            placeholder=key == "Column volume (mL)" ? "e.g. 1.0" : "", width=key == "Notes" ? 420 : 260,
            fontsize=FS_BODY, halign=:left)
    end
    save = Button(g[12, 2]; label="Save", fontsize=FS_BODY, halign=:left)
    feedback = Label(g[13, 1:4], ""; halign=:left, fontsize=FS_BODY, color=ui().ok)
    rowgap!(g, 10)
    colgap!(g, 14)
    colgap!(g, 2, 40)

    on(save.clicks) do _
        for (key, tb) in boxes
            s.run_info[key] = strip(something(tb.displayed_string[], ""))
        end
        save_settings(s)
        log_run_info!(acq.app, s.run_info; only_changed=true)
        feedback.text = "Saved" * (isnothing(acq.app.csv_io) ? "." : " and recorded in $(basename(acq.app.log_filename)).")
    end
    finish_layout!(fig)
    return fig
end

# Builds the Settings page without showing it, so the first click is quick.
function prepare_settings!(ws::Workspace)
    isnothing(ws.settings_page) &&
        (ws.settings_page = _new_page((topbar, _) -> _settings_figure(ws, topbar), ws, "Settings", true))
    return ws.settings_page
end

open_settings!(ws::Workspace) = show_page!(ws, prepare_settings!(ws))

function _settings_figure(ws::Workspace, topbar)::Figure
    acq, s = ws.acq, ws.acq.settings
    fig = Figure(size=(1440, 900))
    fig.layout.block_updates = true     # one layout solve once the page is built
    topbar(fig[1, 1])
    g = GridLayout(fig[2, 1]; halign=:left, valign=:top, tellwidth=false, tellheight=false,
        alignmode=Outside(40))
    lbl(row, txt) = Label(g[row, 1], txt; halign=:right, fontsize=15)
    note(row, txt) = Label(g[row, 3], txt; halign=:left, fontsize=FS_SMALL + 1, color=ui().muted)

    Label(g[1, 1:3], "Settings"; halign=:left, fontsize=20, font=:bold)

    lbl(2, "Demo mode")
    demo = Toggle(g[2, 2]; active=s.demo_mode, halign=:left)
    note(2, "Simulated data for testing; no instrument needed.")

    lbl(3, "Serial port")
    port = Textbox(g[3, 2]; stored_string=s.serial_port, width=260, fontsize=14,
        halign=:left)
    note(3, "Press Enter to apply, e.g. /dev/ttyUSB0 (Linux) or COM3 (Windows).")

    lbl(4, "Volume unit")
    unit = Menu(g[4, 2]; options=VOLUME_UNIT_OPTIONS, width=260, fontsize=14, halign=:left,
        default=s.volume_unit_uL == 1.0 ? VOLUME_UNIT_OPTIONS[1] : VOLUME_UNIT_OPTIONS[2])
    note(4, "Applies to data received from now on.")

    lbl(5, "Log file prefix")
    prefix = Textbox(g[5, 2]; stored_string=s.log_prefix, width=260, fontsize=14,
        halign=:left)
    note(5, "Press Enter to apply. Used for the next log file: <prefix>_<date>_<time>.csv")

    lbl(6, "Data folder")
    choose = Button(g[6, 2]; label="Choose…", fontsize=13, halign=:left)
    folder = Label(g[6, 3], data_dir(s); halign=:left, fontsize=14)
    note(7, "Log files, method dumps and exported plots are saved here, from the next log file on.")

    lbl(9, "Display refresh")
    refresh = Menu(g[9, 2]; options=REFRESH_OPTIONS, width=260, fontsize=14, halign=:left,
        default=_refresh_label(s.refresh_hz))
    note(9, "How often live plots redraw. Lower is lighter on the computer; data is recorded in full either way.")

    lbl(8, "Dark mode")
    dark = Toggle(g[8, 2]; active=s.dark_mode, halign=:left)
    note(8, "Applies at the next start of the program.")

    lbl(10, "Panels shown at start")
    pg = GridLayout(g[10, 2]; halign=:left, default_colgap=12)
    panel_boxes = map(enumerate(ALL_PANELS)) do (i, name)
        sub = GridLayout(pg[1, i]; default_colgap=4)
        cb = Checkbox(sub[1, 1]; checked=name in s.start_panels)
        Label(sub[1, 2], name; fontsize=FS_BODY)
        name => cb
    end
    note(10, "Plots switched on when the program starts or a run is opened (UV is always shown).")

    lbl(11, "Save raw instrument data")
    raw = Toggle(g[11, 2]; active=s.save_raw, halign=:left)
    note(11, "For troubleshooting: also saves every instrument message (_raw.txt) and method dumps (.met). From the next log file on.")

    feedback = Label(g[12, 1:3], ""; halign=:left, fontsize=FS_BODY, color=ui().ok)
    rowgap!(g, 14)
    colgap!(g, 16)

    # Every change is saved at once; source changes restart the acquisition.
    function changed!(msg; restart=false)
        save_settings(s)
        restart && restart!(acq)
        feedback.text = msg
    end
    on(demo.active) do on_
        s.demo_mode == on_ && return
        s.demo_mode = on_
        _later(() -> changed!(on_ ? "Demo mode on — showing simulated data." :
                                    "Demo mode off — connecting to $(s.serial_port)."; restart=true), ws)
    end
    on(port.stored_string) do str
        str = strip(something(str, ""))
        (isempty(str) || str == s.serial_port) && return
        s.serial_port = str
        _later(() -> changed!("Serial port set to $str." * (s.demo_mode ? "" : " Reconnecting.");
            restart=!s.demo_mode), ws)
    end
    on(unit.selection) do sel
        unit_uL = sel == VOLUME_UNIT_OPTIONS[1] ? 1.0 : 10.0
        s.volume_unit_uL == unit_uL && return
        s.volume_unit_uL = VOLUME_UNIT_UL[] = unit_uL
        changed!("Volume unit set to $(Int(unit_uL)) µL per count.")
    end
    on(choose.clicks) do _
        _later(ws) do
            dir = try
                NativeFileDialog.pick_folder(data_dir(s))
            catch err
                @error "Could not open the folder dialog" exception = err
                ""
            end
            (isempty(dir) || dir == s.data_dir) && return
            s.data_dir = dir
            acq.app.log_dir = data_dir(s)
            METHOD_DIR[] = method_dir(acq.app.log_dir)
            METHODS_CHANGED[] += 1
            folder.text = acq.app.log_dir
            changed!("Data folder set to $(acq.app.log_dir); the next log file goes there, " *
                     "and the Akta's methods are stored in $(METHOD_DIR[]).")
        end
    end
    for (name, cb) in panel_boxes
        on(cb.checked) do _
            s.start_panels = [n for (n, c) in panel_boxes if c.checked[]]
            changed!("Panels shown at start: " * (isempty(s.start_panels) ? "UV only" : join(s.start_panels, ", ")) * ".")
        end
    end
    on(raw.active) do on_
        s.save_raw == on_ && return
        s.save_raw = on_
        changed!((on_ ? "Raw instrument data will be saved" : "Raw instrument data will not be saved") *
                 ", from the next log file on.")
    end
    on(refresh.selection) do sel
        hz = REFRESH_HZ[findfirst(==(sel), REFRESH_OPTIONS)]
        s.refresh_hz == hz && return
        s.refresh_hz = hz
        GUI_REFRESH_S[] = 1 / hz
        changed!("Display refresh set to $sel.")
    end
    on(dark.active) do on_
        s.dark_mode == on_ && return
        s.dark_mode = on_
        changed!((on_ ? "Dark" : "Light") * " mode saved; restart the program to apply it.")
    end
    on(prefix.stored_string) do str
        str = strip(something(str, ""))
        (isempty(str) || str == s.log_prefix) && return
        s.log_prefix = acq.app.log_prefix = str
        changed!("Log prefix set to \"$str\"; the next log file will use it.")
    end
    finish_layout!(fig)
    return fig
end
