# This file is a part of Julia. License is MIT: https://julialang.org/license

## core text I/O ##

"""
    print([io::IO], xs...)

Write to `io` (or to the default output stream [`stdout`](@ref)
if `io` is not given) a canonical (un-decorated) text representation.
The representation used by `print` includes minimal formatting and tries to
avoid Julia-specific details.

`print` falls back to calling the 2-argument `show(io, x)` for each argument `x` in `xs`,
so most types should just define `show`. Define `print` if your type has a separate
"plain" representation.  For example, `show` displays strings with quotes, and `print`
displays strings without quotes.

See also [`println`](@ref), [`string`](@ref), [`printstyled`](@ref).

# Examples
```jldoctest
julia> print("Hello World!")
Hello World!
julia> io = IOBuffer();

julia> print(io, "Hello", ' ', :World!)

julia> takestring!(io)
"Hello World!"
```
"""
function print(io::IO, x)
    lock(io)
    try
        show(io, x)
    finally
        unlock(io)
    end
    return nothing
end

function print(io::IO, xs...)
    lock(io)
    try
        for x in xs
            print(io, x)
        end
    finally
        unlock(io)
    end
    return nothing
end

setfield!(typeof(print).name, :max_args, Int32(10), :monotonic)

"""
    println([io::IO], xs...)

Print (using [`print`](@ref)) `xs` to `io` followed by a newline.
If `io` is not supplied, prints to the default output stream [`stdout`](@ref).

See also [`printstyled`](@ref) to add colors etc.

# Examples
```jldoctest
julia> println("Hello, world")
Hello, world

julia> io = IOBuffer();

julia> println(io, "Hello", ',', " world.")

julia> takestring!(io)
"Hello, world.\\n"
```
"""
println(io::IO, xs...) = print(io, xs..., "\n")

setfield!(typeof(println).name, :max_args, Int32(10), :monotonic)
## conversion of general objects to strings ##

"""
    sprint(f::Function, args...; context=nothing, sizehint=0)

Call the given function with an I/O stream and the supplied extra arguments.
Everything written to this I/O stream is returned as a string.

The optional keyword argument `context` can be set to a `:key=>value` pair, a
tuple of `:key=>value` pairs, or an `IO` or [`IOContext`](@ref) object whose
attributes are used for the I/O stream passed to `f`.  The optional `sizehint`
is a suggested size (in bytes) to allocate for the buffer used to write the
string.

!!! compat "Julia 1.7"
    Passing a tuple to keyword `context` requires Julia 1.7 or later.

# Examples
```jldoctest
julia> sprint(show, 66.66666; context=:compact => true)
"66.6667"

julia> sprint(showerror, BoundsError([1], 100))
"BoundsError: attempt to access 1-element Vector{Int64} at index [100]"
```
"""
function sprint(f::Function, args...; context=nothing, sizehint::Integer=0)
    s = IOBuffer(sizehint=sizehint)
    if context isa Tuple
        f(IOContext(s, context...), args...)
    elseif context !== nothing
        f(IOContext(s, context), args...)
    else
        f(s, args...)
    end
    takestring!(s)
end

function _str_sizehint(x)
    if x isa Float64
        return 20
    elseif x isa Float32
        return 12
    elseif x isa String || x isa SubString{String}
        return sizeof(x)
    elseif x isa Char
        return ncodeunits(x)
    elseif x isa UInt64 || x isa UInt32
        return ndigits(x)
    elseif x isa Int64 || x isa Int32
        return ndigits(x) + (x < zero(x))
    else
        return 8
    end
end

function print_to_string(xs...)
    if isempty(xs)
        return ""
    end
    siz::Int = 0
    for x in xs
        siz += _str_sizehint(x)
    end
    # specialized for performance reasons
    s = IOBuffer(sizehint=siz)
    for x in xs
        print(s, x)
    end
    takestring!(s)
end
setfield!(typeof(print_to_string).name, :max_args, Int32(10), :monotonic)

function string_with_env(env, xs...)
    if isempty(xs)
        return ""
    end
    siz::Int = 0
    for x in xs
        siz += _str_sizehint(x)
    end
    # specialized for performance reasons
    s = IOBuffer(sizehint=siz)
    env_io = IOContext(s, env)
    for x in xs
        print(env_io, x)
    end
    takestring!(s)
