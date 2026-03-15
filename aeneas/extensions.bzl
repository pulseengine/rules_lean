"Module extension for Aeneas toolchain."

load("//aeneas/private:repo.bzl", "ALL_AENEAS_PLATFORMS", "aeneas_lean_lib", "aeneas_release", "aeneas_toolchains_hub")

def _detect_host_platform(module_ctx):
    os_name = module_ctx.os.name.lower()
    os_arch = module_ctx.os.arch.lower()

    if "mac" in os_name or "darwin" in os_name:
        if "aarch64" in os_arch or "arm64" in os_arch:
            return "macos_aarch64"
        return "macos_x86_64"
    elif "linux" in os_name:
        return "linux_x86_64"
    else:
        fail("Unsupported host platform for Aeneas: {} {}".format(os_name, os_arch))

_AeneasToolchainTag = tag_class(attrs = {
    "version": attr.string(mandatory = True, doc = "Aeneas release tag"),
    "rev": attr.string(mandatory = True, doc = "Aeneas git commit hash (for lean lib source)"),
    "lean_version": attr.string(mandatory = True, doc = "Lean 4 version the lib should be built with"),
    "sha256": attr.string_dict(default = {}, doc = "Per-platform SHA-256 overrides"),
})

def _aeneas_impl(module_ctx):
    version = None
    rev = None
    lean_version = None
    sha256_overrides = {}

    for mod in module_ctx.modules:
        for tag in mod.tags.toolchain:
            if version == None or mod.is_root:
                version = tag.version
                rev = tag.rev
                lean_version = tag.lean_version
                sha256_overrides = dict(tag.sha256)

    if version == None:
        return

    for platform in ALL_AENEAS_PLATFORMS:
        sha256 = sha256_overrides.get(platform, "")
        aeneas_release(
            name = "aeneas_" + platform,
            version = version,
            platform = platform,
            sha256 = sha256,
        )

    aeneas_toolchains_hub(
        name = "aeneas_toolchains",
        platforms = ALL_AENEAS_PLATFORMS,
    )

    # Build the Aeneas Lean support library
    host_platform = _detect_host_platform(module_ctx)

    # Determine which lean repo to use (from the lean extension)
    lean_platform_map = {
        "macos_aarch64": "darwin_aarch64",
        "macos_x86_64": "darwin_x86_64",
        "linux_x86_64": "linux_x86_64",
    }
    lean_repo = "lean_" + lean_platform_map[host_platform]

    aeneas_lean_lib(
        name = "aeneas_lean_lib",
        lean_repo = lean_repo,
        lean_version = lean_version,
        aeneas_rev = rev,
    )

aeneas = module_extension(
    implementation = _aeneas_impl,
    tag_classes = {
        "toolchain": _AeneasToolchainTag,
    },
)
