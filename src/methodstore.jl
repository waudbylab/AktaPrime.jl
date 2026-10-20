# methodstore.jl
#
# The PC method store: the ÄKTAprime saves methods to the PC and loads them back
# ("Run Stored Method → PC"), with the PC acting as a numbered file store. This
# reproduces what the original driver (UNICORN 5 / PrimeView, Bin/p232_drv.exe)
# does, so its method files and ours are interchangeable: one text file per method,
# <methods folder>/PrimeMeth_NNN.txt (NNN = 001–999), CRLF line endings.
#
# Instrument → PC                            PC → instrument
#   0x2007                 dump begin          –   (method report before a run)
#   0x2008 [x]             dump end            –
#   0x2009 [u16 n]         save begin          –
#   0x8008–0x8011          method text         –   (during a dump or save)
#   0x2010                 save end            0x2011 [1 saved / 0 not saved]
#   0x2015 [u16 n, u8 up]  list methods        0x2016 [10 × u16 numbers, 0xFFFF = none]
#   0x2019 [u16 n]         does n exist?       0x2020 [1 / 0]
#   0x2017 [u16 n]         delete n            0x2018 [1 deleted / 0 not]
#   0x2012 [u16 n]         load n              0x2013, the file's lines, 0x2014 [0 ok / 2 error]
#                                              or just 0x2014 [1] if there is no such file
# Numbers are little-endian. Method text travels in ASCII messages: 0x8008 is a
# whole line; a line longer than 34 characters goes as 0x8009, 0x8010…, 0x8011.
#
# Text escaping (both directions; '#' starts a link-layer frame):
#   zy → '#'    z<c> → c (for c in z { | } ~)    ~ → CR    } → CR LF
#   |<n> → n spaces    {<n> → n '*'    (n = count + '0', runs of 2–60)

const METHOD_FILE_PREFIX = "PrimeMeth_"
const METHOD_NUMBERS = 1:999
const METHOD_LIST_LENGTH = 10      # numbers per 0x2016 reply
const METHOD_CHUNK = 34            # characters per method text message
const METHOD_LINE_MAX = 99         # longer lines make the original driver abort a load
const METHOD_NONE = 0xffff         # empty slot in a 0x2016 reply

# The methods folder, set when acquisition starts (link thread reads it).
const METHOD_DIR = Ref("")
# Bumped (on the main thread) when the Akta saved, deleted or loaded a method or
# the folder changed, so the Methods tab can update its list.
const METHODS_CHANGED = Observable(0)
const LAST_LOADED_METHOD = Ref(0)        # the method the Akta last loaded from the PC
method_dir(data_folder::AbstractString) = joinpath(data_folder, "methods")
method_path(dir::AbstractString, n::Integer) = joinpath(dir, @sprintf("%s%03d.txt", METHOD_FILE_PREFIX, n))

const _METHOD_FILE_RE = r"^primemeth_(\d{3})\.txt$"i

# Numbers of the methods in `dir`, ascending.
function stored_methods(dir::AbstractString)::Vector{Int}
    isdir(dir) || return Int[]
    nums = Int[]
    for f in readdir(dir)
        m = match(_METHOD_FILE_RE, f)
        isnothing(m) && continue
        n = parse(Int, m[1])
        n in METHOD_NUMBERS && isfile(joinpath(dir, f)) && push!(nums, n)
    end
    return sort!(unique!(nums))
end

# The file of method n, matched case-insensitively (UNICORN runs on Windows).
function find_method_file(dir::AbstractString, n::Integer)::Union{Nothing,String}
    path = method_path(dir, n)
    isfile(path) && return path
    isdir(dir) || return nothing
    for f in readdir(dir)
        lowercase(f) == lowercase(basename(path)) && return joinpath(dir, f)
    end
    return nothing
end

# ── Method names ──────────────────────────────────────────────────────────────
# Names given in the method editor stay on the PC: <methods folder>/names.txt,
# one "NNN<tab>name" line per method. The instrument never sees them.

const METHOD_NAMES_FILE = "names.txt"

function method_names(dir::AbstractString)::Dict{Int,String}
    names = Dict{Int,String}()
    path = joinpath(dir, METHOD_NAMES_FILE)
    isfile(path) || return names
    for line in eachline(path)
        m = match(r"^(\d{1,3})\t(.+)$", line)
        isnothing(m) || (names[parse(Int, m[1])] = m[2])
    end
    return names
