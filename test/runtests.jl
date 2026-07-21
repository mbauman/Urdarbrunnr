using Urdarbrunnr
using Test

const FIXTURES = joinpath(@__DIR__, "fixtures")

@testset "Urdarbrunnr" begin

@testset "parse_recipe: ArchiveSource recipe" begin
    recipe = parse_recipe(joinpath(FIXTURES, "Z", "Zstd", "build_tarballs.jl"))
    @test recipe.name == "Zstd"
    @test recipe.version == v"1.5.6"
    @test length(recipe.sources) == 1
    src = only(recipe.sources)
    @test src.kind == :ArchiveSource
    @test src.url == "https://github.com/facebook/zstd/releases/download/v1.5.6/zstd-1.5.6.tar.gz"
    @test src.hash == "8c29e06cf42aacc1eafc4077ae2ec6c6fcb96a626157e0593d5e82a34fd403c1"
end

@testset "parse_recipe: GitSource + static FileSource" begin
    recipe = parse_recipe(joinpath(FIXTURES, "L", "LibGit", "build_tarballs.jl"))
    @test recipe.name == "LibGit"
    @test recipe.version == v"2.3.4"
    @test [s.kind for s in recipe.sources] == [:GitSource, :FileSource]
    @test recipe.sources[1].url == "https://github.com/example/libgit.git"
    @test recipe.sources[2].url == "https://example.com/static/config-file.txt"
end

@testset "parse_recipe: rejects what it can't handle" begin
    @test_throws ErrorException Urdarbrunnr.parse_recipe_text("""
        name = "Foo"
        version = VersionNumber(get(ENV, "FOO_VERSION", "1.0.0"))
        sources = []
        """)
    @test_throws ErrorException Urdarbrunnr.parse_recipe_text("""
        name = "Foo"
        version = v"1.0.0"
        sources = [ArchiveSource("https://example.com/foo.tar.gz", some_hash_variable)]
        """)
    @test_throws ErrorException Urdarbrunnr.parse_recipe_text("""
        version = v"1.0.0"
        """) # no name
end

@testset "render_url" begin
    recipe = parse_recipe(joinpath(FIXTURES, "Z", "Zstd", "build_tarballs.jl"))
    src = only(recipe.sources)
    @test render_url(src.url_expr; version=v"1.5.7", name="Zstd") ==
        "https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz"
    # Plain strings pass through untouched
    @test render_url("https://example.com/x.tar.gz"; version=v"9.9.9") ==
        "https://example.com/x.tar.gz"
    # Major/minor style interpolation
    expr = Meta.parse("\"https://example.com/foo-\$(version.major).\$(version.minor).tar.gz\"")
    @test render_url(expr; version=v"3.4.5") == "https://example.com/foo-3.4.tar.gz"
    # References to unknown variables fail loudly
    bad = Meta.parse("\"https://example.com/\$(mystery)/foo.tar.gz\"")
    @test_throws ErrorException render_url(bad; version=v"1.0.0")
end

@testset "update_recipe: archive" begin
    recipe = parse_recipe(joinpath(FIXTURES, "Z", "Zstd", "build_tarballs.jl"))
    fetched = String[]
    fake_hash = url -> (push!(fetched, url); "f"^64)
    text = update_recipe(recipe, v"1.5.7"; archive_hash=fake_hash)

    @test occursin("version = v\"1.5.7\"", text)
    @test !occursin("v\"1.5.6\"", text)
    @test occursin("\"$("f"^64)\"", text)
    @test !occursin(recipe.sources[1].hash, text)
    @test fetched == ["https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz"]
    # Everything else is untouched — same number of lines, script intact
    @test occursin("cd \$WORKSPACE/srcdir/zstd-*/", text)
    @test count(==('\n'), text) == count(==('\n'), recipe.text)

    # The updated text reparses to the new version
    updated = Urdarbrunnr.parse_recipe_text(text)
    @test updated.version == v"1.5.7"

    # Refuses downgrades and no-ops
    @test_throws ErrorException update_recipe(recipe, v"1.5.6"; archive_hash=fake_hash)
    @test_throws ErrorException update_recipe(recipe, v"1.5.5"; archive_hash=fake_hash)
end

@testset "update_recipe: git + static file source" begin
    recipe = parse_recipe(joinpath(FIXTURES, "L", "LibGit", "build_tarballs.jl"))
    resolved = []
    fake_commit = (url, commit, cur, new) -> (push!(resolved, (url, commit, cur, new)); "e"^40)
    fake_hash = url -> error("static FileSource URL should not be re-fetched")
    text = update_recipe(recipe, v"2.4.0"; archive_hash=fake_hash, git_commit=fake_commit)

    @test occursin("version = v\"2.4.0\"", text)
    @test occursin("\"$("e"^40)\"", text)
    @test !occursin("0123456789abcdef0123456789abcdef01234567", text)
    # Static FileSource hash untouched
    @test occursin("aaaabbbbccccddddeeeeffff0000111122223333444455556666777788889999", text)
    @test resolved == [("https://github.com/example/libgit.git",
                        "0123456789abcdef0123456789abcdef01234567", v"2.3.4", v"2.4.0")]
end

