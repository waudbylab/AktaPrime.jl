# method.jl
#
# Decoder for the method dump the ÄKTAprime sends just before a run starts
# (OPC 0x2007, content in 0x8008–0x8011, closed by 0x2008). The dump is a
# printer-formatted text report, escaped like all method text (methodstore.jl);
# decoded it reads
#   ** Method Settings
#   Method base        ,ml
#   Brkp Volume   Conc Flow  Frac   Buff Inj    Peak   Autozero Eventmark
#   ,1   ,0.0     ,0   ,0.5  ,0.0   ,8   ,Load  ,0     ,N       ,N
# It holds a "Method Settings" block of `name ,value` lines and a breakpoint
# table with the columns Brkp, Volume (mL), Conc (%B), Flow (mL/min), Frac (mL),
# Buff (buffer valve port), Inj (injection valve), Peak (mAU/min), Autozero and
# Eventmark. The first breakpoint (volume 0) is the state the run starts in.

struct MethodDump
    settings::Vector{Pair{String,String}}
    columns::Vector{String}
    breakpoints::Vector{Dict{String,String}}
end

# A method dump as the Akta sends it (escaped).
parse_method_dump(raw::AbstractVector{UInt8})::MethodDump = parse_method_text(unescape_method_text(raw))

# Method text as stored in a PrimeMeth_NNN.txt file.
function parse_method_text(bytes::AbstractVector{UInt8})::MethodDump
    settings = Pair{String,String}[]
    columns = String[]
    breakpoints = Dict{String,String}[]
    for line in split(String(copy(bytes)), r"\r\n|\r|\n")
        line = rstrip(line)
        (isempty(strip(line)) || startswith(line, '*')) && continue   # rules and headings
        if startswith(line, "Brkp")
            columns = split(line)
        elseif startswith(line, ',')
            # Each value is prefixed by ','; padding before it is optional ("99999.9 ,0").
            values = strip.(split(line, ',')[2:end])
            length(values) == length(columns) && push!(breakpoints, Dict(zip(columns, values)))
        elseif occursin(',', line)
            name, value = split(line, ','; limit=2)
            push!(settings, strip(name) => strip(value))
        end
    end
    return MethodDump(settings, columns, breakpoints)
end

# Event text for the start of a run, recorded once the new run's log is open.
const PENDING_METHOD_EVENT = Ref{Union{Nothing,String}}(nothing)

# Take the run's starting state from the first breakpoint.
function apply_method_dump!(app::AppState, m::MethodDump)
    @info "Method settings: " * join(("$k = $v" for (k, v) in m.settings), "; ")
    isempty(m.breakpoints) && (@warn "Method dump without breakpoints"; return)
    bp = m.breakpoints[1]
    inst = app.inst[]

    port = tryparse(Int, get(bp, "Buff", ""))
    if !isnothing(port) && 1 <= port <= 8
        inst.buffer_port = port
        inst.buffer_port_known = true
    end
    inj = lowercase(get(bp, "Inj", ""))
    inst.inject_value = inj == "load" ? IV_LOAD : inj == "inj" ? IV_INJECT :
                        inj == "waste" ? IV_WASTE : inst.inject_value
    notify(app.inst)

    txt = "Method start: flow $(get(bp, "Flow", "?")) ml/min, $(get(bp, "Conc", "?")) %B, " *
          "buffer port $(get(bp, "Buff", "?")), inject $(get(bp, "Inj", "?")), " *
          "fraction $(get(bp, "Frac", "?")) ml, $(length(m.breakpoints)) breakpoints"
    @info txt
    PENDING_METHOD_EVENT[] = txt
end

# ─────────────────────────────────────────────────────────────────────────────
# Stored method files — the model behind the method editor
# ─────────────────────────────────────────────────────────────────────────────
# A PrimeMeth_NNN.txt file is the decoded method dump: a fixed header, the
# settings (name padded to 19 characters, ',' value) and the breakpoint table,
# each field ',' + value padded to its column width. The instrument loads it only
# with at least two breakpoints: the last one is the end of the method
# (99999.9 = run until stopped). `format_method_text` writes exactly what the
# instrument writes (header, padding, CRLF), checked against its own files.

