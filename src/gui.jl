# gui.jl — GLMakie real-time chromatography display

# ── Colour palette ────────────────────────────────────────────────────────────
# Light-palette colours: exported PDFs always use these (see theme.jl).
const COL_UV = LIGHT.uv
const COL_COND = LIGHT.cond
const COL_PCTB = LIGHT.pctb
const COL_PRES = LIGHT.pres
const COL_PH = LIGHT.ph
const COL_FLOW = LIGHT.flow


const FRAC_COLORS = [RGBf(0.8, 0.9, 1.0), RGBf(1.0, 1.0, 0.8)]  # light blue, light yellow
const FRAC_ALPHA = 0.22

const EVT_COLORS = Dict(
    EVT_INJECT => (:hotpink, :solid),
    EVT_RUN_STATE => (:green, :dash),
    EVT_STEP => (:teal, :dashdot),
    EVT_TUBEFEED => (:grey50, :solid),
    EVT_LOG => (:blue, :solid),
    EVT_CONNECT => (:green, :solid),
    EVT_DISCONNECT => (:red, :solid),
    EVT_MARK => (:darkorange, :solid),
)

_inject_label(v::InjectValue) =
    v == IV_LOAD ? "LOAD" :
    v == IV_INJECT ? "INJECT" :
    v == IV_WASTE ? "WASTE" : "UNKNOWN"

function _event_label_top(e::AktaEvent)::String
    if e.kind == EVT_INJECT
        if (m = match(r"Valve\s*→\s*([A-Za-z_]+)", e.text)) !== nothing
            return "INJ $(uppercase(m.captures[1]))"
        end
        return "INJECT"
    elseif e.kind == EVT_RUN_STATE
        if (m = match(r"Run state:\s*([^\s]+)", e.text)) !== nothing
            return uppercase(m.captures[1])
        end
        return "STATE"
    elseif e.kind == EVT_STEP
        return "STEP"
    elseif e.kind == EVT_LOG
        # Special handling for fraction size zero-transitions
        if contains(e.text, "Fraction size")
            if (m = match(r"Fraction size (\d+(?:\.\d+)?)", e.text)) !== nothing
                val = parse(Float64, m.captures[1])
                return val > 0.0 ? "FRAC START" : "FRAC STOP"
            end
        end
        t = strip(e.text)
        for (re, short) in ((r"^(?:Manual Set;\s*)?Buffer Valve Pos\s+(\d+)"i, "Buffer "),
            (r"^Injection Valve (\w+)"i, "Inj valve "), (r"^Flow ([0-9.]+) ml/min"i, "Flow "),
            (r"^(?:Manual Set;\s*)?Concentration ([0-9.]+) %B"i, "%B "),
            (r"^Feed Tube Nr\s+(\d+)"i, "Tube "))
            m = match(re, t)
            isnothing(m) || return short * m.captures[1]
        end
        startswith(t, "Method start") && return "Method start"
        return length(t) > 20 ? first(t, 18) * "…" : t
    elseif e.kind == EVT_MARK
        return "Mark: " * (length(e.text) > 16 ? first(e.text, 15) * "…" : e.text)
    elseif e.kind == EVT_CONNECT
        return "CONNECT"
    elseif e.kind == EVT_DISCONNECT
        return "DISCONNECT"
    end
    return string(e.kind)
end

# The x axis is set by a scale `xs`: 0 = time in min, otherwise volume divided by
# `xs` — 1 for mL, the column volume for column volumes (CV).
_x(time_ms::Real, vol_mL::Real, xs::Real)::Float32 =
    xs == 0 ? Float32(time_ms / 60_000) : Float32(vol_mL / xs)
_xlabel(xs::Real) = xs == 0 ? "Time (min)" : xs == 1 ? "Volume (mL)" : "Column volumes (CV)"

_trend_x(p::TrendPoint, xs::Real)::Float32 = _x(p.cum_time_ms, p.cum_vol_mL, xs)

_event_x(e::AktaEvent, xs::Real)::Float32 = _x(e.cum_time_ms, e.cum_vol_mL, xs)

# Set flow, as reported by the instrument's "Flow 1.0 ml/min" log messages.
_flow_from_log(text::AbstractString)::Union{Nothing,Float64} =
    let m = match(r"^Flow\s+([0-9]+(?:\.[0-9]+)?)\s*ml/min$"i, strip(text))
        m === nothing ? nothing : parse(Float64, m.captures[1])
    end

# Step-plot points of the set flow: one per flow log event, with the last value
# held up to the newest data point.
function _flow_setpoints(events::AbstractVector{AktaEvent}, trend::AbstractVector{TrendPoint},
    xs::Real)::Vector{Point2f}
    pts = Point2f[]
    for e in events
        e.kind == EVT_LOG || continue
        flow = _flow_from_log(e.text)
        isnothing(flow) || push!(pts, Point2f(_event_x(e, xs), flow))
    end
    if !isempty(pts) && !isempty(trend)
        xend = _trend_x(trend[end], xs)
        xend > pts[end][1] && push!(pts, Point2f(xend, pts[end][2]))
    end
    return pts
end

# Overlay mode: scale a trace to 0–100 % of its own range. %B already is a
# percentage; flow is scaled from 0 so it reads as a fraction of the top flow.
# Returns the scaled points and the (lo, hi) range that maps to 0–100 %.
# `range` = (lo, hi) of the whole trace when `pts` is only a downsampled part of it.
function _normalise(pts::AbstractVector{<:Point2}, key::Symbol; range=nothing)
    key === :pctb && return Vector{Point2f}(pts), (0.0f0, 100.0f0)
    ys = [p[2] for p in pts]
    lo, hi = isnothing(range) ? (Float32(minimum(ys)), Float32(maximum(ys))) : Float32.(range)
    key === :flow && (lo = 0.0f0)
    span = hi - lo
    scaled = span > 0 ? [Point2f(p[1], (p[2] - lo) / span * 100) for p in pts] :
             [Point2f(p[1], 50) for p in pts]
    return scaled, (lo, hi)
end

# Overlay y-range: headroom above 100 % so traces are not squashed against the top.
const OVERLAY_YLIMS = (-3, 110)

_channel_ylabel(name, unit) = isempty(unit) ? name : "$name ($unit)"

# Overlay y-axis: in % of range by default, or in the real units of the highlighted
# trace. `getrange()` returns that trace's current (lo, hi), which map to 0–100 %;
# ticks are chosen on the real values and placed at their scaled positions.
function _set_overlay_yaxis!(ax, highlight; p=ui())
    if isnothing(highlight)
        ax.yticks = Makie.automatic
        ax.ytickformat = Makie.automatic
        ax.ylabel = "Scaled (% of range)"
        ax.ylabelcolor = p.muted
        ax.yticklabelcolor = p.muted
        return
    end
    name, unit, col, getrange = highlight
    function toreal(v)
        lo, hi = getrange()
        return lo + v / 100 * (hi - lo)
    end
    ax.yticks = (vmin, vmax) -> begin
        lo, hi = getrange()
        span = hi - lo
        span > 0 || return [50.0]
        t = Makie.get_tickvalues(LinearTicks(6), toreal(vmin), toreal(vmax))
        return (t .- lo) ./ span .* 100
    end
    ax.ytickformat = vals -> Makie.get_ticklabels(Makie.automatic, toreal.(vals))
    ax.ylabel = _channel_ylabel(name, unit)
    ax.ylabelcolor = col
    ax.yticklabelcolor = col
    return
end

_overlay_label(name, unit, (lo, hi)) =
    "━━  $name   ($(@sprintf("%.3g", lo))–$(@sprintf("%.3g", hi))$(isempty(unit) ? "" : " $unit"))"

# Event labels start just right of their event line, in rows from the top of the
# visible area: a label moves down a row only if it would overlap one already
# placed. Laid out in screen pixels, so it is redone whenever the view changes.
const EVENT_LABEL_FONTSIZE = 8

function _event_label_positions(xs::AbstractVector{<:Real}, labels::AbstractVector{<:AbstractString},
    lims::Rect2, px::AbstractVector{<:Real}, avoid=nothing)::Vector{Point2f}
    x0, y0 = lims.origin
    w, h = lims.widths
    pxw, pxh = max(px[1], 1), max(px[2], 1)
    gap = 3                                            # px between line and label
    rowh = EVENT_LABEL_FONTSIZE * 1.3                  # px per row
    row_end = Float64[]                                # right edge (px) of each row
    pts = Vector{Point2f}(undef, length(xs))
    # `avoid` = (left, right, top, bottom) px box, top/bottom measured from the top edge
    blocked(r, start, stop) = !isnothing(avoid) && start < avoid[2] && stop > avoid[1] &&
                              2 + r * rowh > avoid[3] && 2 + (r - 1) * rowh < avoid[4]
    for i in sortperm(xs)
        start = (xs[i] - x0) / w * pxw + gap
        stop = start + length(labels[i]) * EVENT_LABEL_FONTSIZE * 0.72 + gap
        r = 1
        while (r <= length(row_end) && row_end[r] >= start) || blocked(r, start, stop)
            r += 1
        end
        while length(row_end) < r
            push!(row_end, -Inf)
        end
        row_end[r] = stop
        pts[i] = Point2f(xs[i] + gap / pxw * w, y0 + h - (2 + (r - 1) * rowh) / pxh * h)
    end
    return pts
end

function _event_labels!(ax, evts, xscale; avoid=Observable(nothing))
    lbls = @lift [_event_label_top(e) for e in $evts]
    pts = @lift _event_label_positions([_event_x(e, $xscale) for e in $evts], $lbls,
        $(ax.finallimits), $(ax.scene.viewport).widths, $avoid)
    text!(ax, pts; text=lbls, fontsize=EVENT_LABEL_FONTSIZE, color=ui().muted,
        align=(:left, :top), xautolimits=false, yautolimits=false)
end

# ─────────────────────────────────────────────────────────────────────────────
# Inspecting a past moment
# ─────────────────────────────────────────────────────────────────────────────
const _INJECT_NAMES = Dict(string(v) => v for v in instances(InjectValue))

