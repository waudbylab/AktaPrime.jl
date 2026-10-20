# methodeditor.jl — the Methods tab: the methods stored on the PC for the
# instrument (methodstore.jl) and an editor for them. Files are read, checked
# and written with the model in method.jl, which writes exactly what the
# instrument writes, so a method saved here loads on the Akta like its own.

const EDITOR_ROWS = 12      # breakpoints shown at once
const LIST_ROWS = 18        # methods shown at once in the list

const _COL_HEADS = Dict("Volume" => "Volume", "Conc" => "%B", "Flow" => "Flow", "Frac" => "Fraction",
    "Buff" => "Buffer", "Inj" => "Inj. valve", "Peak" => "Peak", "Autozero" => "Autozero",
    "Eventmark" => "Event mark")
const _COL_WIDTH = Dict("Volume" => 84, "Conc" => 52, "Flow" => 64, "Frac" => 64, "Buff" => 52,
    "Inj" => 76, "Peak" => 64, "Autozero" => 76, "Eventmark" => 76)

function _col_head(col::AbstractString, m::MethodFile)
    col == "Volume" && setting(m, "Method base") == "min" && return "Time (min)"
    unit = col == "Volume" ? "ml" : col == "Flow" ? "ml/min" : col == "Frac" ? setting(m, "Frac base") :
           col == "Peak" ? "mAU/min" : ""
    return isempty(unit) ? _COL_HEADS[col] : "$(_COL_HEADS[col]) ($unit)"
end

function _first_free(dir::AbstractString)::Int
    used = Set(stored_methods(dir))
    for n in METHOD_NUMBERS
        n in used || return n
    end
    return 0
end

# Short description of a stored method for the list, and whether the Akta can load it.
function _method_summary(dir::AbstractString, n::Integer)
    try
        m = read_method_file(read(find_method_file(dir, n)))
        typ = strip(setting(m, "Method Type"))
        nbp = length(m.rows) == 1 ? "1 breakpoint" : "$(length(m.rows)) breakpoints"
        return (typ in ("", "-") ? nbp : typ, isempty(first(method_problems(m))))
    catch
        return ("not a method file", false)
    end
end

_shorten(s::AbstractString, n::Int) = length(s) <= n ? s : first(s, n - 1) * "…"

mutable struct MethodEditing
    number::Int
    on_disk::Bool          # `number` exists as a file with the content `saved`
    file::MethodFile       # what is being edited
    saved::MethodFile      # as last read or written
    name::String           # name in the editor (kept on the PC only, see method_names)
    saved_name::String
    offset::Int            # breakpoints before the first one shown
    list_offset::Int
    pending::String        # an action that waits for a confirming second click
end

# Unsaved work: edits to a stored method, or a new method that differs from the template.
_dirty(ed::MethodEditing) = strip(ed.name) != ed.saved_name ||
                            (ed.on_disk ? ed.file != ed.saved : ed.file != new_method_file())

function open_methods!(ws::Workspace)
    existing = findfirst(p -> p.title == "Methods", ws.pages)
    isnothing(existing) || return show_page!(ws, ws.pages[existing])
    listener = Ref{Any}(nothing)
    page = add_page!((topbar, on_screen) -> _methods_figure(ws, topbar, on_screen, listener), ws, "Methods";
        closable=!ws.editor_only)
    isnothing(listener[]) || push!(page.listeners, listener[])   # released when the tab closes
    show_page!(ws, page)
    return page
end

