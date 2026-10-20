# Tests for AktaPrime. Run with:  julia --project=. -e 'using Pkg; Pkg.test()'
# (in CI under xvfb-run, as GLMakie needs a display to load).
#
# `import`, not `using`: `using AktaPrime` would bring the @main entry point into
# Main, and Julia would start the program when this script ends.
import AktaPrime
using Test
const A = AktaPrime

# A method dump as an ÄKTAprime (V2.01) sends it before a run: manual method,
# 0.5 ml/min, 0 %B, buffer valve port 8, injection valve Load.
const METHOD_DUMP = "{l{5}{2 Method Dump}{2}{2 AKTAprime|3Ver|2, V2.01|?}{2}{2 Dump Format Ver|2, V1.00|?}" *
    "{2}{l{5}}}{B}{2 Method Settings}{B}Method Type|8,Manaul Method}Method|=,1}Method base|8,ml}" *
    "Frac base|:,ml}Max pressure (kPa) ,1000}Alarm (min/ml)|5,0.0}}{E}{2 Method Breakpoints}{E}|E}" *
    "Brkp Volume|3Conc Flow|2Frac|3Buff Inj|4Peak|3Autozzero Eventmark}|Z(mAu/min)}}" *
    ",1|3,0.0|5,0|3,0.5|2,0.0|3,8|3,Load|2,0|5,N|7,N},2|3,99999.9 ,0|3,0.5|2,0.0|3,8|3,Load|2,0|5,N|7,N}"

pt(t; vol=t / 2, uv=0.1, pctb=0.0) = A.TrendPoint(t * 60_000, vol, uv, 10.0, 7.0, pctb, 0.3, 20.0)
event(t, kind, text) = A.AktaEvent(t * 60_000, t / 2, kind, text)