# Instrument state at a past moment, rebuilt by replaying the logged events up to
# `p` with the same decoders the live link uses. Every event is in the CSV, so
# this works for reopened logs too.
function _state_at(events::AbstractVector{AktaEvent}, p::TrendPoint)::InstrumentState
    s = InstrumentState()
    for e in events
        e.cum_time_ms <= p.cum_time_ms || continue
        if e.kind == EVT_RUN_STATE
            m = match(r"Run state:\s*(\S+)\s+inject=(\w+)", e.text)
            if !isnothing(m)
                s.run_state = m.captures[1]
                s.inject_value = get(_INJECT_NAMES, m.captures[2], s.inject_value)
            end
        elseif e.kind == EVT_LOG
            if (m = match(r"^Method start:.*buffer port (\d+), inject (\w+)", e.text)) !== nothing
                s.buffer_port = parse(Int, m.captures[1])
                s.buffer_port_known = true
                inj = lowercase(m.captures[2])
                s.inject_value = inj == "load" ? IV_LOAD : inj == "inj" ? IV_INJECT :
                                 inj == "waste" ? IV_WASTE : s.inject_value
            elseif (m = match(r"^Fraction size\s+([0-9.]+)\s+ml$"i, strip(e.text))) !== nothing
                s.fraction_vol_mL = parse(Float64, m.captures[1])
            elseif (m = match(r"^Feed Tube Nr\s+(\d+)$"i, strip(e.text))) !== nothing
                s.fraction_number = max(1, parse(Int, m.captures[1]))
            else
                _set_inject_from_log!(e.text, s) || _set_buffer_valve_from_log!(e.text, s)
            end
        end
    end
    s.cum_time_ms = s.run_time_ms = p.cum_time_ms
    s.cum_vol_mL = s.run_vol_mL = p.cum_vol_mL
    return s
end

# Set flow (mL/min) in force at `p`, or nothing before the first flow message.
function _flow_at(events::AbstractVector{AktaEvent}, p::TrendPoint)
    flow = nothing
    for e in events
        e.kind == EVT_LOG && e.cum_time_ms <= p.cum_time_ms || continue
        f = _flow_from_log(e.text)
        isnothing(f) || (flow = f)
    end
    return flow
end

# One-line valve summary for the flow-path card; ports named in Run info show their buffer.
function _valve_summary(s::InstrumentState, info::AbstractDict=Dict{String,String}())::String
    name = get(info, "Port $(s.buffer_port)", "")
    port = !isempty(name) ? "$(s.buffer_port) ($name)" :
           s.buffer_port == 1 ? "1 (A)" : s.buffer_port == 8 ? "8 (sample)" : string(s.buffer_port)
    outlet = s.fraction_vol_mL > 0 ?
             "frac #$(s.fraction_number), $(@sprintf("%.2f", s.fraction_vol_mL)) mL" : "waste"
    return "Valve $(lowercase(_inject_label(s.inject_value))) · Buffer $port · Outlet $outlet"
end

function _fraction_label_bottom(e::AktaEvent)::String
    # Show just the fraction number (no "F#" prefix)
    if (m = match(r"Feed Tube Nr\s+(\d+)", e.text)) !== nothing
        return m.captures[1]  # Plain number only
    end
    return "?"
end

# ─────────────────────────────────────────────────────────────────────────────
# Display refresh
# ─────────────────────────────────────────────────────────────────────────────
# The GUI refreshes at a fixed rate (Settings → Display refresh) rather than on
# every data point: recomputing all views costs tens of ms per point on long
# runs, which at ~8 points/s would keep the GUI thread busy. Recording is not
# affected; only what is drawn is batched.
const GUI_REFRESH_S = Ref(0.5)

# Applies a group of GUI changes with a single layout solve at the end. Without
# this, every changed label or axis property re-solves the whole window layout,
# which was the main cost of refreshes, toggles and tab switches. Nestable.
function batch_layout(f, layout::GridLayout)
    layout.block_updates && return f()
    layout.block_updates = true
    try
        return f()
    finally
        layout.block_updates = false
        Makie.GridLayoutBase.update!(layout)
    end
end

# Pages are built with layout updates blocked (one solve per element otherwise);
# this lifts the block and solves the layout once.
function finish_layout!(fig::Figure)
    fig.layout.block_updates = false
    Makie.GridLayoutBase.update!(fig.layout)
end

# True while the package is being precompiled: background loops must not start then.
_precompiling() = ccall(:jl_generating_output, Cint, ()) == 1

# Copies of `srcs` that pass changes on at most every GUI_REFRESH_S, and only
# while `active` (the page is on screen); a page catches up when it is shown.
function _throttled(srcs::Observable...; active::Observable{Bool}=Observable(true), batch=f -> f())
    proxies = map(o -> Observable(o[]), srcs)
    dirty = fill(false, length(srcs))
    for (i, o) in enumerate(srcs)
        on(_ -> (dirty[i] = true), o)
    end
    # one refresh = one layout solve, however many views it updates
    flush!() = any(dirty) && batch() do
        for i in eachindex(srcs)
            dirty[i] || continue
            dirty[i] = false
            proxies[i][] = srcs[i][]
        end
    end
    on(a -> a && flush!(), active)
    _precompiling() || @async while true
        sleep(GUI_REFRESH_S[])
        try
            active[] && flush!()
        catch err
            @error "GUI refresh failed" exception = (err, catch_backtrace())
        end
    end
    return proxies
end

# ── Display downsampling ──────────────────────────────────────────────────────
# A trace is drawn with at most 2 × DISPLAY_BINS points: the data in the shown
# x-window is split into DISPLAY_BINS buckets that each keep their minimum and
# maximum, so peaks look the same as with every point drawn while long runs stay
# light to draw. Recording and PDF export use the full data.
const DISPLAY_BINS = 1500

# Index of the first point at or beyond x (x grows along the run).
function _first_at_or_after(trend::AbstractVector{TrendPoint}, x::Real, xs::Real)::Int
    lo, hi = 1, length(trend) + 1
    while lo < hi
        mid = (lo + hi) ÷ 2
        _trend_x(trend[mid], xs) < x ? (lo = mid + 1) : (hi = mid)
    end
    return lo
end

function _display_points(trend::AbstractVector{TrendPoint}, gety, xs::Real,
    (xlo, xhi))::Vector{Point2f}
    pt(i) = Point2f(_trend_x(trend[i], xs), gety(trend[i]))
    n = length(trend)
    # The window, plus one point either side so lines run to the plot edges.
    i0 = isinf(xlo) ? 1 : max(1, _first_at_or_after(trend, xlo, xs) - 1)
    i1 = isinf(xhi) ? n : min(n, _first_at_or_after(trend, xhi, xs))
    i1 < i0 && return [pt(clamp(i0, 1, n))]
    m = i1 - i0 + 1
    m <= 2 * DISPLAY_BINS && return [pt(i) for i in i0:i1]
    pts = Point2f[]
    sizehint!(pts, 2 * DISPLAY_BINS)
    for b in 0:DISPLAY_BINS-1
        a = i0 + (m * b) ÷ DISPLAY_BINS
        z = i0 + (m * (b + 1)) ÷ DISPLAY_BINS - 1
        imin = imax = a
        ymin = ymax = gety(trend[a])
        for i in a+1:z
            y = gety(trend[i])
            y < ymin && (ymin = y; imin = i)
            y > ymax && (ymax = y; imax = i)
        end
        push!(pts, pt(min(imin, imax)))
        imin != imax && push!(pts, pt(max(imin, imax)))
    end
    return pts
end

