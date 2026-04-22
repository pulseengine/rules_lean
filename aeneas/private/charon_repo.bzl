"""Repository rules for downloading Charon and its matching Rust sysroot.

Charon is AeneasVerif's Rust→LLBC translator. It ships two binaries:

* `charon`       — front-end CLI (statically linked OCaml on macOS).
* `charon-driver` — a rustc driver that dynamically links `librustc_driver`
                   from a matching nightly Rust sysroot.

This rule downloads both the Charon tarball and a matching Rust toolchain
(rustc + rust-std + rustc-dev) from `static.rust-lang.org`, bundles them into
one repository, and exposes the pieces via `charon_toolchain_info`.

### Linux aarch64 (known limitation)

Upstream Charon does NOT publish a `linux-aarch64` tarball. Downloading the
toolchain for that platform therefore fails with a clear error message. Users
on `linux_aarch64` can either:

  * compile Charon from source themselves and provide a local repository
    override, or
  * use `rules_lean`'s Nix track instead (`bazel_dep` on the charon overlay
    provided by Track B), which builds from source via Nix.

### Sysroot / env-var notes

The Charon binary is built via Nix in CI and therefore looks for `rustc` in
`PATH` (guarded by the `CHARON_TOOLCHAIN_IS_IN_PATH` env variable) instead of
invoking `rustup`. Downstream `charon_llbc` build rules (not part of this file)
should set:

    CHARON_TOOLCHAIN_IS_IN_PATH=1
    PATH=<rust_bin_path>:$PATH
    DYLD_LIBRARY_PATH=<rust_lib_path>   # macOS (for librustc_driver-*.dylib)
    LD_LIBRARY_PATH=<rust_lib_path>     # Linux (for librustc_driver-*.so)

The `charon version` smoke test only touches the outer `charon` wrapper and
does NOT need the sysroot — that test passes on a fresh download alone.
"""

# Platform identifiers used throughout rules_lean / aeneas.
ALL_CHARON_PLATFORMS = [
    "macos_aarch64",
    "macos_x86_64",
    "linux_x86_64",
    "linux_aarch64",  # included for registry completeness; download fails fast
]

# Platforms that actually have a published Charon prebuilt.
CHARON_SUPPORTED_PLATFORMS = [
    "macos_aarch64",
    "macos_x86_64",
    "linux_x86_64",
]

_PLATFORM_CONSTRAINTS = {
    "macos_aarch64": '"@platforms//os:macos", "@platforms//cpu:aarch64"',
    "macos_x86_64": '"@platforms//os:macos", "@platforms//cpu:x86_64"',
    "linux_x86_64": '"@platforms//os:linux", "@platforms//cpu:x86_64"',
    "linux_aarch64": '"@platforms//os:linux", "@platforms//cpu:aarch64"',
}

# Charon tarball suffixes.
_CHARON_ARTIFACT = {
    "macos_aarch64": "macos-aarch64",
    "macos_x86_64": "macos-x86_64",
    "linux_x86_64": "linux-x86_64",
}

# Host triples for `static.rust-lang.org` nightly downloads.
_RUST_TRIPLE = {
    "macos_aarch64": "aarch64-apple-darwin",
    "macos_x86_64": "x86_64-apple-darwin",
    "linux_x86_64": "x86_64-unknown-linux-gnu",
}

# ── charon_release ───────────────────────────────────────────────────────────

_CHARON_BUILD_FILE = """\
load("@rules_lean//aeneas:toolchain.bzl", "charon_toolchain_info")

package(default_visibility = ["//visibility:public"])

filegroup(name = "charon_bin", srcs = ["charon"])
filegroup(name = "charon_driver_bin", srcs = ["charon-driver"])

filegroup(
    name = "rust_sysroot_files",
    srcs = glob(["rust_sysroot/**"]),
)

filegroup(
    name = "all_files",
    srcs = glob(["**"], exclude = [".scratch/**"]),
)

charon_toolchain_info(
    name = "charon_toolchain_info",
    charon = ":charon_bin",
    charon_driver = ":charon_driver_bin",
    all_files = ":all_files",
    rust_sysroot = ":rust_sysroot_files",
    rust_sysroot_path = "rust_sysroot",
    rust_bin_path = "rust_sysroot/bin",
    rust_lib_path = "rust_sysroot/lib",
    rust_channel = "{channel}",
    version = "{version}",
)
"""

