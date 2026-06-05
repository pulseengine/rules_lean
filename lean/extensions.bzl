"Module extensions for Lean 4 toolchain and Mathlib."

load("//lean/private:repo.bzl", "ALL_PLATFORMS", "lean_release", "lean_toolchains_hub", "mathlib_repo")

_KNOWN_VERSIONS = {
    "4.27.0": {
        "sha256": {
            "darwin_aarch64": "01e7d9130464bc7d847baece07dfb2c4f48dd02e71b4b9a77d484914ea594efb",
            "darwin_x86_64": "e4ca541d86881c35497cb6e6c1a21358f03a4b2cfb2e8d4e14e58dc2a0a805ae",
            "linux_x86_64": "056e2dc8564fc064a801e69f3eb18c044b9b546bc8b0e5a2c00247f8a1cb8ce6",
            "linux_aarch64": "b256eec276baaaccc3eb3fa64d7ccff64f710b7caa074f305ba95e0013ad31e7",
        },
    },
    "4.29.1": {
        "sha256": {
            "darwin_aarch64": "73bccb392ca7d8ab3d62a1e328bb7d057815f088dbdbfb6574f194ae505797af",
            "darwin_x86_64": "3585ab34d20c53cf915169aa5c0d2efbd9993a78b9dc08516641510eef08fab0",
            "linux_x86_64": "bf062d29556d655685fb287563c249ad6a8fde34352c18b5e32568a595c1aec1",
            "linux_aarch64": "1ccdfb7f924901f4b73a4b4eb169e5b3dc74f6836521b47e733ea25f2abfc0dc",
        },
    },
}

def _detect_host_platform(module_ctx):
    os_name = module_ctx.os.name.lower()
    os_arch = module_ctx.os.arch.lower()

    if "mac" in os_name or "darwin" in os_name:
        if "aarch64" in os_arch or "arm64" in os_arch:
            return "darwin_aarch64"
        return "darwin_x86_64"
    elif "linux" in os_name:
        if "aarch64" in os_arch or "arm64" in os_arch:
            return "linux_aarch64"
        return "linux_x86_64"
    else:
        fail("Unsupported host platform: {} {}".format(os_name, os_arch))

_LeanToolchainTag = tag_class(attrs = {
    "version": attr.string(mandatory = True, doc = "Lean 4 version (e.g. '4.27.0')"),
    "sha256": attr.string_dict(default = {}, doc = "Per-platform SHA-256 overrides (keys: darwin_aarch64, etc.)"),
    "require_hashes": attr.bool(default = True, doc = "Fail if any platform hash is empty. Set False for development with unreleased versions."),
})

_LeanMathlibTag = tag_class(attrs = {
    "rev": attr.string(
        default = "",
        doc = "Mathlib4 git tag (e.g. 'v4.27.0') or commit SHA. " +
              "Empty defaults to 'v' + the active toolchain version.",
    ),
})

# Mathlib release tags follow the "v{lean_version}" convention.
def _required_lean_from_rev(rev):
    """Derive the Lean version a Mathlib rev requires.

    Returns (lean_version | None, is_sha):
      - "v4.29.1"      -> ("4.29.1", False)
      - "v4.29.1-rc1"  -> ("4.29.1", False)   # pre-release suffix dropped
      - 40-char hex    -> (None, True)        # bare SHA: version not inferable
    """
    lowered = rev.lower()
    is_sha = len(rev) == 40 and all([c in "0123456789abcdef" for c in lowered.elems()])
    if is_sha:
        return None, True
    base = rev[1:] if rev.startswith("v") else rev
    return base.split("-")[0], False