# ─────────────────────────────────────────────────────────────────────────────
# build_gui — construct the Figure and wire all Observables
# ─────────────────────────────────────────────────────────────────────────────
function build_gui(app::AppState; viewer::Bool=false, topbar=nothing,
    status::Union{Nothing,Observable{String}}=nothing, on_screen::Observable{Bool}=Observable(true),
    start_panels::AbstractVector{<:AbstractString}=ALL_PANELS)::Figure
    fig = Figure(size=(1440, 900))      # colours and fonts from the theme (theme.jl)
    fig.layout.block_updates = true     # one layout solve once the page is built
    pal = ui()                          # palette; not `p`, which closures below use for points
    batch(f) = batch_layout(f, fig.layout)

    # Live data reaches the views through throttled copies (see _throttled); a
    # log opened for viewing does not change, so it is used directly.
    trend_obs, events_obs, inst_obs, fracs_obs = viewer ?
        (app.trend_data, app.events, app.inst, app.fractions) :
        _throttled(app.trend_data, app.events, app.inst, app.fractions; active=on_screen, batch)

    # Layout, one area per job:
    #   top bar      navigation and global actions (tabs, menu; see workspace.jl)
    #   toolbar      how the data is viewed            │ right panel: what the
    #   plots, slider                                   │ instrument is doing
    #   status bar   connection, recording, mouse help
    r = isnothing(topbar) ? 0 : 1          # rows below the (optional) top bar
    isnothing(topbar) || topbar(fig[1, 1])
    body = fig[r+1, 1] = GridLayout()
    toolbar = body[1, 1] = GridLayout(; halign=:left, tellwidth=false)
    left = body[2, 1] = GridLayout()
    right = body[1:2, 2] = GridLayout(; valign=:top)
    colsize!(body, 1, Relative(0.75))
    colsize!(body, 2, Relative(0.25))

    xscale = Observable(0.0)          # x axis: 0 time, 1 mL, column volume → CV (see _x)

    # ── Chromatogram axes (UV always shown; the rest are toggleable) ───────────
    ax_uv = Axis(left[1, 1]; ylabel="UV (AU)", ygridvisible=false, xgridvisible=false)
    ax_pctb = Axis(left[2, 1]; ylabel="%B", ygridvisible=false, xgridvisible=false,
        limits=(nothing, (-3, 103)))   # margin so the trace is visible at 0 %B and 100 %B
    ax_cond = Axis(left[3, 1]; ylabel="Conductivity (mS/cm)",
        ygridvisible=false, xgridvisible=false)
    ax_ph = Axis(left[4, 1]; ylabel="pH", ygridvisible=false, xgridvisible=false)
    ax_pres = Axis(left[5, 1]; ylabel="Pressure (MPa)",
        ygridvisible=false, xgridvisible=false)
    ax_rate = Axis(left[6, 1]; ylabel="Flow (mL/min)",
        ygridvisible=false, xgridvisible=false)
    # Overlay mode: all traces on one axis, each scaled to 0–100 % of its range.
    ax_ov = Axis(left[7, 1]; ylabel="Scaled (% of range)", ygridvisible=false,
        xgridvisible=false, limits=(nothing, OVERLAY_YLIMS))
    plot_axes = (ax_uv, ax_pctb, ax_cond, ax_ph, ax_pres, ax_rate, ax_ov)

    linkxaxes!(plot_axes...)
    # Same fixed room for the y tick labels in every panel, so plots stay aligned
    # and do not shift when the values (and so the tick label widths) change.
    for ax in plot_axes
        ax.yticklabelspace = 42.0
    end
    # Panel names sit inside each panel (top right) instead of rotated axis titles,
    # which overlap once panels get short (small window, run log open); and fewer
    # tick labels, so they do not crowd either.
    for (ax, name, col) in ((ax_uv, "UV (AU)", pal.uv), (ax_pctb, "%B", pal.pctb),
        (ax_cond, "Cond (mS/cm)", pal.cond), (ax_ph, "pH", pal.ph), (ax_pres, "Pressure (MPa)", pal.pres),
        (ax_rate, "Flow (mL/min)", pal.flow))
        text!(ax, Point2f(0.995, 0.96); text=name, space=:relative, align=(:right, :top),
            fontsize=FS_SMALL + 1, font=:bold, color=col, xautolimits=false, yautolimits=false)
        ax.yticks = WilkinsonTicks(3; k_min=2, k_max=4)
    end

    # x label tracks the plotting mode; per-panel visibility is set by
    # refresh_panels! below so only the lowest visible panel carries it.
    for ax in plot_axes
        ax.xlabel = "Time (min)"
        ax.xticklabelsvisible = false
        ax.xlabelvisible = false
    end

    # ── Data observables ──────────────────────────────────────────────────────
    # Guard: provide a dummy point when empty so GLMakie axis autoscaling
    # never reduces over an empty collection on first render.
    _trend = @lift let d = $(trend_obs)
        isempty(d) ? [TrendPoint(0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0)] : d
    end
    # Which views are on screen (set by refresh_panels!), and the x-window to
    # draw: everything while following live, else the zoomed range (set below).
    overlay = Observable(false)
    panel_shown = Dict(k => Observable(k !== :ov) for k in (:uv, :pctb, :cond, :ph, :pres, :ov))
    xwin = Observable((-Inf, Inf))
    # Downsampled trace for a panel; a hidden one gets a single point, not drawn.
    function trace(gety, key)
        @lift $(panel_shown[key]) ? _display_points($_trend, gety, $xscale, $xwin) :
              [Point2f(_trend_x($_trend[1], $xscale), gety($_trend[1]))]
    end
    uv_pts = trace(p -> p.uv, :uv)
    cond_pts = trace(p -> p.cond_mScm, :cond)
    ph_pts = trace(p -> p.ph, :ph)
    pctb_pts = trace(p -> p.pctb, :pctb)
    pres_pts = trace(p -> p.pres_MPa, :pres)
    # Same empty-guard as _trend: a dummy point until the first flow message arrives.
    rate_pts = @lift let pts = _flow_setpoints($(events_obs), $(trend_obs), $xscale)
        isempty(pts) ? [Point2f(0, 0)] : pts
    end

    lines!(ax_uv, uv_pts, color=pal.uv, linewidth=1.6)
    pl_pctb = lines!(ax_pctb, pctb_pts, color=pal.pctb, linewidth=1.6)
    pl_cond = lines!(ax_cond, cond_pts, color=pal.cond, linewidth=1.6)
    pl_ph = lines!(ax_ph, ph_pts, color=pal.ph, linewidth=1.6)
    pl_pres = lines!(ax_pres, pres_pts, color=pal.pres, linewidth=1.6)
    pl_rate = stairs!(ax_rate, rate_pts; step=:post, color=pal.flow, linewidth=1.6)

    # ── Event vlines on UV panel ──────────────────────────────────────────────
    # xautolimits/yautolimits=false prevents Makie calling extrema on empty vectors.
    # One plot for the solid and one for the dashed event lines (coloured per event),
    # instead of one per event kind: fewer plot objects. Run information is not drawn.
    evt_style(e) = get(EVT_COLORS, e.kind, (:black, :dash))
    for dashed in (false, true)
        evts = @lift filter(e -> e.kind != EVT_INFO && (evt_style(e)[2] != :solid) == dashed, $(events_obs))
        evt_x = @lift [_event_x(e, $xscale) for e in $evts]
        evt_col = @lift [RGBAf(Makie.to_color(evt_style(e)[1]), 0.55) for e in $evts]
        for ax in (ax_uv, ax_ov)
            vlines!(ax, evt_x; color=evt_col, linestyle=dashed ? :dash : :solid, linewidth=1.0,
                xautolimits=false, yautolimits=false)
        end
    end

    # ── Fraction collection spans on UV and %B panels ──────────────────────────
    # Build starts/ends/colors from one observable to keep lengths in lockstep.
    fraction_spans = @lift begin
        fracs = $(fracs_obs)
        xs = $xscale

        starts = Float64[]
        ends = Float64[]
        colors = RGBf[]
        label_pts = Point2f[]
        labels = String[]

        for (i, f) in enumerate(fracs)
            x0 = _x(f.start_time_ms, f.start_vol_mL, xs)
            x1 = if !isnothing(f.end_time_ms) && !isnothing(f.end_vol_mL)
                _x(something(f.end_time_ms), something(f.end_vol_mL), xs)
            elseif !isempty($_trend)
                p = $_trend[end]
                _trend_x(p, xs)
            else
                x0
            end

            if x1 > x0
                push!(starts, x0)
                push!(ends, x1)
                push!(colors, FRAC_COLORS[mod1(i, length(FRAC_COLORS))])
                push!(label_pts, Point2f((x0 + x1) / 2, 1.0f0))
                push!(labels, string(f.fraction_number))
            end
        end

        (starts, ends, colors, label_pts, labels)
    end

    frac_xstart = @lift $fraction_spans[1]
    frac_xend = @lift $fraction_spans[2]
    frac_colors = @lift $fraction_spans[3]
    frac_label_pts = @lift $fraction_spans[4]
    frac_labels = @lift $fraction_spans[5]

    vspan!(ax_uv, frac_xstart, frac_xend;
        color=frac_colors, alpha=FRAC_ALPHA, xautolimits=false, yautolimits=false)
    vspan!(ax_pctb, frac_xstart, frac_xend;
        color=frac_colors, alpha=FRAC_ALPHA, xautolimits=false, yautolimits=false)
    vspan!(ax_ov, frac_xstart, frac_xend;
        color=frac_colors, alpha=FRAC_ALPHA, xautolimits=false, yautolimits=false)

    # Fraction number labels in %B panel near baseline (0%)
    text!(ax_pctb, frac_label_pts;
        text=frac_labels, fontsize=12, color=:blue,
        font=:bold, align=(:center, :bottom),
        xautolimits=false, yautolimits=false)

    # ── Other event text labels on UV panel ────────────────────────────────────
    # Filter other events, keeping only the non-tube-feed events (and zero-transition fraction size changes)
    evt_other = @lift begin
        events = $(events_obs)
        # Track fraction volume state to detect zero-transitions
        frac_vol_states = Float64[]
        for e in events
            if e.kind == EVT_LOG && contains(e.text, "Fraction size")
                if (m = match(r"Fraction size (\d+(?:\.\d+)?)", e.text)) !== nothing
                    push!(frac_vol_states, parse(Float64, m.captures[1]))
                end
            end
        end

        # Collect filtered events: exclude tube-feeds, keep zero-transition fraction-size events
        filtered = AktaEvent[]
        frac_vol_prev = 0.0
        frac_vol_idx = 0
        for e in events
            if e.kind == EVT_TUBEFEED || e.kind == EVT_INFO
                continue  # tube feeds are shown as spans, run information in the run log
            elseif e.kind == EVT_LOG && contains(e.text, "Fraction size")
                frac_vol_idx += 1
                frac_vol_current = frac_vol_idx <= length(frac_vol_states) ? frac_vol_states[frac_vol_idx] : 0.0
                # Show only on zero-transitions: 0→>0 or >0→0
                if (frac_vol_prev == 0.0 && frac_vol_current > 0.0) || (frac_vol_prev > 0.0 && frac_vol_current == 0.0)
                    push!(filtered, e)
                end
                frac_vol_prev = frac_vol_current
            else
                push!(filtered, e)
            end
        end
        filtered
    end

    _event_labels!(ax_uv, evt_other, xscale)

    # ── Event legend ──────────────────────────────────────────────────────────
    # legend_elements = [LineElement(color=EVT_COLORS[k][1], linestyle=EVT_COLORS[k][2])
    #                    for k in (EVT_INJECT, EVT_RUN_STATE, EVT_STEP, EVT_LOG)]
    # legend_labels = ["Inject", "State", "Step", "Log"]
    # Legend(left[5, 1], legend_elements, legend_labels;
    #     orientation=:horizontal, framevisible=false, tellwidth=false,
    #     labelsize=11, patchsize=(18, 2))

    # ── Plot toolbar: two groups — view controls, and which panels are shown.
    # In a narrow window the panel group moves to a second row (see respond!).
    tb_view = GridLayout(toolbar[1, 1]; halign=:left, default_colgap=14)
    tb_panels = GridLayout(toolbar[1, 2]; halign=:left, default_colgap=14)
    xmenu = Menu(tb_view[1, 1]; options=["Plot vs time", "Plot vs volume", "Plot vs column volumes"],
        default="Plot vs time", width=150, fontsize=13)
    ov_btn = Button(tb_view[1, 2]; label="Overlay", fontsize=13)
    function check!(layout, col, label; checked=true)
        g = GridLayout(layout[1, col]; default_colgap=4)
        cb = Checkbox(g[1, 1]; checked)
        Label(g[1, 2], label; fontsize=13)
        return cb
    end
    save_btn = Button(tb_view[1, 3]; label="Save plot…", fontsize=13)
    tg_log = check!(tb_view, 4, "Show log"; checked=false)
    # UV is always shown; these switch the other panels (start state: Settings).
    tg_pctb = check!(tb_panels, 1, "%B"; checked="%B" in start_panels)
    tg_cond = check!(tb_panels, 2, "Cond"; checked="Cond" in start_panels)
    tg_ph = check!(tb_panels, 3, "pH"; checked="pH" in start_panels)
    tg_pres = check!(tb_panels, 4, "Pressure"; checked="Pressure" in start_panels)
    tg_rate = check!(tb_panels, 5, "Flow"; checked="Flow" in start_panels)
    # Follow live: auto-rescale to all data on each update. Switched off as soon
    # as the user zooms or pans, so a zoomed view stays put while the run continues.
    tg_follow = check!(tb_panels, 6, "Follow live")
    # Event marks: type a note (optional) and press Mark or Enter; live runs only.
    if !viewer
        mark_txt = Textbox(tb_view[1, 5]; placeholder="Mark note…", width=150, fontsize=13)
        mark_btn = Button(tb_view[1, 6]; label="Mark", fontsize=13)
        function add_mark!()
            note = strip(something(mark_txt.displayed_string[], ""))
            note == strip(something(mark_txt.placeholder[], "")) && (note = "")
            push_event!(app, EVT_MARK, isempty(note) ? "Mark" : String(note))
            mark_txt.stored_string[] = ""
            mark_txt.displayed_string[] = ""
        end
        on(_ -> add_mark!(), mark_btn.clicks)
        # Enter in the note; clearing the box afterwards sets "" and must not mark again.
        on(str -> isnothing(str) || isempty(str) || add_mark!(), mark_txt.stored_string)
    end
    colgap!(toolbar, 28)

    # ── Shown moment: live, or a past moment picked with the time slider ──────
    # The status text and schematic show `shown_state` / `shown_point`: the live
    # instrument state, or the state rebuilt from the log at the selected moment.
    # In viewer mode there is no live state, so the end of the log is the default.
    following = Observable(true)                 # slider at the end
    shown_state = Observable(app.inst[])
    shown_point = Observable{Union{Nothing,TrendPoint}}(nothing)
    shown_header = Observable("")

    # ── Right panel: cards for the run, the readings and the flow path ─────────
    # Typed explicitly: it starts as `nothing` (no flow message yet) and later holds numbers.
    shown_flow = map!(p -> isnothing(p) ? nothing : _flow_at(app.events[], p),
        Observable{Union{Nothing,Float64}}(nothing), shown_point)
    fmt(fmtstr, x) = isnothing(x) ? "—" : Printf.format(Printf.Format(fmtstr), x)

    # Run: what is shown (live / a past moment / end of log), state and position.
    run = card!(right[1, 1], "Run")
    mode = @lift startswith($shown_header, "●") ? ("LIVE", pal.ok) :
                 startswith($shown_header, "◀") ? ("VIEWING", pal.warn) :
                 startswith($shown_header, "End") ? ("END OF LOG", pal.muted) : ("NO DATA", pal.muted)
    chip!(run[1, 1], @lift($mode[1]), @lift($mode[2]))
    Label(run[1, 2:3], @lift(isnothing($shown_point) ? "" : string($shown_state.run_state));
        halign=:right, fontsize=FS_BODY, font=:bold, tellwidth=false)
    function stat!(row, col, name, value)
        g = GridLayout(run[row, col]; halign=:left, default_rowgap=0)
        Label(g[1, 1], name; halign=:left, fontsize=FS_SMALL, color=pal.muted)
        Label(g[2, 1], value; halign=:left, fontsize=15, font=:bold)
    end
    stat!(2, 1, "Run time", @lift(fmt("%.2f min", $shown_state.run_time_ms / 60_000)))
    stat!(2, 2, "Run volume", @lift(fmt("%.3f mL", $shown_state.run_vol_mL)))
    stat!(2, 3, "Set flow", @lift(fmt("%.2f mL/min", $shown_flow)))
    # Run documentation (Run info), as recorded in this log.
    info = @lift run_info($events_obs)
    Label(run[3, 1:3], @lift(join(filter(!isempty, [get($info, "Sample", ""),
            isempty(get($info, "Column", "")) ? "" : "Column " * $info["Column"]]), " · "));
        halign=:left, fontsize=FS_SMALL + 1, color=pal.muted, tellwidth=false)
    colgap!(run, 18)
    foreach(c -> colsize!(run, c, Relative(1 / 3)), 1:3)        # fixed columns: no shifting
    rowgap!(run, 8)

    # Readings: big numbers, named in their trace colour.
    readings = card!(right[2, 1], "Readings")
    for (i, (name, unit, key, f, col)) in enumerate((
        ("UV", "AU", :uv, "%.4f", pal.uv), ("%B", "%", :pctb, "%.1f", pal.pctb),
        ("Cond", "mS/cm", :cond_mScm, "%.2f", pal.cond), ("pH", "", :ph, "%.2f", pal.ph),
        ("Pressure", "MPa", :pres_MPa, "%.3f", pal.pres), ("Temp", "°C", :temp_degC, "%.1f", pal.muted)))
        g = GridLayout(readings[(i - 1) ÷ 3 + 1, (i - 1) % 3 + 1]; halign=:left, default_rowgap=0)
        Label(g[1, 1:2], isempty(unit) ? name : "$name · $unit"; halign=:left, fontsize=FS_SMALL,
            font=:bold, color=col)
        Label(g[2, 1], @lift(isnothing($shown_point) ? "—" : fmt(f, getfield($shown_point, key)));
            halign=:left, fontsize=FS_READING, font=:bold)
        colgap!(g, 4)
    end
    colgap!(readings, 18)
    foreach(c -> colsize!(readings, c, Relative(1 / 3)), 1:3)   # fixed columns: no shifting
    rowgap!(readings, 10)

    # Flow path: one-line valve summary above the schematic.
    path = card!(right[3, 1], "Flow path")
    Label(path[1, 1], @lift(_valve_summary($shown_state, $info)); halign=:left, fontsize=FS_SMALL + 1,
        color=pal.muted, tellwidth=false)
    ax_flow = Axis(path[2, 1]; backgroundcolor=pal.panel,
        xgridvisible=false, ygridvisible=false,
        xticksvisible=false, yticksvisible=false,
        xticklabelsvisible=false, yticklabelsvisible=false,
        leftspinevisible=false, rightspinevisible=false,
        topspinevisible=false, bottomspinevisible=false,
        limits=(0.3, 8.1, 1.3, 13.3))
    rowsize!(right, 3, Auto(1))
    rowgap!(right, 10)
    _draw_flow_schematic!(ax_flow, shown_state, shown_point)

    # Full-extent autoscale of every panel. All linked axes must be reset: one left
    # zoomed keeps the shared x-range stuck. %B keeps its fixed range, flow starts at 0.
    # `all=false` (each refresh while following) resets only the panels on screen;
    # x is shared, and hidden panels catch up when shown.
    function rescale!(; all::Bool=true)
        for ax in plot_axes
            all || ax.leftspinevisible[] || continue     # hidden panels have no spine
            ax.limits[] = ax === ax_pctb ? (nothing, (-3, 103)) :
                          ax === ax_ov ? (nothing, OVERLAY_YLIMS) :
                          ax === ax_rate ? (nothing, (0, nothing)) : (nothing, nothing)
            reset_limits!(ax)
        end
    end

    # On switching time<->volume, relabel the x-axis and reset the limits to fit
    # the data in the new units (equivalent to a zoom reset). Live updates and
    # manual zooming continue to work normally afterwards.
    # Column volumes need the column volume from the run information (Run info);
    # without it the axis falls back to mL and says so.
    apply_xmode!() = batch(_apply_xmode!)
    function _apply_xmode!()
        sel = xmenu.selection[]
        cv = column_volume(run_info(events_obs[]))
        xs = sel == "Plot vs time" ? 0.0 : sel == "Plot vs volume" || cv == 0 ? 1.0 : cv
        lbl = _xlabel(xs) * (sel == "Plot vs column volumes" && cv == 0 ?
                             " — set the column volume under Run info" : "")
        for ax in plot_axes
            ax.xlabel = lbl
        end
        xs == xscale[] && return
        xscale[] = xs
        tg_follow.checked[] = true   # notifies, so this also rescales
    end
    on(_ -> apply_xmode!(), xmenu.selection)
    on(_ -> xmenu.selection[] == "Plot vs column volumes" && apply_xmode!(), events_obs)

    # Save the currently displayed plot (visible panels, current limits) to PDF.
    fig_counter = Ref(0)
    on(save_btn.clicks) do _
        _save_plot_pdf(app, plot_axes,
            (tg_pctb, tg_cond, tg_ph, tg_pres, tg_rate), xscale[], fig_counter;
            overlay=overlay[], highlighted=highlighted[])
    end

    # ── Overlay traces ──────────────────────────────────────────────────────────
    # (key, name, unit, colour, points, visibility toggle — nothing means always shown)
    # The 5th entry reads a trace's value from a point (the flow comes from events).
    ov_channels = (
        (:uv, "UV", "AU", pal.uv, p -> p.uv, nothing),
        (:pctb, "%B", "%", pal.pctb, p -> p.pctb, tg_pctb),
        (:cond, "Cond", "mS/cm", pal.cond, p -> p.cond_mScm, tg_cond),
        (:ph, "pH", "", pal.ph, p -> p.ph, tg_ph),
        (:pres, "Pressure", "MPa", pal.pres, p -> p.pres_MPa, tg_pres),
        (:flow, "Flow", "mL/min", pal.flow, nothing, tg_rate))

    # Clicking a legend entry highlights that trace; clicking it again clears it.
    highlighted = Observable{Union{Nothing,Symbol}}(nothing)
    ov_plots = Dict{Symbol,Any}()
    ov_labels = Dict{Symbol,Observable{String}}()
    ov_ranges = Dict{Symbol,Observable}()
    ov_dummy = (Point2f[Point2f(0, 0)], (0.0f0, 1.0f0))
    for (key, name, unit, col, gety, _) in ov_channels
        # Scaled to the whole run's range; computed only while the overlay is shown.
        norm = isnothing(gety) ? @lift(_normalise($rate_pts, key)) :
               @lift $(panel_shown[:ov]) ?
                     _normalise(_display_points($_trend, gety, $xscale, $xwin), key;
                         range=extrema(gety, $_trend)) : ov_dummy
        ov_ranges[key] = @lift $norm[2]
        ov_labels[key] = @lift _overlay_label(name, unit, $norm[2])
        color = @lift isnothing($highlighted) || $highlighted === key ?
                      RGBAf(col.r, col.g, col.b, 1.0) : RGBAf(col.r, col.g, col.b, 0.2)
        lw = @lift $highlighted === key ? 3.0 : 1.5
        npts = @lift $norm[1]
        ov_plots[key] = key === :flow ?
                        stairs!(ax_ov, npts; step=:post, color=color, linewidth=lw) :
                        lines!(ax_ov, npts; color=color, linewidth=lw)
    end

    # The overlay y-axis shows the highlighted trace's real values.
    on(highlighted) do key
        i = findfirst(c -> c[1] === key, ov_channels)
        _set_overlay_yaxis!(ax_ov, isnothing(i) ? nothing :
            let (_, name, unit, col, _, _) = ov_channels[i]
                (name, unit, col, () -> ov_ranges[key][])
            end)
    end
    # Its range grows with the data, so refresh the ticks when it changes.
    on(trend_obs) do _
        isnothing(highlighted[]) || notify(ax_ov.yticks)
    end

    # Legend: one button per visible trace, inside the top-left of the overlay axis.
    # Rebuilt whenever the visible traces change.
    # The legend is a row of buttons above the overlay plot (in the space on top of
    # its cell), so it never covers data.
    legend = GridLayout(left[7, 1, Top()]; tellwidth=false, halign=:left,
        alignmode=Outside(0, 0, 6, 0), default_colgap=6, default_rowgap=4)
    legend_btns = Pair{Symbol,Button}[]
    _event_labels!(ax_ov, evt_other, xscale)

    function style_legend!()
        for (key, btn) in legend_btns
            on_ = highlighted[] === key
            btn.font = on_ ? :bold : :regular
            btn.buttoncolor = on_ ? ui().accent_soft : RGBAf(ui().panel, 0.9)
        end
    end

    function rebuild_legend!()
        foreach(kb -> delete!(kb[2]), legend_btns)
        empty!(legend_btns)
        trim!(legend)
        overlay[] || return
        for (key, _, _, col, _, tg) in ov_channels
            (isnothing(tg) || tg.checked[]) || continue
            n = length(legend_btns)
            ncol = left.layoutobservables.computedbbox[].widths[1] >= 1000 ? 6 : 3
            btn = Button(legend[n ÷ ncol + 1, n % ncol + 1]; label=ov_labels[key],
                fontsize=12, labelcolor=col, labelcolor_hover=col, labelcolor_active=col,
                buttoncolor_hover=ui().accent_soft, buttoncolor_active=ui().accent_soft,
                strokecolor=(col, 0.6), strokewidth=1, cornerradius=4,
                padding=(6, 6, 3, 3), halign=:left)
            on(btn.clicks) do _
                batch() do
                    highlighted[] = highlighted[] === key ? nothing : key
                    style_legend!()
                end
            end
            push!(legend_btns, key => btn)
        end
        # A highlighted trace that was just hidden cannot stay highlighted.
        any(kb -> kb[1] === highlighted[], legend_btns) || (highlighted[] = nothing)
        style_legend!()
    end

    # ── Panel show/hide ─────────────────────────────────────────────────────────
    # Hiding a panel collapses its row *and* turns off its plots and every
    # decoration, so no orphaned frame, ticks or labels are left behind.  UV is
    # always shown; the toggles drive the other five.  The lowest visible panel
    # carries the shared x tick labels and axis label.  In overlay mode all the
    # stacked panels collapse and only the overlay axis (row 7) is shown.
    panels = ((ax_pctb, 2, tg_pctb), (ax_cond, 3, tg_cond),
        (ax_ph, 4, tg_ph), (ax_pres, 5, tg_pres), (ax_rate, 6, tg_rate))

    function showaxis!(ax, vis)
        ax.ylabelvisible = vis && ax === ax_ov    # stacked panels show their name inside
        ax.yticksvisible = vis
        ax.yticklabelsvisible = vis
        ax.ygridvisible = false   # no horizontal grid lines
        ax.xticksvisible = vis
        ax.leftspinevisible = vis
        ax.bottomspinevisible = vis      # open frame: no top/right spines (theme.jl)
        # x tick labels and the x axis label are re-enabled only on the bottom
        # visible panel, below.
        ax.xticklabelsvisible = false
        ax.xlabelvisible = false
    end

    function setpanel!(ax, row, vis)
        foreach(p -> p.visible[] = vis, ax.scene.plots)
        showaxis!(ax, vis)
        rowsize!(left, row, vis ? Auto() : Fixed(0))
    end

    gap0 = left.addedrowgaps[1]   # the layout's normal gap between panels

    refresh_panels!() = batch(_refresh_panels!)
    function _refresh_panels!()
        ov = overlay[]
        visible = Axis[]
        setpanel!(ax_uv, 1, !ov)
        ov || push!(visible, ax_uv)
        for (ax, row, tg) in panels
            vis = !ov && tg.checked[]
            setpanel!(ax, row, vis)
            vis && push!(visible, ax)
        end
        setpanel!(ax_ov, 7, ov)
        for (k, vis) in ((:uv, !ov), (:pctb, !ov && tg_pctb.checked[]), (:cond, !ov && tg_cond.checked[]),
            (:ph, !ov && tg_ph.checked[]), (:pres, !ov && tg_pres.checked[]), (:ov, ov))
            panel_shown[k][] == vis || (panel_shown[k][] = vis)
        end
        if ov
            for (key, _, _, _, _, tg) in ov_channels
                ov_plots[key].visible[] = isnothing(tg) || tg.checked[]
            end
            push!(visible, ax_ov)
        end
        bottom = visible[end]
        bottom.xticklabelsvisible = true
        bottom.xlabelvisible = true
        # Collapsed rows keep their gaps, so only keep a gap between two shown panels.
        shown = [!ov; [!ov && tg.checked[] for (_, _, tg) in panels]; ov]
        for i in 1:6
            rowgap!(left, i, shown[i] && any(shown[i+1:end]) ? gap0 : Fixed(0))
        end
        rebuild_legend!()
    end

    for (_, _, tg) in panels
        on(_ -> refresh_panels!(), tg.checked)
    end
    on(ov_btn.clicks) do _
        batch() do
            overlay[] = !overlay[]
            ov_btn.label = overlay[] ? "Stacked" : "Overlay"
            refresh_panels!()
            tg_follow.checked[] && rescale!()
        end
    end
    refresh_panels!()

    # A user zoom/pan freezes the view; Ctrl-click (Makie's limit reset) resumes following.
    for ax in plot_axes
        register_interaction!(ax, :follow_live) do event, _
            if event isa ScrollEvent ||
               (event isa MouseEvent &&
                event.type in (MouseEventTypes.leftdragstop, MouseEventTypes.rightdragstop))
                tg_follow.checked[] = false
            elseif event isa MouseEvent && event.type == MouseEventTypes.leftclick &&
                   ispressed(fig, Keyboard.left_control | Keyboard.right_control)
                tg_follow.checked[] = true
            end
            return Consume(false)
        end
    end

    on(tg_follow.checked) do follow
        follow && rescale!()
    end

    on(trend_obs) do _
        tg_follow.checked[] && rescale!(all=false)
    end

    # Downsampling window: the whole run while following, the zoomed range otherwise.
    function update_xwin!()
        l = ax_uv.finallimits[]
        w = tg_follow.checked[] ? (-Inf, Inf) : (Float64(l.origin[1]), Float64(l.origin[1] + l.widths[1]))
        w == xwin[] || (xwin[] = w)
    end
    on(_ -> update_xwin!(), ax_uv.finallimits)
    on(_ -> update_xwin!(), tg_follow.checked)

    # ── Status bar: connection · recording · mouse help ────────────────────────
    Box(fig[r+2, 1]; color=pal.panel, strokecolor=pal.border, cornerradius=6)
    statusbar = GridLayout(fig[r+2, 1]; alignmode=Outside(6), tellwidth=false)
    # Every item has a fixed-width slot (chips sit at its left), so a changing
    # text or a blinking chip never moves the others.
    col = 0
    function slot!(width)
        g = GridLayout(statusbar[1, col += 1]; halign=:left)
        colsize!(statusbar, col, Fixed(width))
        return g
    end
    if !isnothing(status)
        # Connection chip: green connected, amber waiting, red port missing, blue demo.
        chip!(slot!(330)[1, 1], @lift(replace($status, "● " => "")), @lift(status_color($status)))
        demo = @lift startswith($status, "Demo")
        chip!(slot!(56)[1, 1], @lift($demo ? "DEMO" : ""),
            @lift($demo ? pal.demo : RGBAf(0, 0, 0, 0)))
    end
    recording = @lift begin
        td = $(trend_obs)
        $(events_obs)
        file = basename(app.log_filename)
        if viewer
            "Viewing $file · $(length(td)) points"
        elseif isnothing(app.csv_io)
            "Not recording"
        else
            t = isempty(td) ? 0.0 : td[end].cum_time_ms / 60_000
            "$file · $(@sprintf("%.1f", t)) min"
        end
    end
    is_rec = @lift !viewer && !isnothing(app.csv_io) && $recording != "Not recording"
    # REC chip with a blinking dot while writing a log.
    blink = Observable(true)
    # REC chip blinks by fading its colour; the text (and so its width) stays the same.
    chip!(slot!(120)[1, 1], @lift($is_rec ? "● REC" : "NOT RECORDING"),
        @lift(RGBAf($is_rec ? pal.rec : pal.faint, $is_rec && !$blink ? 0.45 : 1.0)))
    Label(slot!(380)[1, 1], recording; halign=:left, fontsize=FS_SMALL + 1, color=pal.muted)
    help_lbl = Label(statusbar[1, col+=1], "Drag: zoom · Right-drag: pan · Ctrl-click: reset · Alt/Shift-click: inspect moment";
        halign=:right, fontsize=FS_SMALL, color=pal.muted, tellwidth=false)
    colgap!(statusbar, 10)
    viewer || _precompiling() || @async while true   # a flag flip every 0.6 s; ends with the program
        sleep(0.6)
        is_rec[] && (blink[] = !blink[])
    end

    # ── Time slider: inspect a past moment ─────────────────────────────────────
    # Selects a trend point; at the right end it follows the newest data. The
    # moment is marked in every panel, and status + schematic show its state.
    slider_row = left[8, 1] = GridLayout(; tellwidth=false)
    sel_slider = Slider(slider_row[1, 1]; range=1:1, startvalue=1)
    sel_label = Label(slider_row[1, 2], ""; width=170, halign=:left, fontsize=13)
    end_btn = Button(slider_row[1, 3]; label=viewer ? "End" : "Live", fontsize=13)
    colgap!(slider_row, 10)

    update_shown!() = batch(_update_shown!)
    function _update_shown!()
        td = app.trend_data[]
        i = clamp(sel_slider.value[], 1, max(1, length(td)))
        p = isempty(td) ? nothing : td[i]
        if following[] && !viewer
            shown_state[] = app.inst[]
            shown_header[] = "● Live"
            sel_label.text = "Live"
        elseif isnothing(p)
            shown_header[] = ""
            sel_label.text = ""
        else
            shown_state[] = _state_at(app.events[], p)
            where = @sprintf("%.2f min · %.3f mL", p.cum_time_ms / 60_000, p.cum_vol_mL)
            shown_header[] = (following[] ? "End of log: " : "◀ Viewing: ") * where
            sel_label.text = where
        end
        shown_point[] = p
    end

    on(sel_slider.value) do i
        following[] = i >= length(app.trend_data[])
        update_shown!()
    end
    on(end_btn.clicks) do _
        set_close_to!(sel_slider, length(app.trend_data[]))
        following[] = true
        update_shown!()
    end
    # New data: extend the slider; keep the newest point selected while following.
    on(trend_obs) do td
        sel_slider.range[] = 1:max(1, length(td))
        following[] ? set_close_to!(sel_slider, length(td)) : update_shown!()
    end
    live_view() = following[] && !viewer
    on(_ -> live_view() && update_shown!(), inst_obs)            # live state changed
    on(_ -> live_view() || update_shown!(), events_obs)          # a past state may change

    # Dashed marker at the selected moment in every panel (none while following live).
    marker_x = @lift begin
        td = $(trend_obs)
        $following || isempty(td) ? Float32[] :
            [_trend_x(td[clamp($(sel_slider.value), 1, length(td))], $xscale)]
    end
    for ax in plot_axes
        # Alt- or Shift-click jumps the slider to the nearest data point.
        register_interaction!(ax, :inspect_moment) do event, _
            event isa MouseEvent && event.type == MouseEventTypes.leftclick || return Consume(false)
            ispressed(fig, Keyboard.left_alt | Keyboard.right_alt | Keyboard.left_shift |
                           Keyboard.right_shift) || return Consume(false)
            td = app.trend_data[]
            isempty(td) && return Consume(false)
            xs = _trend_x.(td, xscale[])
            set_close_to!(sel_slider, argmin(abs.(xs .- event.data[1])))
            return Consume(true)
        end
    end

    # ── Run log: every event as a list below the slider ────────────────────────
    # Filter by text, scroll with the wheel, click a line to inspect that moment.
    logpane = GridLayout(left[9, 1]; tellwidth=false)
    log_blocks = Any[]
    log_listeners = Any[]
    # Lines in the log: fewer on short windows, so the plots keep their room.
    log_rows() = clamp((round(Int, fig.scene.viewport[].widths[2]) - 650) ÷ 17, 4, 10)
    shown_log_rows = Ref(0)
    function open_log!()
        filt = Textbox(logpane[1, 1]; placeholder="Filter the run log…", width=260, fontsize=13,
            halign=:left, tellwidth=false)      # the list below sets the width, not the box
        LOG_ROWS = shown_log_rows[] = log_rows()
        rowsize!(left, 9, Auto())
        lax = Axis(logpane[2, 1]; height=LOG_ROWS * 17 + 8, backgroundcolor=pal.panel,
            limits=(0, 100, nothing, nothing), leftspinevisible=false, bottomspinevisible=false)
        hidedecorations!(lax)
        for name in (:rectanglezoom, :dragpan, :limitreset, :scrollzoom)
            deregister_interaction!(lax, name)
        end
        append!(log_blocks, (filt, lax))
        query = Observable("")
        push!(log_listeners, on(str -> query[] = lowercase(strip(something(str, ""))), filt.displayed_string))
        rows = lift(events_obs, query) do evts, q
            filter(e -> isempty(q) || occursin(q, lowercase(e.text)) ||
                        occursin(q, lowercase(string(e.kind))), evts)
        end
        push!(log_listeners, rows.inputs...)
        kind_name(k) = replace(string(k), "EVT_" => "")
        kind_col(k) = k == EVT_MARK ? :darkorange : k == EVT_INFO ? pal.muted : pal.text
        cols = ((1, e -> @sprintf("%.2f min", e.cum_time_ms / 60_000), e -> pal.muted),
            (10, e -> @sprintf("%.3f mL", e.cum_vol_mL), e -> pal.muted),
            (19, e -> kind_name(e.kind), e -> kind_col(e.kind)),
            (29, e -> e.text, e -> kind_col(e.kind)))
        for (x, txt, col) in cols
            text!(lax, @lift([Point2f(x, -k) for k in eachindex($rows)]);
                text=@lift([txt(e) for e in $rows]), color=@lift([col(e) for e in $rows]),
                fontsize=12, align=(:left, :center))
        end
        # Scroll position: first visible row; follows the newest event when at the end.
        top = Observable(1)
        last_top(n) = max(1, n - LOG_ROWS + 1)
        push!(log_listeners, on(top) do t
            ylims!(lax, -(t + LOG_ROWS - 1) - 0.5, -t + 0.5)
        end)
        at_end = Ref(true)
        push!(log_listeners, on(rows) do r
            at_end[] && (top[] = last_top(length(r)))
        end)
        top[] = last_top(length(rows[]))
        register_interaction!(lax, :scroll_log) do event, _
            event isa ScrollEvent || return Consume(false)
            n = length(rows[])
            top[] = clamp(top[] - round(Int, 3 * sign(event.y)), 1, last_top(n))
            at_end[] = top[] == last_top(n)
            return Consume(true)
        end
        register_interaction!(lax, :inspect_log) do event, _
            event isa MouseEvent && event.type == MouseEventTypes.leftclick || return Consume(false)
            k = round(Int, -event.data[2])
            r = rows[]
            (1 <= k <= length(r) && !isempty(app.trend_data[])) || return Consume(false)
            # the trend point at (or just after) the event's time
            i = _first_at_or_after(app.trend_data[], r[k].cum_time_ms / 60_000, 0.0)
            set_close_to!(sel_slider, clamp(i, 1, length(app.trend_data[])))
            return Consume(true)
        end
    end
    function close_log!()
        foreach(off, log_listeners)
        empty!(log_listeners)
        foreach(delete!, log_blocks)
        empty!(log_blocks)
        trim!(logpane)
        rowsize!(left, 9, Fixed(0))          # a closed log takes no room (overlay gets it)
        shown_log_rows[] = 0
    end
    on(checked -> batch(checked ? open_log! : close_log!), tg_log.checked)
    rowsize!(left, 9, Fixed(0))

    # ── Hover readout: values under the mouse in every panel ──────────────────
    hover_x = Observable(Float32[])

    # ── Top layer: the marker and hover lines and the tooltip, drawn once over all
    # panels (in pixels) instead of once per panel: fewer plot objects. ─────────
    top = Scene(fig.scene; camera=campixel!, clear=false)
    geometry = Observable(0)             # bumped when the panels move or the x range changes
    for a in plot_axes
        on(_ -> (geometry[] += 1), a.scene.viewport)
    end
    on(_ -> (geometry[] += 1), ax_uv.finallimits)
    # Vertical lines at data x through all visible panels, as pixel segments.
    function column_lines(xs)
        vis = [a for a in plot_axes if a.leftspinevisible[]]
        pts = Point2f[]
        (isempty(xs) || isempty(vis)) && return pts
        l, vp = vis[1].finallimits[], vis[1].scene.viewport[]
        ylo = minimum(a.scene.viewport[].origin[2] for a in vis)
        yhi = maximum(a.scene.viewport[].origin[2] + a.scene.viewport[].widths[2] for a in vis)
        for x in xs
            l.origin[1] <= x <= l.origin[1] + l.widths[1] || continue
            px = vp.origin[1] + (x - l.origin[1]) / l.widths[1] * vp.widths[1]
            push!(pts, Point2f(px, ylo), Point2f(px, yhi))
        end
        return pts
    end
    linesegments!(top, @lift(($geometry; column_lines($marker_x))); color=(pal.text, 0.6),
        linestyle=:dash, linewidth=1.5)
    linesegments!(top, @lift(($geometry; column_lines($hover_x))); color=(pal.muted, 0.6), linewidth=1)
    tip = tooltip!(top, Point2f(0, 0); text="", visible=false, fontsize=FS_SMALL + 1,
        backgroundcolor=pal.panel, textcolor=pal.text, outline_color=pal.border,
        outline_linewidth=1, placement=:right, triangle_size=6)
    function hover!(ax, x, y)
        td = app.trend_data[]
        isempty(td) && return
        xs = xscale[]
        i = clamp(_first_at_or_after(td, x, xs), 1, length(td))
        i > 1 && abs(_trend_x(td[i-1], xs) - x) < abs(_trend_x(td[i], xs) - x) && (i -= 1)
        p = td[i]
        hover_x[] = [_trend_x(p, xs)]
        mp = events(fig).mouseposition[]
        tip[1][] = Point2f(mp[1], mp[2])
        tip.text[] = @sprintf("%.2f min · %.3f mL\nUV %.4f AU   %%B %.1f\nCond %.2f mS/cm   pH %.2f\nPressure %.3f MPa",
            p.cum_time_ms / 60_000, p.cum_vol_mL, p.uv, p.pctb, p.cond_mScm, p.ph, p.pres_MPa)
        tip.placement[] = x > (ax.finallimits[].origin[1] + ax.finallimits[].widths[1] / 2) ? :left : :right
        tip.visible[] || (tip.visible[] = true)
    end
    function unhover!()
        isempty(hover_x[]) && return
        hover_x[] = Float32[]
        tip.visible[] && (tip.visible[] = false)
    end
    on(events(fig).mouseposition) do _
        ax = findfirst(a -> a.leftspinevisible[] && is_mouseinside(a.scene), collect(plot_axes))
        if isnothing(ax)
            unhover!()
        else
            a = plot_axes[ax]
            mp = mouseposition(a.scene)
            hover!(a, mp[1], mp[2])
        end
    end

    # ── Small windows: keep everything readable ───────────────────────────────
    # The right column keeps at least 340 px; when the toolbar does not fit in one
    # row its panel checkboxes move to a second row; the mouse help is hidden when
    # narrow; the run log and the overlay legend adapt to the window.
    GLB = Makie.GridLayoutBase
    panels_below = Ref(false)
    tbwidth(gl) = something(GLB.determinedirsize(gl, GLB.Col()), 600.0)
    function respond!()
        w, h = fig.scene.viewport[].widths
        batch() do
            rightw = round(Int, clamp(0.25w, 340, 480))
            colsize!(body, 1, Auto())
            colsize!(body, 2, Fixed(rightw))
            fits = tbwidth(tb_view) + tbwidth(tb_panels) + 28 <= w - rightw - 60
            if fits == panels_below[]
                fits ? (toolbar[1, 2] = tb_panels) : (toolbar[2, 1] = tb_panels)
                panels_below[] = !fits
                trim!(toolbar)
            end
            help_lbl.visible = w >= 1350
            shown_log_rows[] > 0 && shown_log_rows[] != log_rows() && (close_log!(); open_log!())
            overlay[] && rebuild_legend!()
        end
    end
    on(_ -> respond!(), fig.scene.viewport)
    respond!()

    sel_slider.range[] = 1:max(1, length(app.trend_data[]))
    set_close_to!(sel_slider, length(app.trend_data[]))
    update_shown!()

    finish_layout!(fig)
    return fig
