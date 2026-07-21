git(root, args...) = run(`git -C $root $(collect(args))`)

"""
    ensure_clone!() -> String

Make sure an up-to-date checkout of JuliaPackaging/Yggdrasil exists and
return its path (`\$YGGDRASIL_CLONE`, defaulting to
`~/.urdarbrunnr/Yggdrasil`). Uses a blobless partial clone since
Yggdrasil's history is large and we only ever touch one recipe.
"""
function ensure_clone!()
    dir = get(ENV, "YGGDRASIL_CLONE", joinpath(homedir(), ".urdarbrunnr", "Yggdrasil"))
    if !isdir(joinpath(dir, ".git"))
        mkpath(dirname(dir))
        run(`git clone --filter=blob:none https://github.com/JuliaPackaging/Yggdrasil.git $dir`)
    else
        git(dir, "fetch", "origin", "master")
    end
    return dir
end

"""
    find_recipe(root::AbstractString, name::AbstractString) -> String

Locate `<root>/<letter>/<Name>/build_tarballs.jl` for a project name,
matching case-insensitively. Throws if the recipe doesn't exist or the
name is ambiguous.
"""
function find_recipe(root::AbstractString, name::AbstractString)
    # Always scan rather than probing an exact path: this both handles
    # case-insensitive matching and returns the on-disk casing of the path
    # even on case-insensitive filesystems.
    name = chopsuffix(lowercase(name), "_jll")
    matches = String[]
    for shard in readdir(root; join=true)
        isdir(shard) || continue
        startswith(basename(shard), ".") && continue
        for dir in readdir(shard; join=true)
            if lowercase(basename(dir)) == name
                candidate = joinpath(dir, "build_tarballs.jl")
                isfile(candidate) && push!(matches, candidate)
            end
        end
    end
    length(matches) == 1 && return only(matches)
    isempty(matches) && error("no recipe named $name found under $root")
    error("multiple recipes match $name: $(join(matches, ", "))")
end

"""
    validate_recipe(recipe_path, new_version)

Smoke-test an updated recipe by running it with BinaryBuilder's
`--meta-json` flag, which evaluates the entire script and emits the build
metadata without building anything. Throws (with the script's output) if
the recipe fails to run, or if the emitted metadata doesn't mention the
new version.
"""
function validate_recipe(recipe_path::AbstractString, new_version::VersionNumber)
    cmd = Cmd(`$(Base.julia_cmd()) --project=$(Base.active_project())
               $(basename(recipe_path)) --meta-json`; dir=dirname(abspath(recipe_path)))
    out = IOBuffer()
    ok = success(pipeline(cmd; stdout=out, stderr=out))
    text = String(take!(out))
    ok || error("the updated $recipe_path is not valid; `--meta-json` failed with:\n$text")
    # BinaryBuilder serializes the version with a leading "v" ("version":"v1.5.6")
    occursin("\"v$new_version\"", text) || occursin("\"$new_version\"", text) ||
        error("`--meta-json` output for the updated $recipe_path does not mention $new_version:\n$text")
    return nothing
end

"""
    workflow_provenance() -> String

When running inside a GitHub Actions workflow, a Markdown sentence linking
to the run and crediting whoever triggered it, built from the default
`GITHUB_*` environment variables; empty when not running in Actions.
"""
function workflow_provenance()
    haskey(ENV, "GITHUB_RUN_ID") && haskey(ENV, "GITHUB_REPOSITORY") || return ""
    server = get(ENV, "GITHUB_SERVER_URL", "https://github.com")
    url = "$server/$(ENV["GITHUB_REPOSITORY"])/actions/runs/$(ENV["GITHUB_RUN_ID"])"
    actor = haskey(ENV, "GITHUB_ACTOR") ? ", triggered by @$(ENV["GITHUB_ACTOR"])" : ""
    return "\nCreated by [this workflow run]($url)$actor.\n"
end

"""
    create_update_pr(name, new_version; dry_run=false) -> Union{String,Nothing}

The full pipeline: update the recipe for `name` to `new_version`, commit it
on a fresh branch, push that branch to the bot's fork (`\$YGGDRASIL_FORK`,
an `owner/repo` slug), and open a PR against JuliaPackaging/Yggdrasil.
Returns the PR URL.

The commit author defaults to git's own configuration; set
`\$NORN_GIT_NAME`/`\$NORN_GIT_EMAIL` to override it. Authentication is
delegated entirely to `gh`: set `GH_TOKEN` to the bot account's token (and
run `gh auth setup-git`) so both the push and the PR creation act as the bot.

With `dry_run=true`, stops after applying the update: prints the diff,
restores the working tree, and returns `nothing`.
"""
function create_update_pr(name::AbstractString, new_version::VersionNumber;
                          dry_run::Bool=false)
    root = ensure_clone!()
    branch = "urdarbrunnr/$(lowercase(name))"
    git(root, "checkout", "--quiet", "-B", branch, "origin/master")

    recipe_path = find_recipe(root, name)
    recipe = parse_recipe(recipe_path)
    recipe.version == new_version &&
        error("$(recipe.name) is already at $new_version")

    @info "Updating $(recipe.name): $(recipe.version) → $new_version"
    write(recipe_path, update_recipe(recipe, new_version))

    @info "Validating the updated recipe with --meta-json"
    try
        validate_recipe(recipe_path, new_version)
    catch
        git(root, "checkout", "--quiet", "--", ".")
        rethrow()
    end

    if dry_run
        run(pipeline(`git -C $root --no-pager diff`, stdout))
        git(root, "checkout", "--quiet", "--", ".")
        git(root, "checkout", "--quiet", "master")
        return nothing
    end

    fork = get(ENV, "YGGDRASIL_FORK") do
        error("no fork configured: set YGGDRASIL_FORK to the bot's owner/repo slug")
    end

    title = "[$(recipe.name)] Update to v$new_version"
    body = """
    Update $(recipe.name) from v$(recipe.version) to v$new_version.

    This pull request was generated automatically by [Urdarbrunnr](https://github.com/mbauman/Urdarbrunnr).
    """ * workflow_provenance()
    author = String[]
    haskey(ENV, "NORN_GIT_NAME") && append!(author, ["-c", "user.name=$(ENV["NORN_GIT_NAME"])"])
    haskey(ENV, "NORN_GIT_EMAIL") && append!(author, ["-c", "user.email=$(ENV["NORN_GIT_EMAIL"])"])
    git(root, author..., "commit", "--quiet", "--all", "--message", title)
    git(root, "push", "--force", "https://github.com/$fork.git", "$branch:$branch")

    fork_owner = first(split(fork, '/'))
    url = readchomp(setenv(`gh pr create --repo JuliaPackaging/Yggdrasil
                            --head $fork_owner:$branch
                            --title $title --body $body`; dir=root))
    @info "Opened $url"
    return url
end