def _lean_impl(module_ctx):
    # ── Toolchain ────────────────────────────────────────────────────────
    # Root module's declaration takes precedence over dependencies.
    version = None
    sha256_overrides = {}
    require_hashes = True

    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            if version == None or mod.is_root:
                version = tag.version
                sha256_overrides = dict(tag.sha256)
                require_hashes = tag.require_hashes

    if version == None:
        fail("lean.toolchain(version = ...) is required")

    known = _KNOWN_VERSIONS.get(version, {})
    known_sha256 = known.get("sha256", {})

    for platform in ALL_PLATFORMS:
        sha256 = sha256_overrides.get(platform, known_sha256.get(platform, ""))
        if require_hashes and not sha256:
            fail(
                "SHA-256 hash missing for lean {version} on {platform}. ".format(
                    version = version,
                    platform = platform,
                ) +
                "Provide sha256 = {\"" + platform + "\": \"<hash>\"} in lean.toolchain(), " +
                "or set require_hashes = False for development use only.",
            )
        lean_release(
            name = "lean_" + platform,
            version = version,
            platform = platform,
            sha256 = sha256,
        )

    lean_toolchains_hub(
        name = "lean_toolchains",
        platforms = ALL_PLATFORMS,
    )

    # ── Mathlib (optional) ───────────────────────────────────────────────
    host_platform = _detect_host_platform(module_ctx)

    # Select ONE Mathlib rev with the same root-precedence rule as the toolchain
    # loop above: the root module wins, so a consumer can always override a
    # dependency's pinned rev. Declaring `mathlib` more than once per extension
    # with differing attrs is otherwise a hard Bazel "repo already generated"
    # error, so collapsing to a single declaration is also required for
    # correctness, not just hygiene.
    # mathlib is "wanted" if ANY module declares a tag, but the rev is taken
    # ONLY from the root module. A dependency (e.g. rules_lean's own
    # MODULE.bazel, which pins a rev for its own examples) must NOT impose that
    # rev on a consumer that picked a different toolchain — doing so is exactly
    # the skew that breaks downstream builds. When the root gives no rev, the
    # rev defaults to the tag matching the active toolchain (below).
    mathlib_wanted = False
    mathlib_rev = None
    for mod in module_ctx.modules:
        for tag in mod.tags.mathlib:
            mathlib_wanted = True
            if mod.is_root and tag.rev:
                mathlib_rev = tag.rev

    if mathlib_wanted:
        # Bug #3: never let an empty rev reach lake as `@ ""` — lake resolves
        # that to mathlib4 HEAD, which tracks the newest Lean and is guaranteed
        # to skew against any pinned toolchain. Default to the matching tag.
        if not mathlib_rev:
            mathlib_rev = "v" + version
            # buildifier: disable=print
            print("lean.mathlib: no root rev given; defaulting to '{}' to match lean.toolchain({}).".format(
                mathlib_rev,
                version,
            ))

        # Bug #2 (LS-001 mitigation): fail LOUDLY on Lean↔Mathlib skew BEFORE
        # the fetch. A mismatched pair makes lake try to switch toolchains via
        # Elan (absent in a hermetic build), surfacing as the undiscoverable
        # "info: no Elan detected" deep inside `lake update`.
        required_lean, is_sha = _required_lean_from_rev(mathlib_rev)
        if is_sha:
            # buildifier: disable=print
            print("lean.mathlib(rev = '{}') is a bare commit SHA; cannot verify it matches lean.toolchain({}).".format(
                mathlib_rev,
                version,
            ))
        elif required_lean != version:
            fail(
                ("Lean/Mathlib version skew: lean.mathlib(rev = '{rev}') requires Lean " +
                 "'{req}', but the active lean.toolchain is '{ver}'. Mismatched versions " +
                 "produce incompatible oleans and make lake attempt an Elan toolchain " +
                 "switch, which fails later with a cryptic error deep inside the fetch.\n" +
                 "To fix, align lean.toolchain and lean.mathlib:\n" +
                 "  - set lean.toolchain(version = '{req}') to match the Mathlib rev, or\n" +
                 "  - pin lean.mathlib(rev = 'v{ver}') to match the toolchain.").format(
                    rev = mathlib_rev,
                    req = required_lean,
                    ver = version,
                ),
            )

        mathlib_repo(
            name = "mathlib",
            host_platform = host_platform,
            lean_version = version,
            mathlib_rev = mathlib_rev,
        )

lean = module_extension(
    implementation = _lean_impl,
    tag_classes = {
        "toolchain": _LeanToolchainTag,
        "mathlib": _LeanMathlibTag,
    },
)