end

# ─────────────────────────────────────────────────────────────────────────────
# Plot export helpers
# ─────────────────────────────────────────────────────────────────────────────

_channel_value(p::TrendPoint, chan::Symbol)::Float64 =
    chan === :uv ? p.uv :
    chan === :pctb ? p.pctb :
    chan === :cond ? p.cond_mScm :
    chan === :ph ? p.ph : p.pres_MPa

# Shade fraction-collection spans (and optionally number them) on a static axis.
function _draw_fraction_spans!(ax, fracs::Vector{Fraction}, trend::Vector{TrendPoint},
    xs::Real; labels::Bool=false)
    isempty(fracs) && return
    lastx = isempty(trend) ? 0.0 :
            _trend_x(trend[end], xs)
    starts = Float64[]
    ends = Float64[]
    cols = RGBf[]
    lblpts = Point2f[]
    lbls = String[]
    for (i, f) in enumerate(fracs)
        x0 = _x(f.start_time_ms, f.start_vol_mL, xs)
        x1 = if !isnothing(f.end_time_ms) && !isnothing(f.end_vol_mL)
            _x(f.end_time_ms, f.end_vol_mL, xs)
        else
            lastx
        end
        if x1 > x0
            push!(starts, x0)
            push!(ends, x1)
            push!(cols, FRAC_COLORS[mod1(i, length(FRAC_COLORS))])
            push!(lblpts, Point2f((x0 + x1) / 2, 1.0f0))
            push!(lbls, string(f.fraction_number))
        end
    end
    isempty(starts) && return
    vspan!(ax, starts, ends; color=cols, alpha=FRAC_ALPHA)
    labels && text!(ax, lblpts; text=lbls, fontsize=12, color=:blue,
        font=:bold, align=(:center, :bottom))
    return
