"Core Aeneas rule implementations."

load("//lean/private:lean.bzl", "LeanInfo")

AeneasInfo = provider(
    doc = "Information about Aeneas-translated Lean files.",
    fields = {
        "lean_srcs": "Generated .lean source files (list of Files)",
        "llbc_file": "The LLBC intermediate file (File or None)",
    },
)

def _aeneas_translate_impl(ctx):
    toolchain = ctx.toolchains["//aeneas:toolchain_type"].aeneas_toolchain_info

    out_dir = ctx.actions.declare_directory(ctx.label.name + ".lean_out")

    lines = [
        "#!/bin/bash",
        "set -euo pipefail",
        "",
        'AENEAS="{aeneas}"'.format(aeneas = toolchain.aeneas.path),
    ]

    extra = " ".join(ctx.attr.extra_flags)

    for llbc in ctx.files.srcs:
        cmd = '"$AENEAS" -backend lean -dest "{out}"'.format(out = out_dir.path)
        if extra:
            cmd += " " + extra
        cmd += ' "{src}"'.format(src = llbc.path)
        lines.append(cmd)

    ctx.actions.run_shell(
        inputs = ctx.files.srcs + toolchain.all_files,
        outputs = [out_dir],
        command = "\n".join(lines),
        mnemonic = "AeneasTranslate",
        progress_message = "Translating LLBC to Lean via Aeneas %s" % ctx.label,
        use_default_shell_env = False,
    )

    return [
        DefaultInfo(files = depset([out_dir])),
        AeneasInfo(
            lean_srcs = [out_dir],
            llbc_file = ctx.files.srcs[0] if ctx.files.srcs else None,
        ),
    ]

aeneas_translate = rule(
    implementation = _aeneas_translate_impl,
    doc = "Translates LLBC files to Lean 4 source files using Aeneas.",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".llbc"],
            mandatory = True,
            doc = "LLBC files produced by Charon.",
        ),
        "extra_flags": attr.string_list(
            default = [],
            doc = "Additional flags passed to aeneas (e.g. ['-split-files']).",
        ),
    },
    toolchains = ["//aeneas:toolchain_type"],
    provides = [AeneasInfo],
)

def aeneas_verified_library(
        name,
        llbc_srcs,
        proof_srcs = [],
        lean_deps = [],
        aeneas_flags = [],
        extra_lean_flags = [],
        **kwargs):
    """Convenience macro: translate LLBC → Lean, compile, and optionally verify proofs.

    Args:
        name: Target name.
        llbc_srcs: LLBC files to translate.
        proof_srcs: Hand-written Lean proof files about the translated code.
        lean_deps: Additional lean_library or lean_prebuilt_library deps.
        aeneas_flags: Extra flags for aeneas (e.g. ["-split-files"]).
        extra_lean_flags: Extra flags for the lean compiler.
        **kwargs: Passed through to all generated targets.
    """
    translate_name = name + "_translated"
    compiled_name = name + "_compiled"

    native.filegroup(
        name = translate_name + "_llbc",
        srcs = llbc_srcs,
    )

    aeneas_translate(
        name = translate_name,
        srcs = [translate_name + "_llbc"],
        extra_flags = aeneas_flags,
        **{k: v for k, v in kwargs.items() if k in ["visibility", "tags", "testonly"]}
    )

    # The translated lean files + aeneas support library
    all_deps = lean_deps + ["@aeneas_lean_lib//:Aeneas"]

    native.alias(
        name = name,
        actual = translate_name,
        **{k: v for k, v in kwargs.items() if k in ["visibility", "tags", "testonly"]}
    )