end

"""
    string(xs...)

Create a string from any values using the [`print`](@ref) function.

`string` should usually not be defined directly. Instead, define a method
`print(io::IO, x::MyType)`. If `string(x)` for a certain type needs to be
highly efficient, then it may make sense to add a method to `string` and
define `print(io::IO, x::MyType) = print(io, string(x))` to ensure the
functions are consistent.

See also: [`String`](@ref), [`repr`](@ref), [`sprint`](@ref), [`show`](@ref @show).

# Examples
```jldoctest
julia> string("a", 1, true)
"a1true"
```
"""
string(xs...) = print_to_string(xs...)

string(a::Symbol) = String(a)

# note: print uses an encoding determined by `io` (defaults to UTF-8), whereas
#       write uses an encoding determined by `s` (UTF-8 for `String`)
print(io::IO, s::AbstractString) = for c in s; print(io, c); end
write(io::IO, s::AbstractString) = (len = 0; for c in s; len += Int(write(io, c))::Int; end; len)
show(io::IO, s::AbstractString) = print_quoted(io, s)

# show elided string if more than `limit` characters
function show(
    io    :: IO,
    mime  :: MIME"text/plain",
    str   :: AbstractString;
    limit :: Union{Int, Nothing} = nothing,
)
    # compute limit in default case
    if limit === nothing
        get(io, :limit, false)::Bool || return show(io, str)
        limit = max(20, displaysize(io)[2])
        # one line in collection, seven otherwise
        get(io, :typeinfo, nothing) === nothing && (limit *= 7)
    end
    limit = max(0, limit-2) # quote chars

    # early out for short strings
    check_textwidth(str, limit) && return show(io, str)

    # these don't depend on string data
    units = codeunit(str) == UInt8 ? "bytes" : "code units"
    skip_text(skip) = " ⋯ $skip $units ⋯ "

    # longest possible replacement string for omitted chars
    max_replacement = skip_text(ncodeunits(str) * 100) # *100 for 2 inner quote chars

    head, tail = string_truncate_boundaries(str, limit, max_replacement, Val(:center))

    # threshold: min chars skipped to make elision worthwhile
    afterhead = nextind(str, head)
    n = tail - afterhead # skipped code units
    replacement = skip_text(n)
    t = ncodeunits(replacement) # length of replacement (textwidth == ncodeunits here)
    @views if 4t ≤ n || t ≤ n && t ≤ textwidth(str[afterhead:prevind(str,tail)])
        show(io, str[begin:head])
        printstyled(io, replacement; color=:light_yellow, bold=true)
        show(io, str[tail:end])
    else
        show(io, str)
    end
end

# optimized methods to avoid iterating over chars
write(io::IO, s::Union{String,SubString{String}}) =
    GC.@preserve s (unsafe_write(io, pointer(s), reinterpret(UInt, sizeof(s))) % Int)::Int
print(io::IO, s::Union{String,SubString{String}}) = (write(io, s); nothing)

"""
    repr(x; context=nothing)

Create a string representation of any value using the 2-argument `show(io, x)` function,
which aims to produce a string that is parseable Julia code, where possible.
i.e. `eval(Meta.parse(repr(x))) == x` should hold true.
You should not add methods to `repr`; define a [`show`](@ref) method instead.

The optional keyword argument `context` can be set to a `:key=>value` pair, a
tuple of `:key=>value` pairs, or an `IO` or [`IOContext`](@ref) object whose
attributes are used for the I/O stream passed to `show`.

Note that `repr(x)` is usually similar to how the value of `x` would
be entered in Julia.  See also [`repr(MIME("text/plain"), x)`](@ref) to instead
return a "pretty-printed" version of `x` designed more for human consumption,
equivalent to the REPL display of `x`, using the 3-argument `show(io, mime, x)`.

!!! compat "Julia 1.7"
    Passing a tuple to keyword `context` requires Julia 1.7 or later.

# Examples
```jldoctest
julia> repr(1)
"1"

julia> repr(zeros(3))
"[0.0, 0.0, 0.0]"

julia> repr(big(1/3))
"0.333333333333333314829616256247390992939472198486328125"

julia> repr(big(1/3), context=:compact => true)
"0.333333"

```
"""
repr(x; context=nothing) = sprint(show, x; context=context)