@testset "parse_ls_remote" begin
    tags = Urdarbrunnr.parse_ls_remote("""
        $("1"^40)\trefs/tags/v1.5.6
        $("2"^40)\trefs/tags/v1.5.7
        $("3"^40)\trefs/tags/v2.0.0
        $("4"^40)\trefs/tags/v2.0.0^{}
        $("5"^40)\trefs/heads/not-a-tag
        """)
    @test tags == [(tag="v1.5.6", commit="1"^40),
                   (tag="v1.5.7", commit="2"^40),
                   (tag="v2.0.0", commit="4"^40)]  # peeled commit wins for annotated tags
    @test Urdarbrunnr.parse_ls_remote("") == []
end

@testset "derive_tag_commit" begin
    derive = Urdarbrunnr.derive_tag_commit
    mktags(pairs...) = [(tag=String(t), commit=String(c)) for (t, c) in pairs]

    # Plain v-prefix scheme
    tags = mktags("v1.5.6" => "a"^40, "v1.5.7" => "b"^40)
    @test derive(tags, "a"^40, v"1.5.6", v"1.5.7") == "b"^40

    # Bare version tags
    tags = mktags("1.5.6" => "a"^40, "1.5.7" => "b"^40)
    @test derive(tags, "a"^40, v"1.5.6", v"1.5.7") == "b"^40

    # Arbitrary prefix is preserved verbatim
    tags = mktags("release-1.2.3" => "a"^40, "release-1.2.4" => "b"^40,
                  "v1.2.4" => "c"^40)  # decoy in a different scheme
    @test derive(tags, "a"^40, v"1.2.3", v"1.2.4") == "b"^40

    # Underscore separators
    tags = mktags("FOO_1_2_3" => "a"^40, "FOO_1_2_4" => "b"^40)
    @test derive(tags, "a"^40, v"1.2.3", v"1.2.4") == "b"^40

    # Two-component tags for patch-zero versions, in both directions
    tags = mktags("v2.1" => "a"^40, "v2.2" => "b"^40, "v2.2.1" => "c"^40)
    @test derive(tags, "a"^40, v"2.1.0", v"2.2.0") == "b"^40
    @test derive(tags, "a"^40, v"2.1.0", v"2.2.1") == "c"^40

    # Current commit isn't tagged at all
    tags = mktags("v1.0.0" => "a"^40)
    @test_throws "cannot infer the tag naming scheme" derive(tags, "f"^40, v"1.0.0", v"1.1.0")

    # Current tag doesn't contain the current version
    tags = mktags("some-random-tag" => "a"^40)
    @test_throws "do not contain the current version" derive(tags, "a"^40, v"1.0.0", v"1.1.0")

    # The new version simply isn't tagged yet
    tags = mktags("v1.0.0" => "a"^40)
    err = try derive(tags, "a"^40, v"1.0.0", v"1.1.0"); nothing catch e e end
    @test err isa ErrorException
    @test occursin("tried: v1.1.0", err.msg)
end

@testset "validate_recipe" begin
    # validate_recipe just runs `julia <script> --meta-json`, so stub scripts
    # cover the plumbing without BinaryBuilder's load time
    mktempdir() do dir
        ok = joinpath(dir, "build_tarballs.jl")
        json = "{\"name\":\"Foo\",\"version\":\"1.2.3\"}"
        write(ok, "println($(repr(json)))")
        @test validate_recipe(ok, v"1.2.3") === nothing
        @test_throws "does not mention" validate_recipe(ok, v"1.2.4")

        bad = joinpath(dir, "bad.jl")
        write(bad, """error("boom")""")
        err = try validate_recipe(bad, v"1.2.3"); nothing catch e e end
        @test err isa ErrorException
        @test occursin("boom", err.msg)
    end

    # And the real thing: run the Zstd fixture through BinaryBuilder itself
    @test validate_recipe(joinpath(FIXTURES, "Z", "Zstd", "build_tarballs.jl"), v"1.5.6") === nothing
end

@testset "workflow_provenance" begin
    withenv("GITHUB_RUN_ID" => "12345", "GITHUB_REPOSITORY" => "mbauman/Urdarbrunnr",
            "GITHUB_ACTOR" => "mbauman", "GITHUB_SERVER_URL" => nothing) do
        prov = Urdarbrunnr.workflow_provenance()
        @test occursin("(https://github.com/mbauman/Urdarbrunnr/actions/runs/12345)", prov)
        @test occursin("triggered by @mbauman", prov)
    end
    # Actor is optional
    withenv("GITHUB_RUN_ID" => "12345", "GITHUB_REPOSITORY" => "mbauman/Urdarbrunnr",
            "GITHUB_ACTOR" => nothing) do
        prov = Urdarbrunnr.workflow_provenance()
        @test occursin("actions/runs/12345", prov)
        @test !occursin("triggered by", prov)
    end
    # Outside of GitHub Actions: contributes nothing to the PR body
    withenv("GITHUB_RUN_ID" => nothing, "GITHUB_REPOSITORY" => nothing) do
        @test Urdarbrunnr.workflow_provenance() == ""
    end
end

@testset "find_recipe" begin
    @test find_recipe(FIXTURES, "Zstd") == joinpath(FIXTURES, "Z", "Zstd", "build_tarballs.jl")
    @test find_recipe(FIXTURES, "zstd") == joinpath(FIXTURES, "Z", "Zstd", "build_tarballs.jl")
    @test_throws ErrorException find_recipe(FIXTURES, "NoSuchProject")
end

end
