"Lean 4 toolchain provider and rule."

LeanToolchainInfo = provider(
    doc = "Information about a Lean 4 toolchain installation.",
    fields = {
        "lean": "The lean compiler binary (File)",
        "leanc": "The lean C backend compiler (File)",
        "lake": "The lake build system binary (File)",
        "all_files": "All toolchain files including stdlib (list of Files)",
        "version": "Lean version string",
    },
)

def _lean_toolchain_info_impl(ctx):
    toolchain_info = LeanToolchainInfo(
        lean = ctx.file.lean,
        leanc = ctx.file.leanc,
        lake = ctx.file.lake,
        all_files = ctx.files.all_files,
        version = ctx.attr.version,
    )
    return [platform_common.ToolchainInfo(
        lean_toolchain_info = toolchain_info,
    )]

lean_toolchain_info = rule(
    implementation = _lean_toolchain_info_impl,
    attrs = {
        "lean": attr.label(allow_single_file = True, mandatory = True),
        "leanc": attr.label(allow_single_file = True, mandatory = True),
        "lake": attr.label(allow_single_file = True, mandatory = True),
        "all_files": attr.label(mandatory = True),
        "version": attr.string(mandatory = True),
    },
    provides = [platform_common.ToolchainInfo],
)