limitrepr(x) = repr(x, context = :limit=>true)

# IOBuffer views of a (byte)string:

"""
    IOBuffer(string::String)

Create a read-only `IOBuffer` on the data underlying the given string.

# Examples
```jldoctest
julia> io = IOBuffer("Haho");

julia> takestring!(io)
"Haho"

julia> takestring!(io)
"Haho"
```
"""
IOBuffer(str::String) = IOBuffer(unsafe_wrap(Vector{UInt8}, str))
IOBuffer(s::SubString{String}) = IOBuffer(view(unsafe_wrap(Vector{UInt8}, s.string), s.offset + 1 : s.offset + sizeof(s)))

# join is implemented using IO

"""
    join([io::IO,] iterator [, delim [, last]])

Join any `iterator` into a single string, inserting the given delimiter (if any) between
adjacent items.  If `last` is given, it will be used instead of `delim` between the last
two items.  Each item of `iterator` is converted to a string via `print(io::IOBuffer, x)`.
If `io` is given, the result is written to `io` rather than returned as a `String`.

# Examples
```jldoctest
julia> join(["apples", "bananas", "pineapples"], ", ", " and ")
"apples, bananas and pineapples"

julia> join([1,2,3,4,5])
"12345"
```
"""
function join(io::IO, iterator, delim, last)
    first = true
    local prev
    for item in iterator
        if @isdefined prev
            first ? (first = false) : print(io, delim)
            print(io, prev)
        end
        prev = item
    end
    if @isdefined prev
        first || print(io, last)
        print(io, prev)
    end
    nothing
end
function join(io::IO, iterator, delim="")
    # Specialization of the above code when delim==last,
    # which lets us emit (compile) less code
    first = true
    for item in iterator
        first ? (first = false) : print(io, delim)
        print(io, item)
    end
end

function _join_preserve_annotations(iterator, args...)
    et = @default_eltype(iterator)
    if isconcretetype(et) && !_isannotated(et) && !any(_isannotated, args)
        sprint(join, iterator, args...)
    else
        io = AnnotatedIOBuffer()
        join(io, iterator, args...)
        # If we know (from compile time information, or dynamically in the case
        # of iterators with a non-concrete eltype), that the result is annotated
        # in nature, we extract an `AnnotatedString`, otherwise we just extract
        # a plain `String` from `io`.
        if isconcretetype(et) || !isempty(io.annotations)
            seekstart(io)
            read(io, AnnotatedString{String})
        else
            String(take!(io.io))
        end
    end
end

join(iterator) = _join_preserve_annotations(iterator)
join(iterator, delim) = _join_preserve_annotations(iterator, delim)
join(iterator, delim, last) = _join_preserve_annotations(iterator, delim, last)

## string escaping & unescaping ##

need_full_hex(c::Union{Nothing, AbstractChar}) = c !== nothing && isxdigit(c)
escape_nul(c::Union{Nothing, AbstractChar}) =
    (c !== nothing && '0' <= c <= '7') ? "\\x00" : "\\0"