end

# Render the currently displayed chromatogram (only the visible panels, with the
# current axis limits) to a PDF via CairoMakie.  Files are numbered per session:
# <prefix>_<date>_<time>_figure_N.pdf
function _save_plot_pdf(app::AppState, axes, toggles, xs::Real, counter::Ref{Int};
    overlay::Bool=false, highlighted::Union{Nothing,Symbol}=nothing)
    trend = copy(app.trend_data[])
    if isempty(trend)
        @warn "Nothing to save yet — no data on the plot"
        return
    end
    events = copy(app.events[])
    fracs = copy(app.fractions[])
    ax_uv, ax_pctb, ax_cond, ax_ph, ax_pres, ax_rate, ax_ov = axes
    tg_pctb, tg_cond, tg_ph, tg_pres, tg_rate = toggles

    # Visible panels top-to-bottom (UV always); keep the source axis for its y-limits.
    specs = Tuple{Axis,Symbol,String,RGBf}[(ax_uv, :uv, "UV (AU)", COL_UV)]
    tg_pctb.checked[] && push!(specs, (ax_pctb, :pctb, "%B", COL_PCTB))
    tg_cond.checked[] && push!(specs, (ax_cond, :cond, "Conductivity (mS/cm)", COL_COND))
    tg_ph.checked[] && push!(specs, (ax_ph, :ph, "pH", COL_PH))
    tg_pres.checked[] && push!(specs, (ax_pres, :pres, "Pressure (MPa)", COL_PRES))
    tg_rate.checked[] && push!(specs, (ax_rate, :flow, "Flow (mL/min)", COL_FLOW))

    xr = ax_uv.finallimits[]
    xlo, xhi = xr.origin[1], xr.origin[1] + xr.widths[1]
    xlab = _xlabel(xs)

    # Both views on one page: the stacked panels, then the overlay below them.
    # The overlay keeps its on-screen y-range only when it is the view being shown.
    yr = ax_ov.finallimits[]
    ov_ylims = overlay ? (yr.origin[2], yr.origin[2] + yr.widths[2]) : OVERLAY_YLIMS
    # Paper is white: the export always uses the light theme, even in dark mode.
    expfig = with_theme(makie_theme(LIGHT)) do
        f = Figure(size=(1000, 200 * length(specs) + 500), backgroundcolor=:white)
        _stacked_export!(f[1, 1], trend, events, fracs, specs, xs, xlab, (xlo, xhi))
        _overlay_export!(f[2, 1], trend, events, fracs, specs, xs, xlab, (xlo, xhi),
            ov_ylims, highlighted)
        rowsize!(f.layout, 2, Relative(500 / (200 * length(specs) + 500)))
        f
    end

    counter[] += 1
    prefix = isempty(app.log_prefix) ? "akta" : app.log_prefix
    stamp = Dates.format(Dates.now(), "yyyymmdd_HHMMSS")
    path = joinpath(app.log_dir, "$(prefix)_$(stamp)_figure_$(counter[]).pdf")

    CairoMakie.activate!()
    try
        save(path, expfig)
        @info "Saved plot to $path"
    catch err
        @error "Could not save plot" exception = err
    finally
        GLMakie.activate!()
    end
    return
