"Implementation of charon_llbc: Rust → LLBC translation via Charon."

CharonLlbcInfo = provider(
    doc = "Information about a Charon-produced LLBC file.",
    fields = {
        "llbc_file": "The .llbc output (File)",
        "crate_name": "The crate name used during translation (string)",
    },
)

def _resolve_crate_root(ctx):
    if ctx.file.crate_root:
        return ctx.file.crate_root
    for src in ctx.files.srcs:
        if src.basename == "lib.rs":
            return src
    if not ctx.files.srcs:
        fail("charon_llbc requires at least one source file")
    return ctx.files.srcs[0]

def _resolve_crate_name(ctx):
    if ctx.attr.crate_name:
        return ctx.attr.crate_name
    return ctx.label.name.replace("-", "_")

def _charon_llbc_impl(ctx):
    toolchain = ctx.toolchains["//aeneas:charon_toolchain_type"].charon_toolchain_info

    crate_root = _resolve_crate_root(ctx)
    crate_name = _resolve_crate_name(ctx)

    llbc_out = ctx.actions.declare_file(ctx.label.name + ".llbc")

    extra_flags = " ".join(['"%s"' % f for f in ctx.attr.extra_flags])
    rustc_args = " ".join(['"%s"' % a for a in ctx.attr.rustc_args])

    # The charon wrapper invokes charon-driver (a rustc driver) which links
    # librustc_driver-<hash>.{dylib,so} at @rpath. Setting DYLD_LIBRARY_PATH
    # / LD_LIBRARY_PATH to the bundled sysroot lets it resolve. PATH is set
    # so CHARON_TOOLCHAIN_IS_IN_PATH=1 finds `rustc` in the same sysroot
    # instead of invoking rustup.
    script_content = """\
#!/bin/bash
set -euo pipefail

CHARON="{charon}"
TOOLCHAIN_DIR=$(dirname "$CHARON")
SYSROOT="$(cd "$TOOLCHAIN_DIR/rust_sysroot" 2>/dev/null && pwd)" || SYSROOT="$TOOLCHAIN_DIR/rust_sysroot"

export CHARON_TOOLCHAIN_IS_IN_PATH=1
export PATH="$SYSROOT/bin:$PATH"

case "$(uname)" in
    Darwin) export DYLD_LIBRARY_PATH="$SYSROOT/lib:${{DYLD_LIBRARY_PATH:-}}" ;;
    *)      export LD_LIBRARY_PATH="$SYSROOT/lib:${{LD_LIBRARY_PATH:-}}" ;;
esac

"$CHARON" rustc --preset={preset} --dest-file "{output}" {extra_flags} \\
    -- --edition=2021 --crate-type lib --crate-name "{crate_name}" {rustc_args} \\
    "{crate_root}"
""".format(
        charon = toolchain.charon.path,
        preset = ctx.attr.preset,
        output = llbc_out.path,
        crate_root = crate_root.path,
        crate_name = crate_name,
        extra_flags = extra_flags,
        rustc_args = rustc_args,
    )

    script = ctx.actions.declare_file(ctx.label.name + "_charon.sh")
    ctx.actions.write(
        output = script,
        content = script_content,
        is_executable = True,
    )

    inputs = depset(ctx.files.srcs + toolchain.all_files)

    ctx.actions.run(
        executable = script,
        inputs = inputs,
        outputs = [llbc_out],
        mnemonic = "CharonLlbc",
        progress_message = "Translating %s to LLBC with Charon" % ctx.label,
    )

    return [
        DefaultInfo(files = depset([llbc_out])),
        CharonLlbcInfo(
            llbc_file = llbc_out,
            crate_name = crate_name,
        ),
    ]

charon_llbc = rule(
    implementation = _charon_llbc_impl,
    doc = """Translates Rust source files to LLBC via Charon.

    Output: a single `<name>.llbc` file suitable as input to `aeneas_translate`.

    Example:
        charon_llbc(
            name = "my_crate",
            srcs = ["src/lib.rs"],
            # crate_name defaults to target name
            # crate_root defaults to lib.rs in srcs, or srcs[0]
        )

        aeneas_translate(
            name = "my_crate_lean",
            srcs = [":my_crate"],
        )
    """,
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".rs"],
            mandatory = True,
            doc = "Rust source files to translate. The crate root must be among them.",
        ),
        "crate_root": attr.label(
            allow_single_file = [".rs"],
            doc = "Explicit crate root. Defaults to lib.rs in srcs, or srcs[0].",
        ),
        "crate_name": attr.string(
            doc = "Crate name. Defaults to the target name with hyphens as underscores.",
        ),
        "preset": attr.string(
            default = "aeneas",
            values = ["aeneas", "eurydice", "soteria", "raw-mir", "old-defaults", "tests"],
            doc = "Charon output preset. 'aeneas' matches the Aeneas Lean backend.",
        ),
        "extra_flags": attr.string_list(
            default = [],
            doc = "Extra flags to pass to `charon rustc` (before the `--` separator).",
        ),
        "rustc_args": attr.string_list(
            default = [],
            doc = "Extra flags to pass to rustc (after the `--` separator).",
        ),
    },
    toolchains = ["//aeneas:charon_toolchain_type"],
    provides = [CharonLlbcInfo],
)