"""
    escape_string(str::AbstractString[, esc]; keep=(), ascii=false, fullhex=false)::AbstractString
    escape_string(io, str::AbstractString[, esc]; keep=())::Nothing

General escaping of traditional C and Unicode escape sequences. The first form returns the
escaped string, the second prints the result to `io`.

Backslashes (`\\`) are escaped with a double-backslash (`"\\\\"`). Non-printable
characters are escaped either with their standard C escape codes, `"\\0"` for NUL (if
unambiguous), unicode code point (`"\\u"` prefix) or hex (`"\\x"` prefix).

The optional `esc` argument specifies any additional characters that should also be
escaped by a prepending backslash (`\"` is also escaped by default in the first form).

The argument `keep` specifies a collection of characters which are to be kept as
they are. Notice that `esc` has precedence here.

The argument `ascii` can be set to `true` to escape all non-ASCII characters,
whereas the default `ascii=false` outputs printable Unicode characters as-is.
(`keep` takes precedence over `ascii`.)

The argument `fullhex` can be set to `true` to require all `\\u` escapes to be
printed with 4 hex digits, and `\\U` escapes to be printed with 8 hex digits,
whereas by default (`fullhex=false`) they are printed with fewer digits if
possible (omitting leading zeros).

See also [`unescape_string`](@ref) for the reverse operation.

!!! compat "Julia 1.7"
    The `keep` argument is available as of Julia 1.7.

!!! compat "Julia 1.12"
    The `ascii` and `fullhex` arguments require Julia 1.12.

# Examples
```jldoctest
julia> escape_string("aaa\\nbbb")
"aaa\\\\nbbb"

julia> escape_string("aaa\\nbbb"; keep = '\\n')
"aaa\\nbbb"

julia> escape_string("\\xfe\\xff") # invalid utf-8
"\\\\xfe\\\\xff"

julia> escape_string(string('\\u2135','\\0')) # unambiguous
"ℵ\\\\0"

julia> escape_string(string('\\u2135','\\0','0')) # \\0 would be ambiguous
"ℵ\\\\x000"
```
"""
function escape_string(io::IO, s::AbstractString, esc=""; keep = (), ascii::Bool=false, fullhex::Bool=false)
    a = Iterators.Stateful(s)
    for c::AbstractChar in a
        if c in esc
            print(io, '\\', c)
        elseif c in keep
            print(io, c)
        elseif isascii(c)
            c == '\0'          ? print(io, escape_nul(peek(a)::Union{AbstractChar,Nothing})) :
            c == '\e'          ? print(io, "\\e") :
            c == '\\'          ? print(io, "\\\\") :
            '\a' <= c <= '\r'  ? print(io, '\\', "abtnvfr"[Int(c)-6]) :
            isprint(c)         ? print(io, c) :
                                 print(io, "\\x", string(UInt32(c), base = 16, pad = 2))
        elseif !isoverlong(c) && !ismalformed(c)
            !ascii && isprint(c) ? print(io, c) :
            c <= '\x7f'          ? print(io, "\\x", string(UInt32(c), base = 16, pad = 2)) :
            c <= '\uffff'        ? print(io, "\\u", string(UInt32(c), base = 16, pad = fullhex || need_full_hex(peek(a)::Union{AbstractChar,Nothing}) ? 4 : 2)) :
                                   print(io, "\\U", string(UInt32(c), base = 16, pad = fullhex || need_full_hex(peek(a)::Union{AbstractChar,Nothing}) ? 8 : 4))
        else # malformed or overlong
            u = bswap(reinterpret(UInt32, c)::UInt32)
            while true
                print(io, "\\x", string(u % UInt8, base = 16, pad = 2))
                (u >>= 8) == 0 && break
            end
        end
    end
end

escape_string(s::AbstractString, esc=('\"',); keep = (), ascii::Bool=false, fullhex::Bool=false) =
    sprint((io)->escape_string(io, s, esc; keep, ascii, fullhex), sizehint=lastindex(s))

function print_quoted(io, s::AbstractString)
    print(io, '"')
    escape_string(io, s, ('\"','$')) #"# work around syntax highlighting problem
    print(io, '"')
end

# general unescaping of traditional C and Unicode escape sequences