end

# Data points of one channel for export, in the current x units.
_export_points(chan::Symbol, trend, events, xs::Real)::Vector{Point2f} =
    chan === :flow ? _flow_setpoints(events, trend, xs) :
    [Point2f(_trend_x(p, xs), _channel_value(p, chan)) for p in trend]

# Stacked export: one panel per visible channel, each with its on-screen y-limits.
function _stacked_export!(pos, trend, events, fracs, specs, xs::Real, xlab, (xlo, xhi))
    grid = GridLayout(pos)
    exaxes = Axis[]
    for (i, (srcax, chan, ylab, col)) in enumerate(specs)
        bottom = i == length(specs)
        ax = Axis(grid[i, 1]; ylabel=ylab, xlabel=(bottom ? xlab : ""),
            xgridvisible=false, ygridvisible=false, xticklabelsvisible=bottom)
        (chan === :uv || chan === :pctb) &&
            _draw_fraction_spans!(ax, fracs, trend, xs; labels=(chan === :pctb))
        if chan === :uv
            for e in events
                c, style = get(EVT_COLORS, e.kind, (:black, :dash))
                vlines!(ax, [_event_x(e, xs)]; color=(c, 0.55), linestyle=style, linewidth=1.0)
            end
        end
        pts = _export_points(chan, trend, events, xs)
        if chan === :flow
            isempty(pts) || stairs!(ax, pts; step=:post, color=col, linewidth=1.5)
        else
            lines!(ax, pts; color=col, linewidth=1.5)
        end
        yr = srcax.finallimits[]
        ylims!(ax, yr.origin[2], yr.origin[2] + yr.widths[2])
        push!(exaxes, ax)
    end
    linkxaxes!(exaxes...)
    xlims!(exaxes[1], xlo, xhi)
    return
