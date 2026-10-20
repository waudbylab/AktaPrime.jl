# warmup.jl — run while building the system image (build.jl): uses the GUI the
# way a session does, in an invisible window, so all of it is compiled into the
# image. Only temporary folders are used and no setting is changed or saved
# (anything this script did to the program would be baked into the image).

import AktaPrime     # import, not using: `using` would make Julia run the app (main) at the end
using GLMakie
const A = AktaPrime

dir = mktempdir()
GLMakie.activate!(visible=false)
A.apply_theme!(false)

# A run with data and every kind of event.
app = A.AppState()
for i in 1:4000
    t = i / 8 / 60
    push!(app.trend_data[], A.TrendPoint(t * 60_000, t / 2, exp(-(t - 4)^2), 10 + sin(t), 7.0,
        clamp(10t, 0, 100), 0.3, 21.0))
end
for (k, (kind, txt)) in enumerate(((A.EVT_RUN_STATE, "Run state: Run  inject=IV_LOAD"), (A.EVT_LOG, "Flow 0.5 ml/min"),
    (A.EVT_LOG, "Buffer Valve Pos 3"), (A.EVT_STEP, "Step"), (A.EVT_LOG, "Injection Valve Inj"),
    (A.EVT_LOG, "Fraction size 1.0 ml"), (A.EVT_MARK, "mark"), (A.EVT_INFO, "Sample: test")))
    push!(app.events[], A.AktaEvent(k * 30_000.0, k * 0.25, kind, txt))
end
app.csv_io = devnull
app.log_dir = dir
app.log_filename = joinpath(dir, "warmup.csv")

settings = A.Settings(true, "/dev/null", 1.0, "warmup", dir, false, 2.0, Dict("Column volume (mL)" => "1.0"))
acq = A.Acquisition(app, settings)
acq.status[] = "● Connected on /dev/null"
ws = A.Workspace(acq)
live = A.add_page!((tb, os) -> A.build_gui(app; topbar=tb, on_screen=os, status=acq.status), ws, "Live";
    closable=false)
A.show_page!(ws, live)
ws.screen = display(live.fig)
fig = live.fig
frame() = Makie.colorbuffer(ws.screen)
frame()

find(T, pred=_ -> true) = fig.content[findfirst(c -> c isa T && pred(c), fig.content)]
checks = [c for c in fig.content if c isa Checkbox]   # Show log, %B, Cond, pH, Pressure, Flow, Follow live
logbox, followbox = checks[1], checks[7]
for _ in 1:3                                           # live refreshes
    push!(app.trend_data[], app.trend_data[][end]); notify(app.trend_data); notify(app.inst)
    sleep(0.6); frame()
end
slider = find(Slider); set_close_to!(slider, 1000); frame(); set_close_to!(slider, length(slider.range[])); frame()
ax = find(Axis, a -> a.ylabel[] == "UV (AU)")
xlims!(ax, 1, 3); frame()
followbox.checked[] = false; followbox.checked[] = true; frame()          # follow live
checks[2].checked[] = false; frame(); checks[2].checked[] = true; frame() # panel toggle
menu = find(Menu)
for sel in ("Plot vs volume", "Plot vs column volumes", "Plot vs time"); menu.selection[] = sel; frame(); end
vp = ax.scene.viewport[]
events(fig).mouseposition[] = (vp.origin[1] + vp.widths[1] / 2, vp.origin[2] + vp.widths[2] / 2); frame()
events(fig).mouseposition[] = (1.0, 1.0); frame()
ovb = find(Button, b -> b.label[] == "Overlay"); ovb.clicks[] += 1; frame()
find(Button, b -> startswith(b.label[], "━━")).clicks[] += 1; frame()
ovb.clicks[] += 1; frame()
logbox.checked[] = true; frame(); logbox.checked[] = false; frame()  # run log
find(Button, b -> b.label[] == "Save plot…").clicks[] += 1                # PDF export (into dir)

# other pages: Settings, Run info, an opened run
A.show_page!(ws, A.prepare_settings!(ws)); frame()
A.open_runinfo!(ws); frame()
path = joinpath(dir, "old.csv")
w = A.AppState(); w.csv_io = A.init_csv(path)
foreach(p -> A.write_csv_trend(w, p), app.trend_data[]); foreach(e -> A.write_csv_event(w, e), app.events[])
close(w.csv_io)
run = A.AppState(); fetch(Threads.@spawn A.load_csv_log!(run, path))
page = A.add_page!((tb, os) -> A.build_gui(run; viewer=true, topbar=tb, on_screen=os), ws, "old.csv")
A.show_page!(ws, page); frame()
A.close_page!(ws, page); frame()
close(ws.screen)