end

method_name_ok(s::AbstractString) = length(s) <= 60 && all(c -> isprint(c) && c != '\t', s)

# Sets (or with "" removes) the name of method n.
function set_method_name!(dir::AbstractString, n::Integer, name::AbstractString)
    names = method_names(dir)
    name = strip(name)
    get(names, n, "") == name && return
    isempty(name) ? delete!(names, n) : (names[n] = name)
    mkpath(dir)
    tmp, io = mktemp(dir)
    println(io, "# Method names from the AktaPrime method editor; not sent to the instrument.")
    foreach(k -> println(io, @sprintf("%03d", k), '\t', names[k]), sort!(collect(keys(names))))
    close(io)
    chmod(tmp, 0o644)
    mv(tmp, joinpath(dir, METHOD_NAMES_FILE); force=true)
end

# ── Text codec ────────────────────────────────────────────────────────────────

function escape_method_text(s::AbstractVector{UInt8})::Vector{UInt8}
    out = UInt8[]
    i = 1
    n = length(s)
    while i <= n
        c = s[i]
        if c == UInt8('#')
            append!(out, b"zy")
        elseif 0x7a <= c <= 0x7e
            push!(out, 0x7a, c)
        elseif c == 0x0d
            push!(out, UInt8('~'))
        elseif c == 0x0a
            push!(out, UInt8('}'))
        elseif (c == UInt8(' ') || c == UInt8('*')) && i < n && s[i+1] == c
            run = 0
            while i <= n && s[i] == c && run < 60
                run += 1
                i += 1
            end
            push!(out, c == UInt8(' ') ? UInt8('|') : UInt8('{'), UInt8(0x30 + run))
            continue
        else
            push!(out, c)
        end
        i += 1
    end
    return out
end

function unescape_method_text(s::AbstractVector{UInt8})::Vector{UInt8}
    out = UInt8[]
    i = 1
    n = length(s)
    while i <= n
        c = s[i]
        if c == UInt8('~')
            push!(out, 0x0d)
        elseif c == UInt8('}')
            push!(out, 0x0d, 0x0a)
        elseif c == 0x7a && i < n
            i += 1
            push!(out, s[i] == UInt8('y') ? UInt8('#') : s[i])
        elseif (c == UInt8('|') || c == UInt8('{')) && i < n
            i += 1
            append!(out, fill(c == UInt8('|') ? UInt8(' ') : UInt8('*'), max(0, Int(s[i]) - 0x30)))
        else
            push!(out, c)
        end
        i += 1
    end
    return out
end

# The messages that carry one line (without its line end) to the instrument.
function method_line_messages(line::AbstractVector{UInt8})::Vector{Tuple{UInt16,Vector{UInt8}}}
    enc = escape_method_text(line)
    length(enc) <= METHOD_CHUNK && return [(OPC_METHOD_LINE, enc)]
    parts = collect(Iterators.partition(enc, METHOD_CHUNK))
    return [(i == 1 ? OPC_METHOD_LINE_BEGIN : i == length(parts) ? OPC_METHOD_LINE_END : OPC_METHOD_LINE_CONT,
        Vector{UInt8}(p)) for (i, p) in enumerate(parts)]
end

# The lines a load sends: split at CR or LF, empty lines dropped (as the driver does).
function method_file_lines(bytes::AbstractVector{UInt8})::Vector{Vector{UInt8}}
    lines = Vector{UInt8}[]
    cur = UInt8[]
    for b in bytes
        if b == 0x0d || b == 0x0a
            isempty(cur) || (push!(lines, cur); cur = UInt8[])
        else
            push!(cur, b)
        end
    end
    isempty(cur) || push!(lines, cur)
    return lines
end

# ── Requests ──────────────────────────────────────────────────────────────────

_u16(data, i=1) = Int(data[i]) | (Int(data[i+1]) << 8)
_u16_bytes(v::Integer) = UInt8[v & 0xff, (v >> 8) & 0xff]