end

# Overlay export: every visible channel on one axis scaled to 0–100 %, with the
# on-screen highlight (y-axis in its units) and a legend giving each trace's range.
function _overlay_export!(pos, trend, events, fracs, specs, xs::Real, xlab,
    (xlo, xhi), (ylo, yhi), highlighted)
    ax = Axis(pos; xlabel=xlab, xgridvisible=false, ygridvisible=false)
    _set_overlay_yaxis!(ax, nothing; p=LIGHT)
    _draw_fraction_spans!(ax, fracs, trend, xs)
    for e in events
        c, style = get(EVT_COLORS, e.kind, (:black, :dash))
        vlines!(ax, [_event_x(e, xs)]; color=(c, 0.55), linestyle=style, linewidth=1.0)
    end
    names = Dict(:uv => ("UV", "AU"), :pctb => ("%B", "%"), :cond => ("Cond", "mS/cm"),
        :ph => ("pH", ""), :pres => ("Pressure", "MPa"), :flow => ("Flow", "mL/min"))
    for (_, chan, _, col) in specs
        pts = _export_points(chan, trend, events, xs)
        isempty(pts) && continue
        scaled, range = _normalise(pts, chan)
        dim = !isnothing(highlighted) && highlighted !== chan
        color = RGBAf(col.r, col.g, col.b, dim ? 0.2 : 1.0)
        lw = highlighted === chan ? 3.0 : 1.5
        label = replace(_overlay_label(names[chan]..., range), "━━  " => "")
        highlighted === chan && _set_overlay_yaxis!(ax, (names[chan]..., col, () -> range); p=LIGHT)
        chan === :flow ?
            stairs!(ax, scaled; step=:post, color=color, linewidth=lw, label=label) :
            lines!(ax, scaled; color=color, linewidth=lw, label=label)
    end
    axislegend(ax; position=:lt, framevisible=true, labelsize=11)
    limits!(ax, xlo, xhi, ylo, yhi)
    return
end

