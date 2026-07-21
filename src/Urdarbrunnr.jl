"""
    Urdarbrunnr

The well at the roots of [Yggdrasil](https://github.com/JuliaPackaging/Yggdrasil).

Tools for creating automated pull requests that update simple
`build_tarballs.jl` recipes to new upstream versions. The scope is
deliberately narrow: recipes with a literal `version = v"..."` and sources
whose URLs are plain strings or interpolate `version`. Anything fancier
(computed versions, patch series that need rebasing, etc.) is rejected
loudly rather than updated wrongly.
"""
module Urdarbrunnr

using Downloads: Downloads
using SHA: sha256

export Recipe, parse_recipe, find_recipe, render_url, update_recipe,
       archive_sha256, resolve_git_tag, validate_recipe, create_update_pr

include("recipe.jl")
include("sources.jl")
include("pullrequest.jl")

end # module