# 0x2016 payload: the first ten stored methods from `start` (inclusive) up or down.
# Like the driver, a start outside 1–999 lists nothing.
function method_list_payload(nums::AbstractVector{<:Integer}, start::Integer, up::Bool)::Vector{UInt8}
    found = start in METHOD_NUMBERS ?
            (up ? sort(filter(>=(start), nums)) : sort(filter(<=(start), nums); rev=true)) : Int[]
    found = first(found, METHOD_LIST_LENGTH)
    padded = vcat(found, fill(METHOD_NONE, METHOD_LIST_LENGTH - length(found)))
    return reduce(vcat, _u16_bytes.(padded))
end

# Move a file the instrument is about to overwrite or delete to <dir>/old/,
# so nothing written in the method editor is ever lost.
function _retire_method_file(path::AbstractString)
    old = joinpath(dirname(path), "old")
    mkpath(old)
    stem = splitext(basename(path))[1]
    mv(path, joinpath(old, stem * "_" * Dates.format(now(), "yyyymmdd-HHMMSS") * ".txt"); force=true)
end

function save_method_file(dir::AbstractString, n::Integer, bytes::AbstractVector{UInt8})
    mkpath(dir)
    path = method_path(dir, n)
    tmp, io = mktemp(dir)      # unique: the editor and the Akta may save at the same moment
    write(io, bytes)
    close(io)
    chmod(tmp, 0o644)          # mktemp makes it private to the user
    existing = find_method_file(dir, n)
    isnothing(existing) || _retire_method_file(existing)
    mv(tmp, path; force=true)
    return path
end

# The messages answering a load request for method n.
function method_load_messages(dir::AbstractString, n::Integer)::Tuple{Vector{Tuple{UInt16,Vector{UInt8}}},String}
    path = find_method_file(dir, n)
    isnothing(path) && return ([(OPC_METHOD_LOAD_END, UInt8[0x01])], "Method $n requested, but there is no such file")
    msgs = Tuple{UInt16,Vector{UInt8}}[(OPC_METHOD_LOAD_BEGIN, UInt8[])]
    lines = method_file_lines(read(path))
    # The driver sends the lines before a bad one, then reports the error.
    for (i, line) in enumerate(lines)
        bad = length(line) > METHOD_LINE_MAX ? "line $i is longer than $METHOD_LINE_MAX characters" :
              any(b -> !(0x20 <= b <= 0x7e) && b != 0x09, line) ? "line $i has a non-ASCII character" : ""
        if !isempty(bad)
            push!(msgs, (OPC_METHOD_LOAD_END, UInt8[0x02]))
            return (msgs, "Method $n sent with an error: $bad ($(basename(path)))")
        end
        append!(msgs, method_line_messages(line))
    end
    push!(msgs, (OPC_METHOD_LOAD_END, UInt8[0x00]))
    return (msgs, "Method $n sent to the Akta ($(length(lines)) lines)")
end

# State of the method text transfer in progress (dump or save).
mutable struct MethodTransfer
    mode::Symbol             # :none, :dump or :save
    number::Int              # method number of a save
    buf::Vector{UInt8}       # text received so far, still escaped
end
MethodTransfer() = MethodTransfer(:none, 0, UInt8[])

# What a received method message calls for.
struct MethodAction
    replies::Vector{Tuple{UInt16,Vector{UInt8}}}   # messages to send to the instrument
    note::Union{Nothing,String}                    # for the run log
    dump::Union{Nothing,Vector{UInt8}}             # a finished method dump (escaped text)
end
MethodAction(replies=Tuple{UInt16,Vector{UInt8}}[]; note=nothing, dump=nothing) = MethodAction(replies, note, dump)

# A function, not a constant: the OPC codes are defined later, in protocol.jl.
is_method_opc(opc::UInt16) = opc in (OPC_METHOD_DUMP_BEGIN, OPC_METHOD_DUMP_END, OPC_METHOD_SAVE_BEGIN,
    OPC_METHOD_SAVE_END, OPC_METHOD_LINE, OPC_METHOD_LINE_BEGIN, OPC_METHOD_LINE_CONT, OPC_METHOD_LINE_END,
    OPC_METHOD_LOAD, OPC_METHOD_LIST, OPC_METHOD_DELETE, OPC_METHOD_EXISTS)