# ─────────────────────────────────────────────────────────────────────────────
function _draw_flow_schematic!(ax, state::Observable{InstrumentState},
    point::Observable{Union{Nothing,TrendPoint}})
    pal = ui()
    # Soft fill of a state colour, blended onto the card so it stays opaque:
    # pipes ending under a node must not show through its label.
    tint(c, a=0.22) = RGBf(a * c.r + (1 - a) * pal.panel.r, a * c.g + (1 - a) * pal.panel.g,
        a * c.b + (1 - a) * pal.panel.b)

    # Rounded rectangle; radii in data units, the y one larger as the axis is
    # taller than wide in data units per pixel.
    function rrect(cx, cy, w, h; rx=0.14, ry=0.18, n=6)
        pts = Point2f[]
        for (ccx, ccy, a0) in ((cx + w/2 - rx, cy + h/2 - ry, 0.0), (cx - w/2 + rx, cy + h/2 - ry, π/2),
                               (cx - w/2 + rx, cy - h/2 + ry, π), (cx + w/2 - rx, cy - h/2 + ry, 3π/2))
            for k in 0:n
                t = a0 + (π/2) * k / n
                push!(pts, Point2f(ccx + rx * cos(t), ccy + ry * sin(t)))
            end
        end
        return pts
    end
    # Boxes grow to fit their label with a margin (≈0.16 data units per character).
    fitw(label, w) = max(w, 0.16 * length(label) + 0.55)
    box_h = 0.86
    # Static boxes and labels are collected and drawn as one polygon plot and one
    # text plot: few plot objects keep every frame and every new page cheap.
    node_shapes, node_colors = Vector{Point2f}[], RGBf[]
    label_texts, label_pos = String[], Point2f[]
    label!(x, y, text) = (push!(label_texts, text); push!(label_pos, Point2f(x, y)))
    function node!(cx, cy, w, h, label; color=pal.node)
        push!(node_shapes, rrect(cx, cy, fitw(label, w), max(h, box_h)))
        push!(node_colors, RGBf(color))
        label!(cx, cy, label)
    end
    diamond(cx, cy, w, h) = Point2f[(cx, cy + h/2), (cx + w/2, cy), (cx, cy - h/2), (cx - w/2, cy)]

    # Pipes are drawn only while liquid flows through them: each pipe is a record
    # here, and the active ones are drawn together as one segments plot (on(state)).
    pipes = Dict{Symbol,Any}[]
    function pipe!(xs, ys; color=pal.pipe, lw=3.2)
        # a path through several points is stored as consecutive segments
        segs = [Point2f(xs[k+j], ys[k+j]) for k in 1:length(xs)-1 for j in 0:1]
        pp = Dict{Symbol,Any}(:pts => segs, :color => RGBAf(color), :lw => Float32(lw),
            :visible => false, :alpha => 1.0)
        push!(pipes, pp)
        return pp
    end
    setvisible!(pp, active) = (pp[:visible] = active)

    # ── Node coordinates (staggered vertically for readability) ─────────────
    x_l, x_c, x_r = 1.3, 4.2, 7.1
    x_frac = x_r

    y_buf = 11.3
    y_mix = 10.3
    y_syr = 9.4
    y_inj = 8.5
    y_loop = 7.6
    y_waste_inj = 7.6
    y_col = 6.6
    y_waste_loop = 5.8
    y_uv = 5.0
    y_out = 3.6
    y_bottom = 2.4

    # ── Buffer valve: 8 inlet ports in a row above it, feeding the A side ───
    # The active port is filled and piped to the valve; the valve feeds the mixer
    # (switch valve), where buffer B is mixed in.
    # Buffer A sits in the left column with the waste outlets. The ports form a row
    # starting right above it (port 1, the standard buffer A, straight above), and
    # the active one is piped down to a short manifold line, then into Buffer A.
    n_ports = 8
    x_vlv = x_l
    y_port = 12.45
    y_manifold = 12.0
    port_x = [x_vlv + 0.62 * (i - 1) for i in 1:n_ports]
    port_color(i) = i == 1 ? pal.buf_a : i == n_ports ? pal.sample : pal.buf_port

    ln_ports = [i == 1 ? pipe!([x_vlv, x_vlv], [y_port - 0.24, y_buf + 0.31]; color=port_color(i), lw=2.6) :
                pipe!([port_x[i], port_x[i], x_vlv, x_vlv], [y_port - 0.24, y_manifold, y_manifold, y_buf + 0.31];
                    color=port_color(i), lw=2.6) for i in 1:n_ports]

    # Geometry chosen to mirror the requested routing diagrams.
    ln_buf_a = pipe!([x_vlv, x_c], [y_buf - 0.31, y_mix + 0.02]; color=pal.buf_a)
    ln_buf_b = pipe!([x_frac, x_c], [11.0, y_mix + 0.02]; color=pal.buf_b)
    ln_mix_to_valve = pipe!([x_c, x_c], [y_mix - 0.38, y_inj + 0.42])

    # ── Switchable paths (inject + syringe + output valve) ──────────────────
    ln_load_core = pipe!([x_c, x_c], [y_inj - 0.42, y_col + 0.42])
    ln_inj_to_loop = pipe!([x_c, x_r], [y_inj, y_loop])
    ln_inj_return = pipe!([x_r, x_c], [y_loop, y_col])
    ln_waste_byp = pipe!([x_c, x_l], [y_inj, y_waste_inj])

    ln_syr_to_loop = pipe!([x_r, x_r], [y_syr - 0.34, y_loop + 0.34]; lw=2.6)
    ln_loop_waste = pipe!([x_r, x_r], [y_loop - 0.34, y_waste_loop + 0.34]; lw=2.6)

    ln_col_to_uv = pipe!([x_c, x_c], [y_col - 0.42, y_uv + 0.42])
    ln_uv_to_out = pipe!([x_c, x_c], [y_uv - 0.42, y_out + 0.40])
    ln_out_waste = pipe!([x_c, x_l], [y_out, y_bottom]; color=pal.muted)
    ln_out_frac = pipe!([x_c, x_frac], [y_out, y_bottom]; color=pal.frac)
    pipe_data = Observable((Point2f[], RGBAf[], Float32[]))
    linesegments!(ax, @lift($pipe_data[1]); color=@lift($pipe_data[2]), linewidth=@lift($pipe_data[3]),
        linecap=:round)

    # ── Nodes ────────────────────────────────────────────────────────────────
    # The 8 ports: one polygon plot and one text plot, coloured per port.
    port_fill = Observable(fill(RGBf(pal.node), n_ports))
    port_stroke = Observable(fill(RGBf(pal.border), n_ports))
    port_tcol = Observable(fill(RGBf(pal.node_text), n_ports))
    poly!(ax, [rrect(port_x[i], y_port, 0.50, 0.48; rx=0.08, ry=0.10) for i in 1:n_ports];
        color=port_fill, strokecolor=port_stroke, strokewidth=1.2)
    text!(ax, Point2f.(port_x, y_port); text=string.(1:n_ports), fontsize=10,
        align=(:center, :center), font=:bold, color=port_tcol)
    text!(ax, [Point2f(port_x[1], y_port + 0.30), Point2f(port_x[end], y_port + 0.30)];
        text=["A", "Sample"], fontsize=9, align=(:center, :bottom), color=pal.muted)
    # The A side of the mixer: fed by the buffer valve, coloured by its active port.
    vlv_poly = poly!(ax, rrect(x_vlv, y_buf, fitw("Buffer A", 1.3), box_h); color=tint(pal.buf_a),
        strokecolor=pal.buf_a, strokewidth=1.5)
    label!(x_vlv, y_buf, "Buffer A")
    node!(x_frac, y_buf, 1.30, 0.62, "Buffer B"; color=tint(pal.buf_b, 0.35))
    inj_poly = poly!(ax, diamond(x_c, y_inj, 2.3, 1.15); color=pal.node, strokecolor=pal.border,
        strokewidth=1.5)
    node!(x_c, y_col, 1.35, 0.74, "Column")
    node!(x_c, y_uv, 1.48, 0.78, "UV / Cond")
    out_poly = poly!(ax, diamond(x_c, y_out, 1.6, 1.0); color=pal.node, strokecolor=pal.border,
        strokewidth=1.5)
    node!(x_r, y_syr, 1.45, 0.62, "Syringe")
    node!(x_r, y_loop, 1.20, 0.62, "Loop")
    node!(x_frac, y_bottom, 1.25, 0.68, "Frac"; color=tint(pal.frac, 0.30))
    node!(x_l, y_bottom, 1.30, 0.62, "Waste")
    node!(x_r, y_waste_loop, 1.30, 0.62, "Waste")
    node!(x_l, y_waste_inj, 1.30, 0.62, "Waste")
    label!(x_c, y_out, "Out")
    poly!(ax, node_shapes; color=node_colors, strokecolor=pal.border, strokewidth=1.2)
    text!(ax, label_pos; text=label_texts, fontsize=10, align=(:center, :center), font=:bold,
        color=pal.node_text)

    # ── MIXER — colour blends the A side (active port) with buffer B by %B ──
    mixer_color = @lift begin
        p = $point
        a = port_color($state.buffer_port)
        f = isnothing(p) ? 0.0 : clamp(p.pctb / 100.0, 0.0, 1.0)
        tint(RGBf((1 - f) * a.r + f * pal.buf_b.r, (1 - f) * a.g + f * pal.buf_b.g,
            (1 - f) * a.b + f * pal.buf_b.b), 0.45)
    end
    poly!(ax, rrect(x_c, y_mix, fitw("100 %B", 1.3), box_h); color=mixer_color,
        strokecolor=pal.border, strokewidth=1.2)
    mixer_label = @lift isnothing($point) ? "MIX" : @sprintf("%.0f %%B", $point.pctb)
    text!(ax, x_c, y_mix; text=mixer_label, fontsize=11, align=(:center, :center), font=:bold,
        color=pal.node_text)

    inj_txt = text!(ax, x_c, y_inj; text="LOAD", fontsize=10,
        align=(:center, :center), font=:bold, color=pal.node_text)
    out_txt = text!(ax, x_c, y_out - 1.0; text="TO WASTE", fontsize=9,
        align=(:center, :center), font=:bold, color=pal.muted)

    on(state) do s
        is_load = s.inject_value == IV_LOAD
        is_inj = s.inject_value == IV_INJECT
        is_wst = s.inject_value == IV_WASTE
        is_unk = s.inject_value == IV_UNKNOWN

        has_known_path = !is_unk
        setvisible!(ln_buf_a, has_known_path)

        # Buffer valve: fill and pipe the active port; dimmed while only assumed.
        port = s.buffer_port
        pcol = port_color(port)
        alpha = s.buffer_port_known ? 1.0 : 0.45
        port_fill[] = [i == port ? tint(pcol, alpha) : RGBf(pal.node) for i in 1:n_ports]
        port_stroke[] = [i == port ? RGBf(pcol) : RGBf(pal.border) for i in 1:n_ports]
        port_tcol[] = [i == port && s.buffer_port_known ? RGBf(1, 1, 1) : RGBf(pal.node_text) for i in 1:n_ports]
        for i in 1:n_ports
            setvisible!(ln_ports[i], has_known_path && i == port)
            ln_ports[i][:alpha] = alpha
        end
        ln_buf_a[:color] = RGBAf(pcol.r, pcol.g, pcol.b, alpha)
        vlv_poly.color[] = tint(pcol, 0.25 * alpha)
        vlv_poly.strokecolor[] = tint(pcol, alpha)
        setvisible!(ln_buf_b, has_known_path)
        setvisible!(ln_mix_to_valve, has_known_path)

        setvisible!(ln_load_core, has_known_path && is_load)
        setvisible!(ln_inj_to_loop, has_known_path && is_inj)
        setvisible!(ln_inj_return, has_known_path && is_inj)
        setvisible!(ln_waste_byp, has_known_path && is_wst)

        setvisible!(ln_syr_to_loop, has_known_path && is_load)
        setvisible!(ln_loop_waste, has_known_path && is_load)

        to_column = has_known_path && (is_load || is_inj)
        setvisible!(ln_col_to_uv, to_column)
        setvisible!(ln_uv_to_out, to_column)

        out_to_frac = s.fraction_vol_mL > 0
        setvisible!(ln_out_frac, has_known_path && out_to_frac)
        setvisible!(ln_out_waste, has_known_path && !out_to_frac)

        # Valves: soft tint of their state colour, outlined in it.
        inj_col = is_unk ? pal.err : is_wst ? pal.muted : is_inj ? pal.warn : pal.accent
        inj_poly.color[] = tint(inj_col)
        inj_poly.strokecolor[] = inj_col
        out_col = out_to_frac ? pal.frac : pal.muted
        out_poly.color[] = tint(out_col)
        out_poly.strokecolor[] = out_col

        # all active pipes in one segments plot (two points per pipe)
        active = filter(pp -> pp[:visible], pipes)
        pipe_data[] = (reduce(vcat, (pp[:pts] for pp in active); init=Point2f[]),
            reduce(vcat, (fill(RGBAf(pp[:color], pp[:alpha] * Makie.alpha(pp[:color])), length(pp[:pts])) for pp in active); init=RGBAf[]),
            reduce(vcat, (fill(pp[:lw], length(pp[:pts])) for pp in active); init=Float32[]))

        inj_txt.text[] = _inject_label(s.inject_value)
        out_txt.text[] = is_unk ? "PATH UNKNOWN" :
                         (out_to_frac ? "TO FRAC #$(s.fraction_number)" : "TO WASTE")
    end
end