def _extract_rust_component(rctx, url, sha256, tmp_name, strip_components, target_dir):
    """Download a Rust component tarball and extract it into target_dir.

    The tarballs nest content under `<component>-<v>-<triple>/<component>/...`
    (or an additional `lib/` layer for rust-std). `rctx.download_and_extract` +
    a separate merge step has been observed to silently drop `.rlib` files on
    some hosts (see rules_verus/verus/private/repo.bzl:186-196), so we download
    to a temp file and untar manually with `--strip-components`.
    """
    rctx.download(url = url, output = tmp_name, sha256 = sha256)
    extract = rctx.execute([
        "tar",
        "-xf",
        tmp_name,
        "-C",
        target_dir,
        "--strip-components={}".format(strip_components),
    ])
    if extract.return_code != 0:
        fail("Failed to extract {}:\n{}".format(tmp_name, extract.stderr))
    rctx.execute(["rm", tmp_name])

def _charon_release_impl(rctx):
    platform = rctx.attr.platform
    version = rctx.attr.version
    rust_version = rctx.attr.rust_version

    if platform == "linux_aarch64":
        # Keep the repository materialisable (so `bazel query` works) but
        # refuse to produce usable binaries. Users will see this message when
        # the repository is actually *built* rather than just enumerated.
        rctx.file(
            "charon",
            "#!/bin/sh\n" +
            "echo 'ERROR: Charon has no linux_aarch64 prebuilt (see docs/charon-integration.md).' >&2\n" +
            "exit 1\n",
            executable = True,
        )
        rctx.file("charon-driver", "", executable = True)
        rctx.execute(["mkdir", "-p", "rust_sysroot/bin", "rust_sysroot/lib"])
        rctx.file(
            "BUILD.bazel",
            _CHARON_BUILD_FILE.format(
                channel = rctx.attr.rust_channel,
                version = version,
            ),
        )
        return

    artifact = _CHARON_ARTIFACT.get(platform)
    if not artifact:
        fail("Unsupported platform for charon_release: {}".format(platform))

    charon_sha = rctx.attr.sha256
    charon_url = "https://github.com/AeneasVerif/charon/releases/download/{tag}/charon-{a}.tar.gz".format(
        tag = version,
        a = artifact,
    )

    # Step 1: download the Charon tarball (contains only `charon` and
    # `charon-driver` at the top level).
    rctx.download_and_extract(
        url = charon_url,
        sha256 = charon_sha if charon_sha else "",
    )
    rctx.execute(["chmod", "+x", "charon"])
    rctx.execute(["chmod", "+x", "charon-driver"])
    if "macos" in platform:
        rctx.execute(["xattr", "-cr", "."], quiet = True)

    # Step 2: download + assemble the Rust sysroot for this target.
    triple = _RUST_TRIPLE[platform]
    rust_hashes = rctx.attr.rust_sha256

    def _require_hash(key):
        val = rust_hashes.get(key, "")
        if not val and rctx.attr.require_hashes:
            fail(
                "SHA-256 missing for Rust component '{}' on {}. ".format(key, platform) +
                "Provide rust_sha256 = {\"" + key + "\": \"<hash>\"} or set " +
                "require_hashes = False for local development.",
            )
        return val

    # rustc component (contains rustc binary + librustc_driver + lib/rustlib).
    # Top-level layout inside the tarball:
    #   rustc-<v>-<triple>/rustc/{bin,lib,share}
    # strip_components=2 drops both the outer dir and the "rustc" subdir so we
    # end up with bin/, lib/, share/ directly under rust_sysroot/.
    rctx.execute(["mkdir", "-p", "rust_sysroot"])
    rustc_url = "https://static.rust-lang.org/dist/{date}/rustc-nightly-{t}.tar.xz".format(
        date = rust_version,
        t = triple,
    )
    _extract_rust_component(
        rctx,
        url = rustc_url,
        sha256 = _require_hash("rustc_" + platform),
        tmp_name = "rustc.tar.xz",
        strip_components = 2,
        target_dir = "rust_sysroot",
    )

    # rust-std component (libstd/libcore/liballoc etc. under
    # lib/rustlib/<triple>/lib/*.rlib). Layout:
    #   rust-std-<v>-<triple>/rust-std-<triple>/lib/...
    # strip_components=2 lines it up alongside the rustc component.
    rust_std_url = "https://static.rust-lang.org/dist/{date}/rust-std-nightly-{t}.tar.xz".format(
        date = rust_version,
        t = triple,
    )
    _extract_rust_component(
        rctx,
        url = rust_std_url,
        sha256 = _require_hash("rust_std_" + platform),
        tmp_name = "rust-std.tar.xz",
        strip_components = 2,
        target_dir = "rust_sysroot",
    )

    # rustc-dev component (charon-driver links against librustc_driver which
    # lives here — NOT in the plain `rustc` component for this nightly).
    # Layout: rustc-dev-<v>-<triple>/rustc-dev/lib/...
    rustc_dev_url = "https://static.rust-lang.org/dist/{date}/rustc-dev-nightly-{t}.tar.xz".format(
        date = rust_version,
        t = triple,
    )
    _extract_rust_component(
        rctx,
        url = rustc_dev_url,
        sha256 = _require_hash("rustc_dev_" + platform),
        tmp_name = "rustc-dev.tar.xz",
        strip_components = 2,
        target_dir = "rust_sysroot",
    )

    # rust-src component is architecture-independent. Charon asks for it in
    # its rust-toolchain manifest, so bundle it too.
    rust_src_url = "https://static.rust-lang.org/dist/{date}/rust-src-nightly.tar.xz".format(
        date = rust_version,
    )
    _extract_rust_component(
        rctx,
        url = rust_src_url,
        sha256 = _require_hash("rust_src"),
        tmp_name = "rust-src.tar.xz",
        strip_components = 2,
        target_dir = "rust_sysroot",
    )

    # Sanity-check the sysroot is usable.
    verify_libcore = rctx.execute(["sh", "-c",
        "ls rust_sysroot/lib/rustlib/{t}/lib/libcore-*.rlib 2>/dev/null | head -1".format(t = triple),
    ])
    if verify_libcore.return_code != 0 or not verify_libcore.stdout.strip():
        debug = rctx.execute(["find", "rust_sysroot/lib/rustlib", "-maxdepth", "4", "-type", "d"])
        fail("Rust sysroot for {} missing libcore. Contents:\n{}".format(triple, debug.stdout[:1000]))

    # librustc_driver lives either in lib/ (Linux .so) or lib/ (macOS .dylib).
    driver_glob = "librustc_driver-*.so" if "linux" in platform else "librustc_driver-*.dylib"
    verify_driver = rctx.execute(["sh", "-c",
        "ls rust_sysroot/lib/{} 2>/dev/null | head -1".format(driver_glob),
    ])
    if verify_driver.return_code != 0 or not verify_driver.stdout.strip():
        debug = rctx.execute(["sh", "-c", "ls rust_sysroot/lib/ 2>&1 | head -40"])
        fail(
            "Rust sysroot for {} missing librustc_driver (charon-driver will not load).\n".format(triple) +
            "rust_sysroot/lib contents:\n{}".format(debug.stdout),
        )

    rctx.file(
        "BUILD.bazel",
        _CHARON_BUILD_FILE.format(
            channel = rctx.attr.rust_channel,
            version = version,
        ),
    )