const BP_COLUMNS = ["Volume", "Conc", "Flow", "Frac", "Buff", "Inj", "Peak", "Autozero", "Eventmark"]
const _BP_WIDTHS = [4, 8, 4, 5, 6, 4, 6, 6, 8]     # Brkp, then BP_COLUMNS but the last (unpadded)
const METHOD_END_VOLUME = "99999.9"
const INJ_OPTIONS = ["Load", "Inj", "Waste"]
const BASE_OPTIONS = ["ml", "min"]
const YN_OPTIONS = ["N", "Y"]

const _METHOD_HEAD = ["*"^65, "** Method Dump", "**", rpad("** AKTAprime   Ver  , V2.01", 42), "**",
    rpad("** Dump Format Ver  , V1.00", 42), "**", "*"^65, "", "", "*"^18, "** Method Settings", "*"^18]
const _METHOD_TABLE_HEAD = ["", "*"^21, "** Method Breakpoints", "*"^21, " "^21,
    "Brkp Volume   Conc Flow  Frac   Buff Inj    Peak   Autozero Eventmark", " "^42 * "(mAu/min)", ""]

mutable struct MethodFile
    settings::Vector{Pair{String,String}}   # in file order; values as written (no padding)
    rows::Vector{Vector{String}}            # breakpoints, values in BP_COLUMNS order
end
Base.:(==)(a::MethodFile, b::MethodFile) = a.settings == b.settings && a.rows == b.rows
Base.copy(m::MethodFile) = MethodFile(copy(m.settings), [copy(r) for r in m.rows])

setting(m::MethodFile, name) = (i = findfirst(p -> p.first == name, m.settings); isnothing(i) ? "" : m.settings[i].second)
function set_setting!(m::MethodFile, name, value)
    i = findfirst(p -> p.first == name, m.settings)
    isnothing(i) ? push!(m.settings, name => value) : (m.settings[i] = name => value)
end

# A new method: like one programmed on the instrument ("-"), start and open end.
function new_method_file()
    row = ["0.0", "0", "1.0", "0.0", "1", "Load", "0", "N", "N"]
    MethodFile(["Method Type" => "-", "Method" => "-", "Method base" => "ml", "Frac base" => "ml",
            "Max pressure (kPa)" => "500", "Alarm (min/ml)" => "0.0"],
        [row, [METHOD_END_VOLUME; row[2:end]]])
end

function read_method_file(bytes::AbstractVector{UInt8})::MethodFile
    m = MethodFile(Pair{String,String}[], Vector{String}[])
    section = :head
    for line in split(String(copy(bytes)), r"\r\n|\r|\n")
        if line == "** Method Settings"
            section = :settings
        elseif line == "** Method Breakpoints"
            section = :table
        elseif startswith(line, "Brkp")
            split(line) == ["Brkp"; BP_COLUMNS] || error("unknown breakpoint columns: $line")
        elseif section == :settings && occursin(',', line) && !startswith(line, '*')
            name, value = split(line, ','; limit=2)
            push!(m.settings, String(strip(name)) => String(value))
        elseif section == :table && startswith(line, ',')
            values = String.(strip.(split(line, ',')[3:end]))   # [1] is "", [2] the Brkp number
            length(values) == length(BP_COLUMNS) || error("breakpoint with $(length(values)) values: $line")
            push!(m.rows, values)
        end
    end
    section == :table || error("not a method file")
    return m
end

function format_method_text(m::MethodFile)::Vector{UInt8}
    lines = copy(_METHOD_HEAD)
    append!(lines, [rpad(k, 19) * "," * v for (k, v) in m.settings])
    append!(lines, _METHOD_TABLE_HEAD)
    for (i, row) in enumerate(m.rows)
        vals = [string(i); row]
        push!(lines, join("," * rpad(v, max(w, length(v) + 1)) for (v, w) in zip(vals, _BP_WIDTHS)) *
                     "," * vals[end])
    end
    return Vector{UInt8}(join(lines, "\r\n") * "\r\n")
end

