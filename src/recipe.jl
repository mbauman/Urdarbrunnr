"""
    SourceRef

One source entry from a recipe's `sources` vector.

- `kind`: `:ArchiveSource`, `:FileSource`, or `:GitSource`
- `url_expr`: the raw parsed expression for the URL argument (a `String`
  literal or an interpolation `Expr` referencing `version`/`name`)
- `url`: the URL rendered with the recipe's *current* version
- `hash`: the second positional argument — a SHA256 hex digest for
  archive/file sources, a 40-char commit SHA for git sources
"""
struct SourceRef
    kind::Symbol
    url_expr::Any
    url::String
    hash::String
end

"""
    Recipe

A parsed `build_tarballs.jl`, retaining the original text so that updates
can be applied as minimal textual edits that preserve formatting.
"""
struct Recipe
    path::String
    text::String
    name::String
    version::VersionNumber
    sources::Vector{SourceRef}
end

# The source constructors we know how to update. DirectorySource has no
# version-dependent content, so it is deliberately ignored.
const SOURCE_KINDS = (:ArchiveSource, :FileSource, :GitSource)

"""
    parse_recipe(path::AbstractString) -> Recipe

Parse a `build_tarballs.jl` file. Throws if the recipe doesn't have the
simple shape we support (literal `name = "..."`, literal `version = v"..."`,
sources with literal hashes). See [`parse_recipe_text`](@ref) to parse
recipe source held in a string.
"""
parse_recipe(path::AbstractString) = parse_recipe_text(read(path, String); path=String(path))

function parse_recipe_text(text::String; path::String="build_tarballs.jl")
    ast = Meta.parseall(text; filename=path)

    name = nothing
    version = nothing
    sources = SourceRef[]

    walk(ast) do ex
        Meta.isexpr(ex, :(=), 2) || Meta.isexpr(ex, :call) || return
        if Meta.isexpr(ex, :(=))
            lhs, rhs = ex.args
            if lhs === :name && rhs isa String && name === nothing
                name = rhs
            elseif lhs === :version && version === nothing
                version = parse_version_literal(rhs, path)
            end
        elseif Meta.isexpr(ex, :call) && ex.args[1] in SOURCE_KINDS
            push!(sources, parse_source(ex, path))
        end
        return
    end

    name === nothing && unsupported(path, "no literal `name = \"...\"` assignment found")
    version === nothing && unsupported(path, "no `version = v\"...\"` assignment found")

    # Render current URLs now that we know name and version.
    rendered = [SourceRef(s.kind, s.url_expr, render_url(s.url_expr; version, name), s.hash)
                for s in sources]
    return Recipe(path, text, name, version, rendered)
end

"Depth-first traversal calling `f` on every expression node."
function walk(f, ex)
    f(ex)
    if ex isa Expr
        for arg in ex.args
            walk(f, arg)
        end
    end
    return
end

function parse_version_literal(rhs, path)
    if Meta.isexpr(rhs, :macrocall) && rhs.args[1] === Symbol("@v_str")
        return VersionNumber(rhs.args[end]::String)
    end
    unsupported(path, "`version` is not a literal `v\"...\"` (got `$rhs`); " *
                      "computed versions are out of scope")
end

function parse_source(callex::Expr, path)
    kind = callex.args[1]::Symbol
    args = [a for a in callex.args[2:end]
            if !(Meta.isexpr(a, :parameters) || Meta.isexpr(a, :kw))]
    length(args) >= 2 ||
        unsupported(path, "`$kind` call with fewer than two positional arguments")
    url_expr, hash = args[1], args[2]
    hash isa String ||
        unsupported(path, "`$kind` hash argument is not a string literal (got `$hash`)")
    url_expr isa String || Meta.isexpr(url_expr, :string) ||
        unsupported(path, "`$kind` URL is not a string (got `$url_expr`)")
    return SourceRef(kind, url_expr, "", hash)
end

"""
    render_url(url_expr; version, name="") -> String

Evaluate a source-URL expression with `version` (and `name`) bound.
Handles plain strings as well as any interpolation of `version`, e.g.
`"https://.../v\$(version)/foo-\$(version.major).\$(version.minor).tar.gz"`.
"""
function render_url(url_expr; version::VersionNumber, name::AbstractString="")
    url_expr isa AbstractString && return String(url_expr)
    sandbox = Module(:UrdarbrunnrRender)
    Core.eval(sandbox, :(version = $version))
    Core.eval(sandbox, :(name = $(String(name))))
    url = try
        Core.eval(sandbox, url_expr)
    catch err
        error("could not render source URL `$url_expr` with version=$version: " *
              sprint(showerror, err) *
              " — the URL likely references variables other than `version`/`name`, " *
              "which is out of scope for Urdarbrunnr")
    end
    url isa AbstractString || error("source URL expression evaluated to a non-string: `$url`")
    return String(url)
end

"""
    update_recipe(recipe::Recipe, new_version::VersionNumber;
                  archive_hash=archive_sha256, git_commit=resolve_git_tag) -> String

Return the recipe text updated to `new_version`: the `version = v"..."`
literal is bumped, and every source hash is replaced with the hash of the
re-rendered source (`archive_hash(url)` for archive/file sources,
`git_commit(url, current_commit, current_version, new_version)` for git
sources). The hash resolvers are keyword arguments so tests can inject
fakes.
"""
function update_recipe(recipe::Recipe, new_version::VersionNumber;
                       archive_hash=archive_sha256, git_commit=resolve_git_tag)
    new_version > recipe.version ||
        error("$(recipe.name): new version $new_version is not newer than current $(recipe.version)")

    version_re = r"^(\s*version\s*=\s*)v\"[^\"]+\""m
    occursin(version_re, recipe.text) ||
        error("$(recipe.name): could not locate the `version = v\"...\"` line for rewriting")
    text = replace(recipe.text, version_re => SubstitutionString("\\1v\"$new_version\""); count=1)

    changed = 0
    for src in recipe.sources
        if src.kind === :GitSource
            new_hash = git_commit(src.url, src.hash, recipe.version, new_version)
        else
            new_url = render_url(src.url_expr; version=new_version, name=recipe.name)
            if new_url == src.url
                # URL does not depend on the version; the content it points at
                # cannot have changed, so leave its hash alone.
                continue
            end
            new_hash = archive_hash(new_url)
        end
        new_hash == src.hash && continue
        old, new = "\"$(src.hash)\"", "\"$new_hash\""
        count_occurrences(text, old) == 1 ||
            error("$(recipe.name): expected exactly one occurrence of hash $(src.hash)")
        text = replace(text, old => new)
        changed += 1
    end
    changed > 0 || error("$(recipe.name): bumping to v$new_version changed no source. " *
        "The version is likely baked into a source URL as a literal (e.g. \"…-$(recipe.version).tar.gz\") " *
        "rather than interpolated as \"…-\$(version).tar.gz\"; Urdarbrunnr only updates recipes " *
        "that interpolate the version into their sources.")
    return text
end

count_occurrences(haystack, needle) = length(findall(needle, haystack))

unsupported(path, msg) = error("$path: $msg (Urdarbrunnr only handles simple recipes)")