# Handle one message of the method protocol; `nothing` for any other message.
# Touches only the methods folder, so it can run on the link thread.
function handle_method_opc!(x::MethodTransfer, opc::UInt16, data::Vector{UInt8},
    dir::AbstractString)::Union{Nothing,MethodAction}
    is_method_opc(opc) || return nothing
    if opc == OPC_METHOD_DUMP_BEGIN
        x.mode, x.buf = :dump, UInt8[]
        return MethodAction()

    elseif opc == OPC_METHOD_DUMP_END
        x.mode == :dump || return MethodAction()
        dump, x.mode, x.buf = x.buf, :none, UInt8[]
        return MethodAction(; dump)

    elseif opc == OPC_METHOD_SAVE_BEGIN
        if length(data) == 2
            x.mode, x.number, x.buf = :save, _u16(data), UInt8[]
        else
            x.mode, x.buf = :none, UInt8[]
            @warn "Method save request with $(length(data)) bytes ignored"
        end
        return MethodAction()

    elseif opc in (OPC_METHOD_LINE, OPC_METHOD_LINE_BEGIN, OPC_METHOD_LINE_CONT, OPC_METHOD_LINE_END)
        x.mode == :none && (@debug "Method text outside a transfer ignored"; return MethodAction())
        append!(x.buf, data)
        return MethodAction()

    elseif opc == OPC_METHOD_SAVE_END
        x.mode == :save || return MethodAction([(OPC_METHOD_SAVE_ACK, UInt8[0x00])];
            note="Akta finished a method save that never started — not saved")
        n, text = x.number, unescape_method_text(x.buf)
        x.mode, x.buf = :none, UInt8[]
        try
            n in METHOD_NUMBERS || error("method number $n is outside 1–999")
            path = save_method_file(dir, n, text)
            note = "Method $n saved by the Akta to $path"
            # The Akta saves a method with a single breakpoint but cannot load it back
            # ("Reading Error on PC"): it needs a last breakpoint marking the end.
            if length(parse_method_text(text).breakpoints) < 2
                note *= " — it has only one breakpoint, so the Akta cannot load it back; add an end breakpoint"
                @warn note
            end
            return MethodAction([(OPC_METHOD_SAVE_ACK, UInt8[0x01])]; note)
        catch err
            @error "Could not save method $n" exception = err
            return MethodAction([(OPC_METHOD_SAVE_ACK, UInt8[0x00])]; note="Method $n from the Akta could not be saved")
        end
    end

    # Requests: each carries at least a method number.
    length(data) < 2 && (@warn "Method request 0x$(string(opc, base=16)) with $(length(data)) bytes ignored";
        return MethodAction())
    n = _u16(data)
    if opc == OPC_METHOD_LIST
        up = length(data) < 3 || data[3] != 0
        payload = method_list_payload(stored_methods(dir), n, up)
        listed = filter(!=(METHOD_NONE), [_u16(payload, i) for i in 1:2:length(payload)])
        @info "Akta asks for methods from $n $(up ? "up" : "down"): $(isempty(listed) ? "none" : join(listed, ", "))"
        return MethodAction([(OPC_METHOD_LIST_REPLY, payload)])

    elseif opc == OPC_METHOD_EXISTS
        exists = !isnothing(find_method_file(dir, n))
        @info "Akta asks whether method $n exists: $(exists ? "yes" : "no")"
        return MethodAction([(OPC_METHOD_EXISTS_REPLY, UInt8[exists])])

    elseif opc == OPC_METHOD_DELETE
        path = find_method_file(dir, n)
        ok = false
        if !isnothing(path)
            try
                _retire_method_file(path)
                ok = true
            catch err
                @error "Could not delete method $n" exception = err
            end
        end
        return MethodAction([(OPC_METHOD_DELETE_REPLY, UInt8[ok])];
            note=ok ? "Method $n deleted by the Akta (moved to $(joinpath(dir, "old")))" :
                 "Akta asked to delete method $n — not deleted")

    else  # OPC_METHOD_LOAD
        try
            msgs, note = method_load_messages(dir, n)
            return MethodAction(msgs; note)
        catch err
            @error "Could not read method $n" exception = err
            return MethodAction([(OPC_METHOD_LOAD_END, UInt8[0x01])]; note="Method $n could not be read")
        end
    end
end
