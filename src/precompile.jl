# precompile.jl — builds the GUI pages once while the package is precompiled, so
# the code behind them is compiled ahead of time instead of on first use (slow
# first start, slow first click on Settings or Open run…). No window is opened.

using PrecompileTools: @setup_workload, @compile_workload

@setup_workload begin
    @compile_workload begin
        with_theme(makie_theme(LIGHT)) do
            app = AppState()
            for t in 0:0.02:4
                push!(app.trend_data[], TrendPoint(t * 60_000, t, exp(-(t - 2)^2), 10.0, 7.0,
                    10t, 0.3, 20.0))
            end
            ev(t, kind, txt) = push!(app.events[], AktaEvent(t * 60_000, t, kind, txt))
            ev(0.1, EVT_LOG, "Method start: flow 0.5 ml/min, 0 %B, buffer port 1, inject Load, fraction 0.0 ml, 2 breakpoints")
            ev(0.2, EVT_RUN_STATE, "Run state: Run  inject=IV_LOAD")
            ev(0.5, EVT_LOG, "Flow 0.5 ml/min")
            ev(1.0, EVT_LOG, "Buffer Valve Pos 8")
            ev(2.0, EVT_LOG, "Injection Valve Inj")

            acq = Acquisition(app, Settings(true, "", 1.0, "akta", "", false, 2.0,
                Dict("Sample" => "Lysozyme", "Column volume (mL)" => "1.0", "Port 3" => "20 mM Tris")))
            ws = Workspace(acq)
            live = add_page!((topbar, on_screen) -> build_gui(app; topbar, on_screen, status=acq.status),
                ws, "Live"; closable=false)
            add_page!((topbar, on_screen) -> build_gui(app; viewer=true, topbar, on_screen), ws, "run.csv")
            show_page!(ws, live)
            show_page!(ws, prepare_settings!(ws))
            open_runinfo!(ws)
        end
    end
end