# What each value may be. The number limits are generous where the instrument's
# own are not known; Method base/Frac base "min" and Inj "Inj" are not yet seen in
# a method from the instrument.
const _VALUE_RULES = Dict{String,Tuple{Regex,Float64,Float64}}(
    "Volume" => (r"^\d{1,5}(\.\d)?$", 0, 99999.9),
    "Conc" => (r"^\d{1,3}$", 0, 100),
    "Flow" => (r"^\d{1,2}(\.\d)?$", 0, 50),
    "Frac" => (r"^\d{1,3}(\.\d)?$", 0, 100),
    "Buff" => (r"^[1-8]$", 1, 8),
    "Peak" => (r"^\d{1,3}(\.\d{1,2})?$", 0, 999.99),
    "Max pressure (kPa)" => (r"^\d{1,4}$", 1, 1000),
    "Alarm (min/ml)" => (r"^\d{1,3}(\.\d)?$", 0, 999.9))
const VALUE_CHOICES = Dict("Inj" => INJ_OPTIONS, "Autozero" => YN_OPTIONS, "Eventmark" => YN_OPTIONS,
    "Method base" => BASE_OPTIONS, "Frac base" => BASE_OPTIONS)
const _ONE_DECIMAL = ("Volume", "Flow", "Frac", "Alarm (min/ml)")

_number_text(s) = replace(strip(s), ',' => '.')    # a decimal comma is accepted while typing

function method_value_ok(name::AbstractString, s::AbstractString)::Bool
    haskey(VALUE_CHOICES, name) && return strip(s) in VALUE_CHOICES[name]
    if haskey(_VALUE_RULES, name)
        re, lo, hi = _VALUE_RULES[name]
        t = _number_text(s)
        return occursin(re, t) && lo <= parse(Float64, t) <= hi
    end
    # free text (Method Type, Method): printable ASCII without the field separator
    return !isempty(strip(s)) && length(s) <= 60 && all(c -> ' ' <= c <= '~' && c != ',', s)
end

# The value as the instrument writes it: 0.5 → "0.5", 1 → "1.0", %B 05 → "5", peak 0.10 → "0.1".
function normalize_value(name::AbstractString, s::AbstractString)::String
    haskey(_VALUE_RULES, name) || return String(name in keys(VALUE_CHOICES) ? strip(s) : s)
    v = parse(Float64, _number_text(s))
    name in _ONE_DECIMAL && return @sprintf("%.1f", v)
    name == "Peak" && return isinteger(v) ? string(Int(v)) : rstrip(@sprintf("%.2f", v), '0')
    return string(round(Int, v))
end

normalize_method(m::MethodFile) = MethodFile([k => normalize_value(k, v) for (k, v) in m.settings],
    [[normalize_value(c, v) for (c, v) in zip(BP_COLUMNS, row)] for row in m.rows])

# Everything that would stop the instrument from loading the method: messages,
# and the bad values as (row, column name), row 0 for the settings.
function method_problems(m::MethodFile)
    msgs = String[]
    bad = Set{Tuple{Int,String}}()
    for (k, v) in m.settings
        method_value_ok(k, v) || (push!(bad, (0, k)); push!(msgs, "$k: \"$v\" is not a valid value"))
    end
    for (i, row) in enumerate(m.rows), (c, v) in zip(BP_COLUMNS, row)
        method_value_ok(c, v) || (push!(bad, (i, c)); push!(msgs, "Breakpoint $i, $c: \"$v\" is not a valid value"))
    end
    length(m.rows) < 2 &&
        push!(msgs, "At least two breakpoints are needed: the Akta cannot load a method without its end breakpoint")
    vols = [method_value_ok("Volume", r[1]) ? parse(Float64, _number_text(r[1])) : NaN for r in m.rows]
    if !isempty(vols) && !isnan(vols[1]) && vols[1] != 0
        push!(bad, (1, "Volume")); push!(msgs, "The first breakpoint must be at 0.0")
    end
    for i in 2:length(vols)
        if vols[i] <= vols[i-1]           # false for NaN, already reported
            push!(bad, (i, "Volume")); push!(msgs, "Breakpoint $i must come after breakpoint $(i-1)")
        end
    end
    return msgs, bad
end
