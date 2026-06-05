"Aeneas and Charon toolchain providers and rules."

AeneasToolchainInfo = provider(
    doc = "Information about an Aeneas installation.",
    fields = {
        "aeneas": "The aeneas binary (File)",
        "all_files": "All toolchain files (list of Files)",
        "lean_lib": "Aeneas Lean support library oleans (list of Files)",
        "lean_lib_path": "Path to the Lean support library directory (string)",
        "version": "Aeneas version string (commit hash or tag)",
    },
)

def _aeneas_toolchain_info_impl(ctx):
    toolchain_info = AeneasToolchainInfo(
        aeneas = ctx.file.aeneas,
        all_files = ctx.files.all_files,
        lean_lib = ctx.files.lean_lib,
        lean_lib_path = ctx.attr.lean_lib_path,
        version = ctx.attr.version,
    )
    return [platform_common.ToolchainInfo(
        aeneas_toolchain_info = toolchain_info,
    )]

aeneas_toolchain_info = rule(
    implementation = _aeneas_toolchain_info_impl,
    attrs = {
        "aeneas": attr.label(allow_single_file = True, mandatory = True),
        "all_files": attr.label(mandatory = True),
        "lean_lib": attr.label(mandatory = True),
        "lean_lib_path": attr.string(default = ""),
        "version": attr.string(mandatory = True),
    },
    provides = [platform_common.ToolchainInfo],
)

# ── Charon toolchain ─────────────────────────────────────────────────────────

CharonToolchainInfo = provider(
    doc = "Information about a Charon installation (Rust → LLBC translator).",
    fields = {
        "charon": "The charon driver binary (File)",
        "charon_driver": "The charon-driver rustc plugin (File)",
        "all_files": "All Charon + sysroot files (list of Files)",
        "rust_sysroot": "Bundled Rust sysroot files (list of Files)",
        "rust_sysroot_path": "Repo-relative path to the Rust sysroot root (string)",
        "rust_bin_path": "Repo-relative path to rust_sysroot/bin (containing rustc) (string)",
        "rust_lib_path": "Repo-relative path to rust_sysroot/lib (for LD_LIBRARY_PATH/DYLD_LIBRARY_PATH) (string)",
        "rust_channel": "The pinned Rust toolchain channel (e.g. 'nightly-2026-02-07')",
        "version": "Charon release tag / version string",
    },
)

def _charon_toolchain_info_impl(ctx):
    toolchain_info = CharonToolchainInfo(
        charon = ctx.file.charon,
        charon_driver = ctx.file.charon_driver,
        all_files = ctx.files.all_files,
        rust_sysroot = ctx.files.rust_sysroot,
        rust_sysroot_path = ctx.attr.rust_sysroot_path,
        rust_bin_path = ctx.attr.rust_bin_path,
        rust_lib_path = ctx.attr.rust_lib_path,
        rust_channel = ctx.attr.rust_channel,
        version = ctx.attr.version,
    )
    return [platform_common.ToolchainInfo(
        charon_toolchain_info = toolchain_info,
    )]

charon_toolchain_info = rule(
    implementation = _charon_toolchain_info_impl,
    attrs = {
        "charon": attr.label(allow_single_file = True, mandatory = True),
        "charon_driver": attr.label(allow_single_file = True, mandatory = True),
        "all_files": attr.label(mandatory = True),
        "rust_sysroot": attr.label(mandatory = True),
        "rust_sysroot_path": attr.string(default = "rust_sysroot"),
        "rust_bin_path": attr.string(default = "rust_sysroot/bin"),
        "rust_lib_path": attr.string(default = "rust_sysroot/lib"),
        "rust_channel": attr.string(mandatory = True),
        "version": attr.string(mandatory = True),
    },
    provides = [platform_common.ToolchainInfo],
)