@testset "AktaPrime" begin

    @testset "link layer frames" begin
        for (opc, data) in ((A.OPC_IDENTITY_REQUEST, UInt8[0x01]),               # binary, odd length
                            (A.OPC_TREND_DATA, UInt8.(0:13)),                     # binary, even length
                            (A.OPC_LOG_SINGLE, Vector{UInt8}("Flow 0.5 ml/min")))  # ASCII
            @test A.decode_opc_payload(A.encode_opc_payload(opc, data)) == [(opc, data)]
        end
        # a frame from the Akta passes validation; a corrupted one does not
        frame = UInt8[A.FRAME_START, A.AKTA_ADDR, A.CTRL_CONN, 0x00, A.FRAME_END]
        frame[4] = A.compute_checksum(frame, 2, 2)
        @test A.validate_rx_frame(frame, length(frame))
        frame[3] ⊻= 0x01
        @test !A.validate_rx_frame(frame, length(frame))
    end

    @testset "volume unit" begin
        A.VOLUME_UNIT_UL[] = 1.0          # ÄKTAprime: 1 µL per count
        @test A._vol_mL(1000) ≈ 1.0
        A.VOLUME_UNIT_UL[] = 10.0         # ÄKTAprime plus: 10 µL per count
        @test A._vol_mL(1000) ≈ 10.0
    end

    @testset "run time and volume advance with trend data" begin
        A.VOLUME_UNIT_UL[] = 1.0
        app = A.AppState(); app.csv_io = devnull
        data = zeros(UInt8, 14); data[1] = 10; data[2] = 1      # Δt = 100 ms, Δv = 1 µL
        A._handle_trend_data(copy(data), app)                    # not running: no change
        @test app.inst[].run_time_ms == 0
        app.inst[].run_state = "Run"
        foreach(_ -> A._handle_trend_data(copy(data), app), 1:600)
        @test app.inst[].run_time_ms ≈ 60_000
        @test app.inst[].run_vol_mL ≈ 0.6
    end

    @testset "method dump" begin
        m = A.parse_method_dump(Vector{UInt8}(METHOD_DUMP))
        @test Dict(m.settings)["Max pressure (kPa)"] == "1000"
        @test m.columns == ["Brkp", "Volume", "Conc", "Flow", "Frac", "Buff", "Inj", "Peak", "Autozero", "Eventmark"]
        @test length(m.breakpoints) == 2                          # incl. the end row "99999.9 ,0"
        @test m.breakpoints[1]["Buff"] == "8"
        @test m.breakpoints[1]["Flow"] == "0.5"
        @test m.breakpoints[2]["Volume"] == "99999.9"
        app = A.AppState()
        A.apply_method_dump!(app, m)
        @test app.inst[].buffer_port == 8 && app.inst[].buffer_port_known
        @test app.inst[].inject_value == A.IV_LOAD
        @test occursin("buffer port 8", A.PENDING_METHOD_EVENT[])
        A.PENDING_METHOD_EVENT[] = nothing
    end

    @testset "method text codec" begin
        for s in ("Flow  0.5 #1 z{|}~ end", " "^61 * "x", "*"^65, "a b * c", "")
            @test A.unescape_method_text(A.escape_method_text(Vector{UInt8}(s))) == Vector{UInt8}(s)
        end
        @test String(A.escape_method_text(Vector{UInt8}("Max  ,#3 z"))) == "Max|2,zy3 zz"
        dump = A.unescape_method_text(Vector{UInt8}(METHOD_DUMP))
        @test startswith(String(copy(dump)), "*"^65 * "\r\n** Method Dump\r\n")
        @test A.parse_method_text(dump).breakpoints == A.parse_method_dump(Vector{UInt8}(METHOD_DUMP)).breakpoints
    end

    @testset "method store" begin
        dir = mktempdir()
        x = A.MethodTransfer()
        handle(opc, data=UInt8[]) = A.handle_method_opc!(x, opc, Vector{UInt8}(data), dir)
        @test isnothing(handle(A.OPC_TREND_DATA))

        # The Akta saves a method as number 3, its text split over several messages.
        raw = Vector{UInt8}(METHOD_DUMP)
        @test isempty(handle(A.OPC_METHOD_SAVE_BEGIN, [0x03, 0x00]).replies)
        for part in Iterators.partition(raw, 30)
            handle(A.OPC_METHOD_LINE, collect(part))
        end
        r = handle(A.OPC_METHOD_SAVE_END)
        @test r.replies == [(A.OPC_METHOD_SAVE_ACK, UInt8[0x01])]
        file = A.method_path(dir, 3)
        @test read(file) == A.unescape_method_text(raw)
        Sys.iswindows() || @test filemode(file) & 0o777 == 0o644      # readable by other users
        @test !occursin("only one breakpoint", r.note)
        # A single-breakpoint method is saved, with a warning: the Akta cannot load it back.
        one_bp = replace(METHOD_DUMP, r"},2\|3,99999.9.*$" => "}")
        handle(A.OPC_METHOD_SAVE_BEGIN, [0x04, 0x00]); handle(A.OPC_METHOD_LINE, Vector{UInt8}(one_bp))
        r4 = handle(A.OPC_METHOD_SAVE_END)
        @test r4.replies == [(A.OPC_METHOD_SAVE_ACK, UInt8[0x01])] && occursin("only one breakpoint", r4.note)
        rm(A.method_path(dir, 4))
        @test handle(A.OPC_METHOD_SAVE_END).replies == [(A.OPC_METHOD_SAVE_ACK, UInt8[0x00])]   # none open

        # A dump in between is returned for decoding, not saved.
        handle(A.OPC_METHOD_DUMP_BEGIN)
        handle(A.OPC_METHOD_LINE, raw)
        @test handle(A.OPC_METHOD_DUMP_END, [0x00]).dump == raw

        # Listing: ten numbers from the start, up or down, 0xFFFF for empty slots.
        long = "Method Type        ," * "Long name with a z and #, "^3
        write(A.method_path(dir, 5), "*****\r\n" * long * "\r\n\r\n,1   ,0.0\r\n")
        write(A.method_path(dir, 12), "x\n")
        write(joinpath(dir, "PrimeMeth_tmp.txt"), "x")
        @test A.stored_methods(dir) == [3, 5, 12]
        nums(r) = [A._u16(r.replies[1][2], i) for i in 1:2:20]
        r = handle(A.OPC_METHOD_LIST, [0x01, 0x00, 0x01])
        @test r.replies[1][1] == A.OPC_METHOD_LIST_REPLY && length(r.replies[1][2]) == 20
        @test nums(r) == [3, 5, 12, fill(0xffff, 7)...]
        @test nums(handle(A.OPC_METHOD_LIST, [0x05, 0x00, 0x00])) == [5, 3, fill(0xffff, 8)...]
        @test nums(handle(A.OPC_METHOD_LIST, [0x00, 0x00, 0x01])) == fill(0xffff, 10)

        # Names from the editor stay on the PC (names.txt) and do not disturb the store.
        A.set_method_name!(dir, 5, "HisTag elution, 5 ml")
        A.set_method_name!(dir, 12, "  Wash  ")
        @test A.method_names(dir) == Dict(5 => "HisTag elution, 5 ml", 12 => "Wash")
        A.set_method_name!(dir, 12, "")
        @test A.method_names(dir) == Dict(5 => "HisTag elution, 5 ml")
        @test A.stored_methods(dir) == [3, 5, 12]
        @test A.method_name_ok("Säule – Elution") && !A.method_name_ok("a\tb") && !A.method_name_ok("x"^61)

        # Loading: 0x2013, the lines (long ones in 34-character parts), 0x2014 [0].
        r = handle(A.OPC_METHOD_LOAD, [0x05, 0x00])
        @test r.replies[1] == (A.OPC_METHOD_LOAD_BEGIN, UInt8[])
        @test r.replies[end] == (A.OPC_METHOD_LOAD_END, UInt8[0x00])
        body = r.replies[2:end-1]
        @test all(length(d) <= A.METHOD_CHUNK for (_, d) in body)
        @test [o for (o, _) in body] == [A.OPC_METHOD_LINE; A.OPC_METHOD_LINE_BEGIN;
            fill(A.OPC_METHOD_LINE_CONT, length(body) - 4); A.OPC_METHOD_LINE_END; A.OPC_METHOD_LINE]
        lines = String[]
        for (o, d) in body
            o in (A.OPC_METHOD_LINE, A.OPC_METHOD_LINE_BEGIN) && push!(lines, "")
            lines[end] *= String(copy(d))
        end
        @test [String(A.unescape_method_text(Vector{UInt8}(l))) for l in lines] == ["*****", long, ",1   ,0.0"]
        for (o, d) in r.replies          # every message survives the link-layer encoding
            @test A.decode_opc_payload(A.encode_opc_payload(o, d)) == [(o, d)]
        end
        @test handle(A.OPC_METHOD_LOAD, [0x07, 0x00]).replies == [(A.OPC_METHOD_LOAD_END, UInt8[0x01])]
        write(A.method_path(dir, 13), "ok\r\n" * "x"^100 * "\r\n")
        @test last(handle(A.OPC_METHOD_LOAD, [0x0d, 0x00]).replies) == (A.OPC_METHOD_LOAD_END, UInt8[0x02])

        # Exists and delete; deleted and overwritten files are kept in old/.
        @test handle(A.OPC_METHOD_EXISTS, [0x0c, 0x00]).replies == [(A.OPC_METHOD_EXISTS_REPLY, UInt8[0x01])]
        @test handle(A.OPC_METHOD_DELETE, [0x0c, 0x00]).replies == [(A.OPC_METHOD_DELETE_REPLY, UInt8[0x01])]
        @test handle(A.OPC_METHOD_EXISTS, [0x0c, 0x00]).replies == [(A.OPC_METHOD_EXISTS_REPLY, UInt8[0x00])]
        @test handle(A.OPC_METHOD_DELETE, [0x0c, 0x00]).replies == [(A.OPC_METHOD_DELETE_REPLY, UInt8[0x00])]
        handle(A.OPC_METHOD_SAVE_BEGIN, [0x03, 0x00]); handle(A.OPC_METHOD_LINE, b"new}"); handle(A.OPC_METHOD_SAVE_END)
        @test read(file, String) == "new\r\n"
        @test length(readdir(joinpath(dir, "old"))) == 2

        # End to end: a list request in a frame from the Akta is answered from the methods folder.
        A.METHOD_DIR[] = dir
        frame = A.build_i_frame(A.encode_opc_payload(A.OPC_METHOD_LIST, UInt8[0x01, 0x00, 0x01]), 0x01, 0x00)
        frame[2] = A.AKTA_ADDR
        frame[end-1] = A.compute_checksum(frame, 2, length(frame) - 3)
        @test A.validate_rx_frame(frame, length(frame))
        app = A.AppState(); app.csv_io = devnull
        tx = Channel{Tuple{UInt16,Vector{UInt8}}}(Inf)
        A.parse_rx_data_frame(frame, length(frame), tx, A.LinkState(), app, f -> f())
        opc, data = take!(tx)
        @test opc == A.OPC_METHOD_LIST_REPLY && A._u16(data) == 3
        A.METHOD_DIR[] = ""
    end

    @testset "method files" begin
        # A file as the Akta writes it reads and writes back unchanged.
        bytes = A.unescape_method_text(Vector{UInt8}(METHOD_DUMP))
        m = A.read_method_file(bytes)
        @test A.format_method_text(m) == bytes
        @test A.setting(m, "Max pressure (kPa)") == "1000" && length(m.rows) == 2
        @test m.rows[1] == ["0.0", "0", "0.5", "0.0", "8", "Load", "0", "N", "N"]
        @test isempty(first(A.method_problems(m)))
        @test A.read_method_file(A.format_method_text(A.new_method_file())) == A.new_method_file()
        @test_throws ErrorException A.read_method_file(b"no method here")

        # Values: what may be entered, and how it is written.
        @test A.method_value_ok("Flow", "0,5") && A.normalize_value("Flow", "0,5") == "0.5"
        @test A.normalize_value("Volume", "10") == "10.0" && A.normalize_value("Conc", "05") == "5"
        @test A.normalize_value("Peak", "0.10") == "0.1" && A.normalize_value("Peak", "0") == "0"
        @test !A.method_value_ok("Flow", "51") && !A.method_value_ok("Conc", "100.5")
        @test !A.method_value_ok("Buff", "9") && !A.method_value_ok("Inj", "load")
        @test !A.method_value_ok("Method Type", "a,b") && A.method_value_ok("Method Type", "-")

        # Problems that stop the Akta loading a method.
        one = A.copy(m); pop!(one.rows)
        @test occursin("two breakpoints", only(first(A.method_problems(one))))
        bad = A.copy(m); bad.rows[1][1] = "1.0"; bad.rows[2][1] = "0.5"; bad.rows[2][3] = "x"
        msgs, cells = A.method_problems(bad)
        @test (1, "Volume") in cells && (2, "Volume") in cells && (2, "Flow") in cells && length(msgs) == 3
        # Saving normalises: 1 → 1.0 in the file.
        m2 = A.copy(m); m2.rows[1][3] = "1"
        @test occursin(",1.0  ,", String(A.format_method_text(A.normalize_method(m2))))
    end

    @testset "valve log messages" begin
        s = A.InstrumentState()
        @test !s.buffer_port_known && s.buffer_port == 1          # assumed until reported
        @test A._set_buffer_valve_from_log!("Buffer Valve Pos 8", s) && s.buffer_port == 8
        @test A._set_buffer_valve_from_log!("Manual Set; Buffer Valve Pos 3", s) && s.buffer_port == 3
        @test !A._set_buffer_valve_from_log!("Buffer Valve Pos 9", s) && s.buffer_port == 3
        @test A._set_inject_from_log!("Injection Valve Inj", s) && s.inject_value == A.IV_INJECT
        @test A._flow_from_log("Flow 0.5 ml/min") == 0.5
        @test isnothing(A._flow_from_log("Concentration 10 %B"))
    end

    @testset "state at a past moment" begin
        events = [event(0.1, A.EVT_LOG, "Method start: flow 0.5 ml/min, 0 %B, buffer port 1, inject Load, fraction 0.0 ml, 2 breakpoints"),
            event(0.2, A.EVT_RUN_STATE, "Run state: Run  inject=IV_LOAD"),
            event(1.0, A.EVT_LOG, "Buffer Valve Pos 8"),
            event(3.0, A.EVT_LOG, "Fraction size 1.0 ml"),
            event(4.0, A.EVT_LOG, "Injection Valve Inj")]
        s = A._state_at(events, pt(2.0))
        @test s.run_state == "Run" && s.buffer_port == 8 && s.inject_value == A.IV_LOAD && s.fraction_vol_mL == 0
        s = A._state_at(events, pt(5.0))
        @test s.inject_value == A.IV_INJECT && s.fraction_vol_mL == 1.0
        @test A._state_at(events, pt(0.05)).inject_value == A.IV_UNKNOWN
        @test A._flow_at([event(0.5, A.EVT_LOG, "Flow 0.5 ml/min")], pt(1.0)) == 0.5
    end

    @testset "run information" begin
        app = A.AppState()
        A.log_run_info!(app, Dict("Sample" => "Lysozyme", "Column volume (mL)" => "2,5", "Port 3" => "Tris"))
        info = A.run_info(app.events[])
        @test info["Sample"] == "Lysozyme" && info["Port 3"] == "Tris"
        @test A.column_volume(info) == 2.5                      # decimal comma accepted
        n = length(app.events[])
        A.log_run_info!(app, Dict("Sample" => "Lysozyme", "User" => "C"); only_changed=true)
        @test length(app.events[]) == n + 1                     # only the new field is recorded
    end

    @testset "CSV log round trip" begin
        dir = mktempdir()
        app = A.AppState(); app.log_dir = dir; app.log_prefix = "test"
        app.log_filename = A.newlogname(app)
        @test dirname(app.log_filename) == dir
        app.csv_io = A.init_csv(app.log_filename)
        points = [pt(t; uv=sin(t)) for t in 0:0.1:2]
        foreach(p -> A.write_csv_trend(app, p), points)
        A.push_event!(app, A.EVT_MARK, "sample loaded")
        A.push_event!(app, A.EVT_INFO, "Sample: Lysozyme")
        close(app.csv_io)
        back = A.AppState(); A.load_csv_log!(back, app.log_filename)
        @test length(back.trend_data[]) == length(points)
        @test back.trend_data[][end].uv ≈ points[end].uv atol = 1e-6
        @test [e.kind for e in back.events[]] == [A.EVT_MARK, A.EVT_INFO]
    end

    @testset "display downsampling" begin
        trend = [pt(i / 480; uv=i == 5000 ? 9.0 : 0.0) for i in 1:30_000]
        all_pts = A._display_points(trend, p -> p.uv, 0.0, (-Inf, Inf))
        @test length(all_pts) <= 2 * A.DISPLAY_BINS
        @test maximum(p[2] for p in all_pts) == 9.0              # a one-point peak survives
        zoom = A._display_points(trend, p -> p.uv, 0.0, (10.0, 11.0))
        @test length(zoom) == 482                                # all 480 points in the window + 2 edges
        @test A._normalise([A.Point2f(0, 2), A.Point2f(1, 4)], :uv)[1][2][2] ≈ 100
    end

    @testset "settings defaults" begin
        s = A.Settings(false, "/dev/ttyUSB0", 1.0, "akta", "", false, 2.0, Dict{String,String}())
        @test s.start_panels == A.ALL_PANELS && !s.save_raw
    end

    @testset "GUI pages build" begin
        app = A.AppState(); app.csv_io = devnull
        foreach(t -> push!(app.trend_data[], pt(t; pctb=10t)), 0:0.01:3)
        push!(app.events[], event(1.0, A.EVT_LOG, "Buffer Valve Pos 3"))
        settings = A.Settings(true, "/dev/null", 1.0, "test", mktempdir(), false, 2.0, Dict{String,String}())
        acq = A.Acquisition(app, settings)
        ws = A.Workspace(acq)
        live = A.add_page!((tb, os) -> A.build_gui(app; topbar=tb, on_screen=os, status=acq.status), ws, "Live";
            closable=false)
        A.show_page!(ws, live)
        @test live.fig isa A.Figure
        @test A.build_gui(app; viewer=true, start_panels=["%B"]) isa A.Figure
        A.show_page!(ws, A.prepare_settings!(ws))
        A.open_runinfo!(ws)
        A.METHOD_DIR[] = mktempdir()
        @test A.open_methods!(ws).fig isa A.Figure                       # no methods yet
        @test [p.title for p in ws.pages] == ["Live", "Settings", "Run info", "Methods"]
        A.close_page!(ws, ws.pages[end])
        long = A.new_method_file()
        foreach(i -> insert!(long.rows, 2, [string(i, ".0"); long.rows[1][2:end]]), 15:-1:1)
        write(A.method_path(A.METHOD_DIR[], 7), A.format_method_text(long))   # more rows than shown at once
        @test A.open_methods!(ws).fig isa A.Figure
        editor = A.Workspace(acq; editor_only=true)
        @test A.open_methods!(editor).fig isa A.Figure
        A.METHOD_DIR[] = ""
    end
end
