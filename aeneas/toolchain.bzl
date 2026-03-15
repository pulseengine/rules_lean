"Aeneas toolchain provider and rule."

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
