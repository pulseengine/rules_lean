"Module extension for Aeneas + Charon toolchains."

load(
    "//aeneas/private:charon_repo.bzl",
    "ALL_CHARON_PLATFORMS",
    "charon_release",
    "charon_toolchains_hub",
)
load(
    "//aeneas/private:repo.bzl",
    "ALL_AENEAS_PLATFORMS",
    "aeneas_lean_lib",
    "aeneas_release",
    "aeneas_toolchains_hub",
)

# Registry of known Charon releases. Keys are upstream release tags. Each entry
# carries the Charon tarball hashes (per rules_lean platform slug) plus the
# matching Rust toolchain channel/date and the hashes for each Rust component.
#
# To add a new entry:
#   1. Find a release at https://github.com/AeneasVerif/charon/releases .
#   2. Read `charon/rust-toolchain` at the pinned git commit to get the Rust
#      nightly date and the required components.
#   3. Run:
#        curl -sL <charon-tarball-url> | sha256sum
#        curl -sL https://static.rust-lang.org/dist/<date>/<component>.tar.xz | sha256sum
#      for each component and platform.
_KNOWN_CHARON_VERSIONS = {
    # Aeneas pins commit bb585116362158a68b2633ce871951d520a50e13 (2026-04-21).
    # That SHA is not itself released as a Charon tarball, so we use the
    # closest prior published release (2026-04-22) — functionally equivalent
    # because no commits landed between the two timestamps that affect the
    # LLBC output format.
    "build-2026.04.22.081730-2d35584fb79ef804c50f106d8c40bd3728284f8d": {
        "charon_sha256": {
            "macos_aarch64": "8668c8d7e1954277401380748b7f3772628a5bee8f96b630ec69fe7cf5f1f671",
            "macos_x86_64": "790145f58acda4e2ffa3c483c6259aa7f3e905f1f04f39490c1727719467bce2",
            "linux_x86_64": "1a212a1e0bd02bda22e429fa8029e715948ace82dfe523f53b349b80ddf39524",
            # linux_aarch64: no prebuilt published upstream.
        },
        "rust_channel": "nightly-2026-02-07",
        "rust_version": "2026-02-07",
        "rust_sha256": {
            "rustc_macos_aarch64": "2e50bef1a29c0d4de66198c71b2f7ce907a954df91a11241b62f03cfe431c69d",
            "rust_std_macos_aarch64": "09bb0b959b990351ae3b78db170498a320f8ed921f34ba812c70d77b8eddb21d",
            "rustc_dev_macos_aarch64": "1047e6b72b5ec12e8524b8a00f73719aa1b863349a790a139fbffabb52fba860",
            "rustc_macos_x86_64": "8530d915b6135030369868d886f71c2dad8fe850a64227d9d3d66e30fcce1b64",
            "rust_std_macos_x86_64": "f984c016a20d017a61935111477a73ba282da758b67db96be1388b91c8747059",
            "rustc_dev_macos_x86_64": "304d769a7112a642fcdb1fcd18da370e00b0bbb43f373d6d387a5a3e010b60df",
            "rustc_linux_x86_64": "2783e4113d9b0ee465a07ef83c436f92ab789f73c14699c09e003a14b04000ac",
            "rust_std_linux_x86_64": "166c55a1e0450e4f7709da70f2053a844f438088b95ce97dd67923143fe38782",
            "rustc_dev_linux_x86_64": "931939b8a53eae8cc3f4c5c80399af2c2d481b26fcd5399773ca2b59b11282cb",
            "rust_src": "65a35eb3b9a96888b73d243c89b228092149e546ee10ce752e816d75ba2defe1",
        },
    },
}

def _detect_host_platform(module_ctx):
    os_name = module_ctx.os.name.lower()
    os_arch = module_ctx.os.arch.lower()

    if "mac" in os_name or "darwin" in os_name:
        if "aarch64" in os_arch or "arm64" in os_arch:
            return "macos_aarch64"
        return "macos_x86_64"
    elif "linux" in os_name:
        if "aarch64" in os_arch or "arm64" in os_arch:
            return "linux_aarch64"
        return "linux_x86_64"
    else:
        fail("Unsupported host platform for Aeneas: {} {}".format(os_name, os_arch))

_AeneasToolchainTag = tag_class(attrs = {
    "version": attr.string(mandatory = True, doc = "Aeneas release tag"),
    "rev": attr.string(mandatory = True, doc = "Aeneas git commit hash (for lean lib source)"),
    "lean_version": attr.string(mandatory = True, doc = "Lean 4 version the lib should be built with"),
    "sha256": attr.string_dict(default = {}, doc = "Per-platform SHA-256 overrides"),
})