# TODO: handle unescaping invalid UTF-8 sequences
"""
    unescape_string(str::AbstractString, keep = ())::AbstractString
    unescape_string(io, s::AbstractString, keep = ())::Nothing

General unescaping of traditional C and Unicode escape sequences. The first form returns
the escaped string, the second prints the result to `io`.
The argument `keep` specifies a collection of characters which (along with backlashes) are
to be kept as they are.

The following escape sequences are recognised:
 - Escaped backslash (`\\\\`)
 - Escaped double-quote (`\\\"`)
 - Standard C escape sequences (`\\a`, `\\b`, `\\t`, `\\n`, `\\v`, `\\f`, `\\r`, `\\e`)
 - Unicode BMP code points (`\\u` with 1-4 trailing hex digits)
 - All Unicode code points (`\\U` with 1-8 trailing hex digits; max value = 0010ffff)
 - Hex bytes (`\\x` with 1-2 trailing hex digits)
 - Octal bytes (`\\` with 1-3 trailing octal digits)

See also [`escape_string`](@ref).

# Examples
```jldoctest
julia> unescape_string("aaa\\\\nbbb") # C escape sequence
"aaa\\nbbb"

julia> unescape_string("\\\\u03c0") # unicode
"π"

julia> unescape_string("\\\\101") # octal
"A"

julia> unescape_string("aaa \\\\g \\\\n", ['g']) # using `keep` argument
"aaa \\\\g \\n"
```
"""
function unescape_string(io::IO, s::AbstractString, keep = ())
    a = Iterators.Stateful(s)
    for c in a
        if !isempty(a) && c == '\\'
            c = popfirst!(a)
            if c in keep
                print(io, '\\', c)
            elseif c == 'x' || c == 'u' || c == 'U'
                n = k = 0
                m = c == 'x' ? 2 :
                    c == 'u' ? 4 : 8
                while (k += 1) <= m && !isempty(a)
                    nc = peek(a)::AbstractChar
                    n = '0' <= nc <= '9' ? n<<4 + (nc-'0') :
                        'a' <= nc <= 'f' ? n<<4 + (nc-'a'+10) :
                        'A' <= nc <= 'F' ? n<<4 + (nc-'A'+10) : break
                    popfirst!(a)
                end
                if k == 1 || n > 0x10ffff
                    u = m == 4 ? 'u' : 'U'
                    throw(ArgumentError("invalid $(m == 2 ? "hex (\\x)" :
                                        "unicode (\\$u)") escape sequence"))
                end
                if m == 2 # \x escape sequence
                    write(io, UInt8(n))
                else
                    print(io, Char(n))
                end
            elseif '0' <= c <= '7'
                k = 1
                n = c-'0'
                while (k += 1) <= 3 && !isempty(a)
                    c = peek(a)::AbstractChar
                    n = ('0' <= c <= '7') ? n<<3 + c-'0' : break
                    popfirst!(a)
                end
                if n > 255
                    throw(ArgumentError("octal escape sequence out of range"))
                end
                write(io, UInt8(n))
            else
                print(io, c == 'a' ? '\a' :
                          c == 'b' ? '\b' :
                          c == 't' ? '\t' :
                          c == 'n' ? '\n' :
                          c == 'v' ? '\v' :
                          c == 'f' ? '\f' :
                          c == 'r' ? '\r' :
                          c == 'e' ? '\e' :
                          (c == '\\' || c == '"') ? c :
                          throw(ArgumentError("invalid escape sequence \\$c")))
            end
        else
            print(io, c)
        end
    end
end
unescape_string(s::AbstractString, keep = ()) =
    sprint(unescape_string, s, keep; sizehint=lastindex(s))

"""
    @b_str

Create an immutable byte (`UInt8`) vector using string syntax.

# Examples
```jldoctest
julia> v = b"12\\x01\\x02"
4-element Base.CodeUnits{UInt8, String}:
 0x31
 0x32
 0x01
 0x02

julia> v[2]
0x32
```
"""
macro b_str(s::String)
    v = codeunits(unescape_string(s))
    QuoteNode(v)
end

"""
    @raw_str -> String

Create a raw string without interpolation and unescaping.
The exception is that quotation marks still must be escaped. Backslashes
escape both quotation marks and other backslashes, but only when a sequence
of backslashes precedes a quote character. Thus, 2n backslashes followed by
a quote encodes n backslashes and the end of the literal while 2n+1 backslashes
followed by a quote encodes n backslashes followed by a quote character.

# Examples
```jldoctest
julia> println(raw"\\ \$x")
\\ \$x

julia> println(raw"\\"")
"

julia> println(raw"\\\\\\"")
\\"

julia> println(raw"\\\\x \\\\\\"")
\\\\x \\"
```
"""
macro raw_str(s); s; end

"""
    escape_raw_string(s::AbstractString, delim='"')::AbstractString
    escape_raw_string(io, s::AbstractString, delim='"')

Escape a string in the manner used for parsing raw string literals.
For each double-quote (`"`) character in input string `s` (or `delim` if
specified), this function counts the number _n_ of preceding backslash (`\\`)
characters, and then increases there the number of backslashes from _n_ to
2_n_+1 (even for _n_ = 0). It also doubles a sequence of backslashes at the end
of the string.

This escaping convention is used in raw strings and other non-standard
string literals. (It also happens to be the escaping convention
expected by the Microsoft C/C++ compiler runtime when it parses a
command-line string into the argv[] array.)

See also [`Base.escape_string()`](@ref).
"""
function escape_raw_string(io::IO, str::AbstractString, delim::Char='"')
    total = 0
    escapes = 0
    for c in str
        if c == '\\'
            escapes += 1
        else
            if c == delim
                # if one or more backslashes are followed by
                # a double quote then escape all backslashes
                # and the double quote
                escapes += 1
                total += escapes
                while escapes > 0
                    write(io, '\\')
                    escapes -= 1
                end
            end
            escapes = 0
        end
        write(io, c)
    end
    # also escape any trailing backslashes,
    # so they do not affect the closing quote
    total += escapes
    while escapes > 0
        write(io, '\\')
        escapes -= 1
    end
    total
end
function escape_raw_string(str::AbstractString, delim::Char='"')
    total = escape_raw_string(devnull, str, delim) # check whether the string even needs to be copied and how much to allocate for it
    return total == 0 ? str : sprint(escape_raw_string, str, delim; sizehint = sizeof(str) + total)
end

## multiline strings ##

"""
    indentation(str::AbstractString; tabwidth=8) -> (width::Int, empty::Bool)

Calculate the width of leading white space. Return the width and a flag to indicate
if the string is empty.

# Examples
```jldoctest
julia> Base.indentation("")
(0, true)

julia> Base.indentation("  a")
(2, false)

julia> Base.indentation("\\ta"; tabwidth=3)
(3, false)
```
"""
function indentation(str::AbstractString; tabwidth=8)
    count = 0
    for ch in str
        if ch == ' '
            count += 1
        elseif ch == '\t'
            count = div(count + tabwidth, tabwidth) * tabwidth
        else
            return count, false
        end
    end
    count, true
end

"""
    unindent(str::AbstractString, indent::Int; tabwidth=8)

Remove leading indentation from string.

See also `indent` from the [`MultilineStrings` package](https://github.com/invenia/MultilineStrings.jl).

# Examples
```jldoctest
julia> Base.unindent("   a\\n   b", 2)
" a\\n b"

julia> Base.unindent("\\ta\\n\\tb", 2, tabwidth=8)
"      a\\n      b"
```
"""
function unindent(str::AbstractString, indent::Int; tabwidth=8)
    indent == 0 && return str
    # Note: this loses the type of the original string
    buf = IOBuffer(sizehint=sizeof(str))
    cutting = true
    col = 0     # current column (0 based)
    for ch in str
        if cutting
            if ch == ' '
                col += 1
            elseif ch == '\t'
                col = div(col + tabwidth, tabwidth) * tabwidth
            elseif ch == '\n'
                # Now we need to output enough indentation
                for i = 1:col-indent
                    print(buf, ' ')
                end
                col = 0
                print(buf, '\n')
            else
                cutting = false
                # Now we need to output enough indentation to get to
                # correct place
                for i = 1:col-indent
                    print(buf, ' ')
                end
                col += 1
                print(buf, ch)
            end
        elseif ch == '\t'       # Handle internal tabs
            upd = div(col + tabwidth, tabwidth) * tabwidth
            # output the number of spaces that would have been seen
            # with original indentation
            for i = 1:(upd-col)
                print(buf, ' ')
            end
            col = upd
        elseif ch == '\n'
            cutting = true
            col = 0
            print(buf, '\n')
        else
            col += 1
            print(buf, ch)
        end
    end
    # If we were still "cutting" when we hit the end of the string,
    # we need to output the right number of spaces for the indentation
    if cutting
        for i = 1:col-indent
            print(buf, ' ')
        end
    end
    takestring!(buf)
end

function String(a::AbstractVector{Char})
    n = 0
    for v in a
        n += ncodeunits(v)
    end
    out = _string_n(n)
    offs = 1
    for v in a
        offs += __unsafe_string!(out, v, offs)
    end
    return out
end

function String(chars::AbstractVector{<:AbstractChar})
    sprint(sizehint=length(chars)) do io
        for c in chars
            print(io, c)
        end
    end
end

function AnnotatedString(chars::AbstractVector{C}) where {C<:AbstractChar}
    str = if C <: AnnotatedChar
        String(getfield.(chars, :char))
    else
        sprint(sizehint=length(chars)) do io
            for c in chars
                print(io, c)
            end
        end
    end
    annots = RegionAnnotation[]
    point = 1
    for c in chars
        if c isa AnnotatedChar
            for annot in c.annotations
                push!(annots, (point:point, annot...))
            end
        end
        point += ncodeunits(c)
    end
    AnnotatedString(str, annots)
end