charon_release = repository_rule(
    implementation = _charon_release_impl,
    doc = "Downloads a Charon release plus a matching nightly Rust sysroot.",
    attrs = {
        "version": attr.string(
            mandatory = True,
            doc = "Charon release tag, e.g. 'build-2026.04.22.081730-<sha>'.",
        ),
        "platform": attr.string(
            mandatory = True,
            values = ALL_CHARON_PLATFORMS,
        ),
        "sha256": attr.string(
            default = "",
            doc = "SHA-256 of the Charon tarball (empty only with require_hashes=False).",
        ),
        "rust_version": attr.string(
            mandatory = True,
            doc = "Nightly date component (e.g. '2026-02-07') used in static.rust-lang.org URLs.",
        ),
        "rust_channel": attr.string(
            mandatory = True,
            doc = "Full channel name (e.g. 'nightly-2026-02-07'), stored in the provider for downstream use.",
        ),
        "rust_sha256": attr.string_dict(
            default = {},
            doc = "SHA-256 hashes keyed by 'rustc_<plat>', 'rust_std_<plat>', 'rustc_dev_<plat>', 'rust_src'.",
        ),
        "require_hashes": attr.bool(
            default = True,
            doc = "Fail the repository rule if any needed hash is empty.",
        ),
    },
)

# ── charon_toolchains_hub ────────────────────────────────────────────────────

def _charon_toolchains_hub_impl(rctx):
    lines = ['package(default_visibility = ["//visibility:public"])', ""]
    for p in rctx.attr.platforms:
        lines.append(
            """toolchain(
    name = "{p}",
    exec_compatible_with = [{c}],
    toolchain = "@charon_{p}//:charon_toolchain_info",
    toolchain_type = "@rules_lean//aeneas:charon_toolchain_type",
)
""".format(p = p, c = _PLATFORM_CONSTRAINTS[p]),
        )
    rctx.file("BUILD.bazel", "\n".join(lines))

charon_toolchains_hub = repository_rule(
    implementation = _charon_toolchains_hub_impl,
    doc = "Hub repository that registers platform-specific Charon toolchains.",
    attrs = {
        "platforms": attr.string_list(mandatory = True),
    },
)
