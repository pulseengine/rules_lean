"""Shared helper for fetching mathlib4 without a full-history clone.

Both `mathlib_repo` (lean/private/repo.bzl) and `aeneas_lean_lib`
(aeneas/private/repo.bzl) need mathlib4, and lake's `require ... from git`
resolver always does an unshallowed `git clone` of the ~2 GB monorepo (no
`--depth` knob), which times out on a cold cache. This helper shallow-fetches
exactly the pinned rev and is consumed by both rules so the fix lives in one
place.
"""

MATHLIB_GIT_URL = "https://github.com/leanprover-community/mathlib4.git"

def shallow_fetch_mathlib(rctx, rev, dest = "mathlib4_src"):
    """Shallow `git fetch --depth 1` mathlib4 at `rev` into `dest`.

    Keeps `.git` AND an `origin` remote, both REQUIRED because Mathlib's
    `lake exe cache get` runs `git remote get-url origin` to pick the olean
    cache bucket and `git rev-parse HEAD` to key it. The `git init` + `fetch
    <rev>` + `checkout FETCH_HEAD` form accepts both tags and bare SHAs (unlike
    `git clone --branch`). Fails loudly on any git error or a bad rev.

    Returns the absolute path to the checkout (str), suitable for a lake
    `require mathlib from "<path>"`.
    """
    src = rctx.path(dest)

    init = rctx.execute(["git", "init", "-q", str(src)])
    if init.return_code != 0:
        fail("git init for mathlib4 checkout failed:\n" + init.stderr)

    remote = rctx.execute(["git", "-C", str(src), "remote", "add", "origin", MATHLIB_GIT_URL])
    if remote.return_code != 0:
        fail("git remote add origin for mathlib4 failed:\n" + remote.stderr)

    fetch = rctx.execute(
        ["git", "-C", str(src), "fetch", "--depth", "1", "--no-tags", "origin", rev],
        # Defense-in-depth: a single shallow tree is fast, but keep a generous
        # ceiling for slow networks / large single trees.
        timeout = 3600,
        quiet = False,
    )
    if fetch.return_code != 0:
        fail("shallow `git fetch` of mathlib4 @ '{}' failed:\n{}".format(rev, fetch.stderr))

    checkout = rctx.execute(["git", "-C", str(src), "checkout", "-q", "FETCH_HEAD"])
    if checkout.return_code != 0:
        fail("`git checkout FETCH_HEAD` for mathlib4 @ '{}' failed:\n{}".format(rev, checkout.stderr))

    # Sanity-check the checkout looks like mathlib before lake touches it, so a
    # bad/force-moved rev fails here with a clear message rather than deep inside
    # `lake update`. mathlib4 ships a lakefile.lean (older) or lakefile.toml.
    has_lakefile = rctx.path(str(src) + "/lakefile.lean").exists or \
                   rctx.path(str(src) + "/lakefile.toml").exists
    if not has_lakefile:
        fail("mathlib4 @ '{}' has no lakefile.lean/.toml after checkout — bad rev?".format(rev))

    return str(src)

def rewrite_git_require_to_local(rctx, lakefile_path, dep_name, local_path):
    """Rewrite a lake `require <dep> from git ... @ "..."` (2-line form) in an
    existing lakefile to `require <dep> from "<local_path>"`.

    Used to redirect a dependency that a downloaded lakefile pins via git (e.g.
    aeneas's `backends/lean/lakefile.lean` requiring mathlib) onto a local
    shallow checkout, so `lake update` never re-clones it.
    """
    content = rctx.read(lakefile_path)
    marker = "require {} from git".format(dep_name)
    idx = content.find(marker)
    if idx == -1:
        fail("could not find `{}` in {} — lakefile format changed?".format(marker, lakefile_path))

    # The require spans two lines: the marker line, then `  "<url>" @ "<rev>"`.
    end_of_line1 = content.find("\n", idx)
    end_of_line2 = content.find("\n", end_of_line1 + 1)
    if end_of_line1 == -1 or end_of_line2 == -1:
        fail("unexpected `{}` layout in {}".format(marker, lakefile_path))

    new_content = (
        content[:idx] +
        'require {} from "{}"'.format(dep_name, local_path) +
        content[end_of_line2:]
    )
    rctx.file(lakefile_path, new_content)