function _methods_figure(ws::Workspace, topbar, on_screen::Observable{Bool}, listener::Ref)::Figure
    p = ui()
    fig = Figure(size=(1440, 900))
    fig.layout.block_updates = true     # one layout solve once the page is built
    topbar(fig[1, 1])
    g = GridLayout(fig[2, 1]; halign=:left, valign=:top, tellwidth=false, tellheight=false,
        alignmode=Outside(30))
    dir() = METHOD_DIR[]

    # ── Left: the stored methods ──────────────────────────────────────────────
    left = GridLayout(g[1, 1]; valign=:top, halign=:left)
    Label(left[1, 1:3], "Methods on the PC"; halign=:left, fontsize=20, font=:bold)
    folder = Label(left[2, 1:3], ""; halign=:left, fontsize=FS_SMALL, color=p.muted)
    lgrid = GridLayout(left[3, 1:3]; halign=:left, valign=:top, default_rowgap=2)
    # A pager keeps its label, also when empty: an empty layout row would take up all spare height.
    lpager = GridLayout(left[4, 1:3]; halign=:left)
    lpage_info = Label(lpager[1, 1], ""; color=p.muted)
    new_btn = Button(left[5, 1]; label="New")
    dup_btn = Button(left[5, 2]; label="Duplicate")
    del_btn = Button(left[5, 3]; label="Delete")
    rowgap!(left, 10)

    # ── Right: the method being edited ────────────────────────────────────────
    right = GridLayout(g[1, 2]; valign=:top, halign=:left)
    title = Label(right[1, 1], ""; halign=:left, fontsize=20, font=:bold)
    state = Label(right[1, 2], ""; halign=:left, fontsize=FS_BODY, color=p.muted)
    bar = GridLayout(right[2, 1:2]; halign=:left, default_colgap=8)
    save_btn = Button(bar[1, 1]; label="Save")
    Label(bar[1, 2], "Save as number"; fontsize=FS_BODY, padding=(16, 0, 0, 0))
    as_box = Textbox(bar[1, 3]; placeholder="1–999", width=70, fontsize=FS_BODY,
        validator=s -> occursin(r"^\d{1,3}$", strip(s)) && parse(Int, strip(s)) in METHOD_NUMBERS)
    as_btn = Button(bar[1, 4]; label="Save as")
    revert_btn = Button(bar[1, 5]; label="Revert")
    sgrid = GridLayout(right[3, 1:2]; halign=:left, default_colgap=10, default_rowgap=8)
    Label(right[4, 1:2], "Breakpoints"; halign=:left, fontsize=15, font=:bold)
    rgrid = GridLayout(right[5, 1:2]; halign=:left, default_colgap=6, default_rowgap=4)
    rpager = GridLayout(right[6, 1:2]; halign=:left)
    rpage_info = Label(rpager[1, 1], ""; color=p.muted)
    check = Label(right[7, 1:2], ""; halign=:left, justification=:left, fontsize=FS_BODY)
    Label(right[8, 1:2], "The last breakpoint is the end of the method (99999.9 = run until stopped). " *
                         "To run a method: Save, then on the Akta choose Run Stored Method, PC and its number.";
        halign=:left, fontsize=FS_SMALL + 1, color=p.muted)
    notice = Label(right[9, 1:2], ""; halign=:left, fontsize=FS_BODY, color=p.ok)
    rowgap!(right, 12)
    colgap!(g, 50)

    nums = stored_methods(dir())
    ed = MethodEditing(0, false, new_method_file(), new_method_file(), "", "", 0, 0, "")
    list_items, lpager_items, setting_items, row_items, rpager_items = (Any[] for _ in 1:5)
    boxes = Dict{Tuple{Int,String},Textbox}()   # (breakpoint, column) → box; breakpoint 0 = settings

    say(msg; err=false) = (notice.text = msg; notice.color = err ? p.err : p.ok)
    # A risky action runs on the second click; the first one explains it.
    confirm(key, msg) = ed.pending == key ? (ed.pending = ""; true) : (ed.pending = key; say(msg; err=true); false)
    clear!(items, grid) = (foreach(delete!, items); empty!(items); trim!(grid))

    # Checks the method after every edit: red borders on bad values, problems listed.
    function changed!()
        msgs, bad = method_problems(ed.file)
        for ((i, name), tb) in boxes
            tb.bordercolor = (i, name) in bad ? p.err : p.border
        end
        check.text = isempty(msgs) ? "No problems found: the Akta can load this method." :
                     join(first(msgs, 4), "\n") * (length(msgs) > 4 ? "\n… and $(length(msgs) - 4) more" : "")
        check.color = isempty(msgs) ? p.ok : p.err
        title.text = @sprintf("Method %03d", ed.number)
        state.text = !ed.on_disk ? "new, not saved yet" : _dirty(ed) ? "unsaved changes" : "saved"
        state.color = ed.on_disk && !_dirty(ed) ? p.muted : p.warn
    end

    function render_list!()
        clear!(list_items, lgrid)
        clear!(lpager_items, lpager)
        folder.text = "Folder: " * (length(dir()) > 40 ? "…" * last(dir(), 39) : dir())
        stored = stored_methods(dir())
        all = sort(unique(ed.on_disk ? stored : [stored; ed.number]))
        ed.list_offset = clamp(ed.list_offset, 0, max(0, length(all) - LIST_ROWS))
        shown = all[ed.list_offset+1:min(end, ed.list_offset + LIST_ROWS)]
        names = method_names(dir())
        for (k, n) in enumerate(shown)
            text, ok = n in stored ? _method_summary(dir(), n) : ("new, not saved", true)
            haskey(names, n) && (text = names[n])
            n == LAST_LOADED_METHOD[] && (text *= " · last loaded")
            ok || (text *= " · cannot be loaded")
            active = n == ed.number
            b = Button(lgrid[k, 1]; label=@sprintf("%03d   %s", n, _shorten(text, 38)), halign=:left,
                font=active ? :bold : :regular, strokewidth=0, cornerradius=4,
                buttoncolor=active ? p.accent_soft : p.bg, buttoncolor_hover=p.accent_soft,
                buttoncolor_active=p.accent_soft, labelcolor=ok ? (active ? p.accent : p.text) : p.err,
                labelcolor_hover=p.text)
            on(_ -> _later(() -> open_method!(n), ws), b.clicks)
            push!(list_items, b)
        end
        isempty(all) && push!(list_items, Label(lgrid[1, 1], "No methods yet."; halign=:left, color=p.muted))
        lpage_info.text = ""
        if length(all) > LIST_ROWS
            lpage_info.text = "$(ed.list_offset + 1)–$(ed.list_offset + length(shown)) of $(length(all))"
            prev = Button(lpager[1, 2]; label="Earlier")
            next = Button(lpager[1, 3]; label="Later")
            on(_ -> _later(() -> (ed.list_offset -= LIST_ROWS; render_list!()), ws), prev.clicks)
            on(_ -> _later(() -> (ed.list_offset += LIST_ROWS; render_list!()), ws), next.clicks)
            append!(lpager_items, (prev, next))
        end
    end

    function render_settings!()
        clear!(setting_items, sgrid)
        filter!(kv -> kv.first[1] != 0, boxes)
        m = ed.file
        item(x) = push!(setting_items, x)
        item(Label(sgrid[1, 1], "Name"; halign=:right, fontsize=FS_BODY))
        name_box = Textbox(sgrid[1, 2:6]; stored_string=ed.name, placeholder="Name of the method, kept on this PC only",
            width=380, fontsize=FS_BODY, halign=:left, validator=method_name_ok)
        on(s -> (ed.name = something(s, ""); changed!()), name_box.displayed_string)
        item(name_box)
        item(Label(sgrid[2, 1:8], "Method type: $(strip(setting(m, "Method Type")))   ·   " *
                                  "Method: $(strip(setting(m, "Method")))   (as set on the Akta)";
            halign=:left, fontsize=FS_BODY, color=p.muted))
        for (c, name, label) in ((1, "Method base", "Method base"), (3, "Frac base", "Fraction base"),
            (5, "Max pressure (kPa)", "Max pressure (kPa)"), (7, "Alarm (min/ml)", "Alarm (min/ml)"))
            item(Label(sgrid[3, c], label; halign=:right, fontsize=FS_BODY))
            if haskey(VALUE_CHOICES, name)        # a click steps to the next choice
                b = Button(sgrid[3, c+1]; label=setting(m, name), width=64, halign=:left)
                on(b.clicks) do _
                    opts = VALUE_CHOICES[name]
                    j = something(findfirst(==(setting(ed.file, name)), opts), 0)
                    set_setting!(ed.file, name, opts[mod1(j + 1, length(opts))])
                    b.label = setting(ed.file, name)
                    _later(() -> batch_layout(render_rows!, fig.layout), ws)   # headings show the base
                end
                item(b)
            else
                tb = Textbox(sgrid[3, c+1]; stored_string=setting(m, name), width=72, fontsize=FS_BODY,
                    halign=:left, validator=s -> method_value_ok(name, s))
                on(s -> (set_setting!(ed.file, name, something(s, "")); changed!()), tb.displayed_string)
                boxes[(0, name)] = tb
                item(tb)
            end
        end
    end

    function render_rows!()
        clear!(row_items, rgrid)
        clear!(rpager_items, rpager)
        filter!(kv -> kv.first[1] == 0, boxes)
        m = ed.file
        n = length(m.rows)
        ed.offset = clamp(ed.offset, 0, max(0, n - EDITOR_ROWS))
        item(x) = push!(row_items, x)
        item(Label(rgrid[1, 1], "#"; halign=:right, fontsize=FS_SMALL + 1, color=p.muted))
        for (c, col) in enumerate(BP_COLUMNS)
            item(Label(rgrid[1, c+1], _col_head(col, m); halign=:left, fontsize=FS_SMALL + 1, color=p.muted))
        end
        for i in ed.offset+1:min(n, ed.offset + EDITOR_ROWS)
            r = i - ed.offset + 1
            item(Label(rgrid[r, 1], i == n ? "end" : string(i); halign=:right, color=p.muted))
            for (c, col) in enumerate(BP_COLUMNS)
                if haskey(VALUE_CHOICES, col)     # a click steps to the next choice
                    b = Button(rgrid[r, c+1]; label=m.rows[i][c], width=_COL_WIDTH[col])
                    on(b.clicks) do _
                        opts = VALUE_CHOICES[col]
                        j = something(findfirst(==(ed.file.rows[i][c]), opts), 0)
                        ed.file.rows[i][c] = opts[mod1(j + 1, length(opts))]
                        b.label = ed.file.rows[i][c]
                        changed!()
                    end
                    item(b)
                else
                    tb = Textbox(rgrid[r, c+1]; stored_string=m.rows[i][c], width=_COL_WIDTH[col],
                        fontsize=FS_BODY, placeholder=col == "Volume" ? "e.g. 10.0" : "",
                        validator=s -> method_value_ok(col, s))
                    on(s -> (ed.file.rows[i][c] = something(s, ""); changed!()), tb.displayed_string)
                    boxes[(i, col)] = tb
                    item(tb)
                end
            end
            add = Button(rgrid[r, length(BP_COLUMNS)+2]; label="+", padding=(7, 7, 3, 3))
            rem = Button(rgrid[r, length(BP_COLUMNS)+3]; label="×", padding=(7, 7, 3, 3))
            on(_ -> _later(() -> add_row!(i), ws), add.clicks)
            on(_ -> _later(() -> remove_row!(i), ws), rem.clicks)
            append!(row_items, (add, rem))
        end
        rpage_info.text = ""
        if n > EDITOR_ROWS
            rpage_info.text = "Breakpoints $(ed.offset + 1)–$(min(n, ed.offset + EDITOR_ROWS)) of $n"
            prev = Button(rpager[1, 2]; label="Earlier")
            next = Button(rpager[1, 3]; label="Later")
            on(_ -> _later(() -> batch_layout(() -> (ed.offset -= EDITOR_ROWS; render_rows!()), fig.layout), ws),
                prev.clicks)
            on(_ -> _later(() -> batch_layout(() -> (ed.offset += EDITOR_ROWS; render_rows!()), fig.layout), ws),
                next.clicks)
            append!(rpager_items, (prev, next))
        end
        changed!()
    end

    render_all!() = batch_layout(fig.layout) do
        render_list!()
        render_settings!()
        render_rows!()
    end

    # A new breakpoint below this one, with its values; below the end it extends the method.
    function add_row!(i)
        at = i + 1
        row = copy(ed.file.rows[i])
        row[1] = ""
        insert!(ed.file.rows, at, row)
        at > ed.offset + EDITOR_ROWS && (ed.offset = at - EDITOR_ROWS)
        batch_layout(render_rows!, fig.layout)
        say("Breakpoint $at added: enter its volume.")
    end
    function remove_row!(i)
        deleteat!(ed.file.rows, i)
        batch_layout(render_rows!, fig.layout)
        say("")
    end

    function edit!(n, m, on_disk; name=on_disk ? get(method_names(dir()), n, "") : "")
        ed.number, ed.on_disk, ed.file, ed.saved, ed.offset, ed.pending = n, on_disk, m, copy(m), 0, ""
        ed.name, ed.saved_name = name, on_disk ? name : ""
        render_all!()
    end

    function open_method!(n)
        n == ed.number && return
        _dirty(ed) && !confirm("open $n", "Method $(ed.number) has unsaved changes. Click again to discard them.") &&
            return
        path = find_method_file(dir(), n)
        isnothing(path) && return render_list!()
        m = try
            read_method_file(read(path))
        catch err
            return say("Cannot open $(basename(path)): $(sprint(showerror, err))"; err=true)
        end
        edit!(n, m, true)
        say("")
    end

    function new_method!(m=new_method_file(); name="")
        n = _first_free(dir())
        n == 0 && return say("All method numbers 1–999 are in use."; err=true)
        edit!(n, m, false; name)
        say("Method $n is new: edit it, then Save.")
    end

    function save_as!(n)
        msgs, _ = method_problems(ed.file)
        isempty(msgs) || return say("Not saved: " * first(msgs); err=true)
        method_name_ok(ed.name) || return say("Not saved: the name may have at most 60 characters."; err=true)
        name = String(strip(ed.name))
        if ed.on_disk && n == ed.number && ed.file == ed.saved     # only the name changed
            set_method_name!(dir(), n, name)
            edit!(n, ed.file, true)
            return say(isempty(name) ? "Name removed." : "Name saved.")
        end
        replacing = !(ed.on_disk && n == ed.number) && !isnothing(find_method_file(dir(), n))
        replacing && !confirm("replace $n", "Method $n already exists. Click again to replace it " *
                                            "(the old version is kept in methods/old).") && return
        m = normalize_method(ed.file)
        path = save_method_file(dir(), n, format_method_text(m))
        set_method_name!(dir(), n, name)
        edit!(n, m, true)
        say("Saved as $(basename(path)). On the Akta: Run Stored Method, PC, number $n.")
    end

    function delete_method!()
        if ed.on_disk
            confirm("delete $(ed.number)", "Click Delete again to delete method $(ed.number) " *
                                            "(it is kept in methods/old).") || return
            _retire_method_file(find_method_file(dir(), ed.number))
            set_method_name!(dir(), ed.number, "")
            say("Method $(ed.number) deleted (moved to methods/old).")
        end
        stored = stored_methods(dir())
        isempty(stored) ? edit!(_first_free(dir()), new_method_file(), false) :
        edit!(stored[1], read_method_file(read(find_method_file(dir(), stored[1]))), true)
    end

    # Files changed outside the editor: by the Akta, by hand, or the folder moved.
    function refresh!()
        disk_name = get(method_names(dir()), ed.number, "")
        if ed.on_disk && disk_name != ed.saved_name          # renamed outside the editor
            strip(ed.name) == ed.saved_name && (ed.name = disk_name; batch_layout(render_settings!, fig.layout))
            ed.saved_name = disk_name
        end
        if ed.on_disk
            path = find_method_file(dir(), ed.number)
            m = isnothing(path) ? nothing : try
                read_method_file(read(path))
            catch
                nothing
            end
            if isnothing(m)
                ed.on_disk = false
                say("Method $(ed.number) is no longer in the folder; Save writes it again."; err=true)
            elseif m != ed.saved
                if _dirty(ed)
                    ed.saved = m
                    say("Method $(ed.number) was replaced while you were editing it. Saving replaces " *
                        "that version (it is kept in methods/old)."; err=true)
                else
                    edit!(ed.number, m, true)
                    return say("Method $(ed.number) was replaced on disk; showing the new version.")
                end
            end
        end
        batch_layout(() -> (render_list!(); changed!()), fig.layout)
    end

    on(_ -> _later(() -> save_as!(ed.number), ws), save_btn.clicks)
    function save_as_box!()
        s = strip(something(as_box.displayed_string[], ""))
        occursin(r"^\d{1,3}$", s) && parse(Int, s) in METHOD_NUMBERS ||
            return say("Enter a method number from 1 to 999."; err=true)
        save_as!(parse(Int, s))
    end
    on(_ -> _later(save_as_box!, ws), as_btn.clicks)
    on(_ -> _later(save_as_box!, ws), as_box.stored_string)
    on(revert_btn.clicks) do _
        _later(ws) do
            m = ed.on_disk ? read_method_file(read(find_method_file(dir(), ed.number))) : new_method_file()
            edit!(ed.number, m, ed.on_disk)
            say("Changes discarded.")
        end
    end
    on(_ -> _later(() -> (!_dirty(ed) || confirm("new", "Unsaved changes. Click New again to discard them.")) &&
                             new_method!(), ws), new_btn.clicks)
    on(_ -> _later(() -> new_method!(copy(ed.file); name=isempty(strip(ed.name)) ? "" : strip(ed.name) * " (copy)"), ws),
        dup_btn.clicks)
    on(_ -> _later(delete_method!, ws), del_btn.clicks)
    listener[] = on(_ -> on_screen[] && _later(refresh!, ws), METHODS_CHANGED)
    on(shown -> shown && _later(refresh!, ws), on_screen)

    # Start with the first stored method, or a new one.
    if isempty(nums)
        ed.number = _first_free(dir())
        render_list!(); render_settings!(); render_rows!()
    else
        m = try
            read_method_file(read(find_method_file(dir(), nums[1])))
        catch
            nothing
        end
        ed.number, ed.on_disk = nums[1], !isnothing(m)
        isnothing(m) || (ed.file = m; ed.saved = copy(m))
        ed.name = ed.saved_name = get(method_names(dir()), nums[1], "")
        render_list!(); render_settings!(); render_rows!()
    end
    finish_layout!(fig)
    return fig
end
