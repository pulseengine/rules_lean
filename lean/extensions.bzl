"Module extensions for Lean 4 toolchain and Mathlib."

load("//lean/private:repo.bzl", "ALL_PLATFORMS", "lean_release", "lean_toolchains_hub", "mathlib_repo")

_KNOWN_VERSIONS = {
    "4.27.0": {
        "sha256": {
            "darwin_aarch64": "01e7d9130464bc7d847baece07dfb2c4f48dd02e71b4b9a77d484914ea594efb",
            "darwin_x86_64": "e4ca541d86881c35497cb6e6c1a21358f03a4b2cfb2e8d4e14e58dc2a0a805ae",
            "linux_x86_64": "056e2dc8564fc064a801e69f3eb18c044b9b546bc8b0e5a2c00247f8a1cb8ce6",
            "linux_aarch64": "fe229059c9050ccf79111a4ba8ea1ebbcb8d3b06075cfee1a57edb97544d4e2a",
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
})

_LeanMathlibTag = tag_class(attrs = {
    "rev": attr.string(mandatory = True, doc = "Mathlib4 git revision or tag (e.g. 'v4.27.0')"),
})

def _lean_impl(module_ctx):
    # ── Toolchain ────────────────────────────────────────────────────────
    # Root module's declaration takes precedence over dependencies.
    version = None
    sha256_overrides = {}

    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            if version == None or mod.is_root:
                version = tag.version
                sha256_overrides = dict(tag.sha256)

    if version == None:
        fail("lean.toolchain(version = ...) is required")

    known = _KNOWN_VERSIONS.get(version, {})
    known_sha256 = known.get("sha256", {})

    for platform in ALL_PLATFORMS:
        sha256 = sha256_overrides.get(platform, known_sha256.get(platform, ""))
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

    for mod in module_ctx.modules:
        for tag in mod.tags.mathlib:
            mathlib_repo(
                name = "mathlib",
                host_platform = host_platform,
                lean_version = version,
                mathlib_rev = tag.rev,
            )

lean = module_extension(
    implementation = _lean_impl,
    tag_classes = {
        "toolchain": _LeanToolchainTag,
        "mathlib": _LeanMathlibTag,
    },
)
