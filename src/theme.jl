# theme.jl — colours, typography and small building blocks (cards, chips) for
# the GUI. Every colour the GUI uses comes from the active palette, so light and
# dark mode differ only here. Exported PDFs always use the light palette.

const LIGHT = (
    bg=RGBf(0.96, 0.965, 0.975),     # page background
    panel=RGBf(1, 1, 1),             # cards, plot areas, controls
    border=RGBf(0.86, 0.875, 0.895),
    faint=RGBf(0.80, 0.82, 0.85),    # idle pipes, inactive tracks
    text=RGBf(0.12, 0.14, 0.17),
    muted=RGBf(0.44, 0.47, 0.52),
    accent=RGBf(0.15, 0.42, 0.86),
    accent_soft=RGBf(0.87, 0.92, 0.99),
    ok=RGBf(0.12, 0.58, 0.32),       # connected, live
    warn=RGBf(0.86, 0.55, 0.08),     # waiting, viewing the past
    err=RGBf(0.80, 0.20, 0.18),      # port missing, unknown valve state
    demo=RGBf(0.38, 0.40, 0.88),
    rec=RGBf(0.86, 0.15, 0.15),
    # measured traces
    uv=RGBf(0.15, 0.35, 0.70), pctb=RGBf(0.10, 0.55, 0.25), cond=RGBf(0.80, 0.20, 0.10),
    ph=RGBf(0.55, 0.25, 0.65), pres=RGBf(0.75, 0.45, 0.00), flow=RGBf(0.10, 0.45, 0.55),
    # flow path
    buf_a=RGBf(0.85, 0.27, 0.27), buf_port=RGBf(0.95, 0.58, 0.25), sample=RGBf(0.68, 0.38, 0.82),
    buf_b=RGBf(0.93, 0.78, 0.15), pipe=RGBf(0.20, 0.50, 0.85), frac=RGBf(0.20, 0.65, 0.40),
    node=RGBf(0.95, 0.96, 0.97), node_text=RGBf(0.20, 0.22, 0.26),
)

const DARK = (
    bg=RGBf(0.085, 0.095, 0.115),
    panel=RGBf(0.135, 0.148, 0.175),
    border=RGBf(0.23, 0.25, 0.29),
    faint=RGBf(0.28, 0.30, 0.34),
    text=RGBf(0.90, 0.91, 0.93),
    muted=RGBf(0.60, 0.63, 0.68),
    accent=RGBf(0.42, 0.63, 1.0),
    accent_soft=RGBf(0.19, 0.25, 0.38),
    ok=RGBf(0.30, 0.76, 0.46),
    warn=RGBf(0.95, 0.68, 0.25),
    err=RGBf(0.95, 0.38, 0.35),
    demo=RGBf(0.55, 0.57, 1.0),
    rec=RGBf(0.97, 0.30, 0.30),
    uv=RGBf(0.40, 0.62, 1.0), pctb=RGBf(0.35, 0.80, 0.45), cond=RGBf(0.98, 0.45, 0.35),
    ph=RGBf(0.78, 0.55, 0.95), pres=RGBf(0.98, 0.70, 0.25), flow=RGBf(0.30, 0.78, 0.85),
    buf_a=RGBf(0.92, 0.38, 0.38), buf_port=RGBf(0.98, 0.65, 0.30), sample=RGBf(0.78, 0.52, 0.95),
    buf_b=RGBf(0.95, 0.82, 0.30), pipe=RGBf(0.42, 0.63, 1.0), frac=RGBf(0.35, 0.80, 0.50),
    node=RGBf(0.19, 0.205, 0.24), node_text=RGBf(0.88, 0.89, 0.91),
)

const UI_PALETTE = Ref{typeof(LIGHT)}(LIGHT)
ui() = UI_PALETTE[]

# Type scale: one body size, one small size, headings and big readings.
const FS_SMALL = 11
const FS_BODY = 13
const FS_TITLE = 12      # card titles (small caps style: muted, bold)
const FS_READING = 22

function makie_theme(p=ui())
    Theme(
        backgroundcolor=p.bg,
        textcolor=p.text,
        fontsize=FS_BODY,
        Axis=(backgroundcolor=p.panel, topspinevisible=false, rightspinevisible=false,
            leftspinecolor=p.border, bottomspinecolor=p.border,
            xtickcolor=p.border, ytickcolor=p.border,
            xticklabelcolor=p.muted, yticklabelcolor=p.muted,
            xticklabelsize=FS_SMALL, yticklabelsize=FS_SMALL,
            xlabelcolor=p.muted, ylabelcolor=p.muted, xlabelsize=FS_BODY, ylabelsize=FS_BODY,
            xgridvisible=false, ygridvisible=false),
        Label=(color=p.text,),
        Button=(buttoncolor=p.panel, buttoncolor_hover=p.accent_soft, buttoncolor_active=p.accent_soft,
            labelcolor=p.text, labelcolor_hover=p.text, labelcolor_active=p.text,
            strokecolor=p.border, strokewidth=1, cornerradius=6, fontsize=FS_BODY,
            padding=(10, 10, 5, 5)),
        Menu=(cell_color_inactive_even=p.panel, cell_color_inactive_odd=p.panel,
            cell_color_hover=p.accent_soft, cell_color_active=p.accent_soft,
            selection_cell_color_inactive=p.panel, textcolor=p.text,
            dropdown_arrow_color=p.muted, fontsize=FS_BODY),
        Checkbox=(checkboxcolor_checked=p.accent, checkboxstrokecolor_checked=p.accent,
            checkboxcolor_unchecked=p.panel, checkboxstrokecolor_unchecked=p.border),
        Slider=(color_active=p.accent, color_active_dimmed=p.accent, color_inactive=p.faint),
        Toggle=(framecolor_active=p.accent, framecolor_inactive=p.faint, buttoncolor=p.panel),
        Textbox=(boxcolor=p.panel, boxcolor_hover=p.panel, boxcolor_focused=p.panel,
            bordercolor=p.border, bordercolor_hover=p.accent, bordercolor_focused=p.accent,
            textcolor=p.text, cursorcolor=p.accent, cornerradius=6, fontsize=FS_BODY),
        Box=(color=p.panel, strokecolor=p.border, cornerradius=8),
    )
end

# Select the palette and make it the default for every figure built afterwards.
function apply_theme!(dark::Bool)
    UI_PALETTE[] = dark ? DARK : LIGHT
    set_theme!(makie_theme())
end

# A card: rounded panel with a muted title; returns the grid for its content.
function card!(pos, title::AbstractString)
    p = ui()
    Box(pos; color=p.panel, strokecolor=p.border, cornerradius=8)
    g = GridLayout(pos; alignmode=Outside(12), tellwidth=false, valign=:top)
    Label(g[1, 1:2], uppercase(title); halign=:left, fontsize=FS_TITLE, font=:bold,
        color=p.muted)
    return GridLayout(g[2, 1:2]; halign=:left, tellwidth=false)
end

# A chip: small rounded badge whose text and colour may be Observables.
function chip!(pos, text, color; textcolor=RGBf(1, 1, 1))
    Box(pos; color=color, strokevisible=false, cornerradius=9)
    Label(pos, text; color=textcolor, fontsize=FS_SMALL, font=:bold,
        padding=(8, 8, 3, 3), halign=:center)
end

# Colour of a connection status text (see run_linklayer / start!).
function status_color(txt::AbstractString)
    p = ui()
    startswith(txt, "Demo") ? p.demo :
    startswith(txt, "●") ? p.ok :
    occursin("not available", txt) || startswith(txt, "Stopped") ? p.err : p.warn
end