_CharonToolchainTag = tag_class(attrs = {
    "version": attr.string(
        mandatory = True,
        doc = "Charon release tag (e.g. 'build-2026.04.22.081730-<sha>').",
    ),
    "rust_version": attr.string(
        default = "",
        doc = "Override the Rust nightly date (e.g. '2026-02-07'). " +
              "If empty, the registry entry for `version` is used.",
    ),
    "rust_channel": attr.string(
        default = "",
        doc = "Override the Rust channel name (e.g. 'nightly-2026-02-07'). " +
              "If empty, the registry entry for `version` is used.",
    ),
    "charon_sha256": attr.string_dict(
        default = {},
        doc = "Per-platform SHA-256 overrides for the Charon tarball " +
              "(keys: macos_aarch64, macos_x86_64, linux_x86_64).",
    ),
    "rust_sha256": attr.string_dict(
        default = {},
        doc = "Per-component Rust SHA-256 overrides " +
              "(keys: rustc_<plat>, rust_std_<plat>, rustc_dev_<plat>, rust_src).",
    ),
    "require_hashes": attr.bool(
        default = True,
        doc = "Fail if any needed SHA-256 is empty. Set False for development.",
    ),
})

def _aeneas_impl(module_ctx):
    # ── Aeneas ───────────────────────────────────────────────────────────
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

    if version != None:
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

        lean_platform_map = {
            "macos_aarch64": "darwin_aarch64",
            "macos_x86_64": "darwin_x86_64",
            "linux_x86_64": "linux_x86_64",
            "linux_aarch64": "linux_aarch64",
        }

        aeneas_lean_lib(
            name = "aeneas_lean_lib",
            host_platform = lean_platform_map[host_platform],
            lean_version = lean_version,
            aeneas_rev = rev,
        )

    # ── Charon ───────────────────────────────────────────────────────────
    charon_version = None
    charon_rust_version = None
    charon_rust_channel = None
    charon_sha_overrides = {}
    charon_rust_sha_overrides = {}
    charon_require_hashes = True

    for mod in module_ctx.modules:
        for tag in mod.tags.charon_toolchain:
            if charon_version == None or mod.is_root:
                charon_version = tag.version
                charon_rust_version = tag.rust_version
                charon_rust_channel = tag.rust_channel
                charon_sha_overrides = dict(tag.charon_sha256)
                charon_rust_sha_overrides = dict(tag.rust_sha256)
                charon_require_hashes = tag.require_hashes

    if charon_version != None:
        known = _KNOWN_CHARON_VERSIONS.get(charon_version, {})
        known_charon_sha = known.get("charon_sha256", {})
        known_rust_sha = known.get("rust_sha256", {})
        rust_version = charon_rust_version or known.get("rust_version", "")
        rust_channel = charon_rust_channel or known.get("rust_channel", "")

        if charon_require_hashes and not rust_version:
            fail(
                "charon.toolchain(version='{}') has no rust_version override " .format(charon_version) +
                "and is not in _KNOWN_CHARON_VERSIONS. Provide rust_version explicitly " +
                "or set require_hashes = False.",
            )
        if charon_require_hashes and not rust_channel:
            fail(
                "charon.toolchain(version='{}') has no rust_channel override " .format(charon_version) +
                "and is not in _KNOWN_CHARON_VERSIONS. Provide rust_channel explicitly " +
                "or set require_hashes = False.",
            )

        # Merge registry hashes with per-module overrides.
        merged_rust_sha = dict(known_rust_sha)
        for k, v in charon_rust_sha_overrides.items():
            merged_rust_sha[k] = v

        for platform in ALL_CHARON_PLATFORMS:
            if platform == "linux_aarch64":
                # Fail-fast stub repo — no hashes needed, no downloads performed.
                charon_release(
                    name = "charon_" + platform,
                    version = charon_version,
                    platform = platform,
                    sha256 = "",
                    rust_version = rust_version or "unused",
                    rust_channel = rust_channel or "unused",
                    rust_sha256 = {},
                    require_hashes = False,
                )
                continue

            charon_sha = charon_sha_overrides.get(
                platform,
                known_charon_sha.get(platform, ""),
            )
            if charon_require_hashes and not charon_sha:
                fail(
                    "SHA-256 missing for charon tarball on {}. ".format(platform) +
                    "Provide charon_sha256 = {\"" + platform + "\": \"<hash>\"} " +
                    "or set require_hashes = False.",
                )

            charon_release(
                name = "charon_" + platform,
                version = charon_version,
                platform = platform,
                sha256 = charon_sha,
                rust_version = rust_version,
                rust_channel = rust_channel,
                rust_sha256 = merged_rust_sha,
                require_hashes = charon_require_hashes,
            )

        charon_toolchains_hub(
            name = "charon_toolchains",
            platforms = ALL_CHARON_PLATFORMS,
        )

aeneas = module_extension(
    implementation = _aeneas_impl,
    tag_classes = {
        "toolchain": _AeneasToolchainTag,
        "charon_toolchain": _CharonToolchainTag,
    },
)
