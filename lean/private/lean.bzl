"Core Lean 4 rule implementations."

LeanInfo = provider(
    doc = "Information about a compiled Lean 4 library.",
    fields = {
        "srcs": "Source .lean files (list of Files)",
        "stamp": "Verification stamp file (File or None)",
        "lib_dir": "Directory containing .olean files (File - tree artifact, or None)",
        "lean_path_entries": "Directories to add to LEAN_PATH (list of strings)",
        "all_files": "All files needed as action inputs (depset of Files)",
        "transitive_stamps": "All dependency verification stamps (depset of Files)",
    },
)

def _lean_prefix(toolchain):
    """Compute the Lean installation prefix from the lean binary path."""
    parts = toolchain.lean.path.split("/")
    return "/".join(parts[:-2])

def _collect_dep_info(deps):
    """Collect LEAN_PATH entries, files, and stamps from LeanInfo deps."""
    lean_path_entries = []
    dep_files = []
    direct_stamps = []
    transitive_stamp_depsets = []

    for dep in deps:
        if LeanInfo in dep:
            info = dep[LeanInfo]
            lean_path_entries.extend(info.lean_path_entries)
            dep_files.extend(info.all_files.to_list())
            if info.stamp:
                direct_stamps.append(info.stamp)
            transitive_stamp_depsets.append(info.transitive_stamps)

    return (
        lean_path_entries,
        dep_files,
        depset(direct = direct_stamps, transitive = transitive_stamp_depsets),
    )

# ── lean_library ─────────────────────────────────────────────────────────────

def _lean_library_impl(ctx):
    toolchain = ctx.toolchains["//lean:toolchain_type"].lean_toolchain_info

    out_dir = ctx.actions.declare_directory(ctx.label.name + ".oleans")
    stamp = ctx.actions.declare_file(ctx.label.name + ".verified")

    dep_path_entries, dep_files, transitive_stamps = _collect_dep_info(ctx.attr.deps)

    prefix = _lean_prefix(toolchain)
    stdlib_path = prefix + "/lib/lean/library"

    # LEAN_PATH: stdlib + deps + output dir (for intra-library imports)
    all_entries = [stdlib_path] + dep_path_entries + [out_dir.path]
    lean_path_str = ":".join(all_entries)

    # Package prefix for computing .olean relative paths
    pkg = ctx.label.package
    pkg_prefix = pkg + "/" if pkg else ""

    extra = " ".join(ctx.attr.extra_flags)

    lines = [
        "#!/bin/bash",
        "set -euo pipefail",
        "",
    ]

    for src in ctx.files.srcs:
        rel = src.short_path
        if rel.startswith(pkg_prefix):
            rel = rel[len(pkg_prefix):]
        olean_rel = rel[:-5] + ".olean"  # strip ".lean" suffix
        olean_path = out_dir.path + "/" + olean_rel

        lines.append("mkdir -p $(dirname {op})".format(op = olean_path))
        if extra:
            lines.append('"{lean}" {extra} "{src}" -o "{op}"'.format(
                lean = toolchain.lean.path,
                extra = extra,
                src = src.path,
                op = olean_path,
            ))
        else:
            lines.append('"{lean}" "{src}" -o "{op}"'.format(
                lean = toolchain.lean.path,
                src = src.path,
                op = olean_path,
            ))

    lines.extend(["", 'touch "{s}"'.format(s = stamp.path)])

    # Write script to file and execute via ctx.actions.run (not run_shell)
    # to avoid Bazel 8's strict input path validation in run_shell.
    script = ctx.actions.declare_file(ctx.label.name + "_compile.sh")
    ctx.actions.write(script, "\n".join(lines), is_executable = True)

    ctx.actions.run(
        executable = script,
        inputs = depset(ctx.files.srcs + dep_files + toolchain.all_files),
        outputs = [out_dir, stamp],
        env = {"LEAN_PATH": lean_path_str},
        mnemonic = "LeanCompile",
        progress_message = "Compiling Lean library %s" % ctx.label,
        execution_requirements = {"no-sandbox": "1"},
    )

    return [
        DefaultInfo(files = depset([stamp])),
        LeanInfo(
            srcs = ctx.files.srcs,
            stamp = stamp,
            lib_dir = out_dir,
            lean_path_entries = [out_dir.path],
            all_files = depset([out_dir, stamp]),
            transitive_stamps = transitive_stamps,
        ),
    ]

lean_library = rule(
    implementation = _lean_library_impl,
    doc = "Compiles Lean 4 source files and produces .olean outputs.",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".lean"],
            mandatory = True,
            doc = "Lean source files, listed in compilation order.",
        ),
        "deps": attr.label_list(
            providers = [LeanInfo],
            doc = "Other lean_library or lean_prebuilt_library targets.",
        ),
        "extra_flags": attr.string_list(
            default = [],
            doc = "Additional flags passed to the lean compiler.",
        ),
    },
    toolchains = ["//lean:toolchain_type"],
    provides = [LeanInfo],
)

# ── lean_proof_test ──────────────────────────────────────────────────────────

def _lean_proof_test_impl(ctx):
    toolchain = ctx.toolchains["//lean:toolchain_type"].lean_toolchain_info

    stamp = ctx.actions.declare_file(ctx.label.name + ".verified")

    dep_path_entries, dep_files, _ = _collect_dep_info(ctx.attr.deps)

    prefix = _lean_prefix(toolchain)
    stdlib_path = prefix + "/lib/lean/library"

    all_entries = [stdlib_path] + dep_path_entries
    lean_path_str = ":".join(all_entries)

    extra = " ".join(ctx.attr.extra_flags)

    lines = [
        "#!/bin/bash",
        "set -euo pipefail",
        "",
        "PASS=0",
        "FAIL=0",
        "",
    ]

    for src in ctx.files.srcs:
        cmd = '"{lean}"'.format(lean = toolchain.lean.path)
        if extra:
            cmd += " " + extra
        cmd += ' "{src}"'.format(src = src.path)

        lines.extend([
            'echo "Checking {sp}..."'.format(sp = src.short_path),
            "if {cmd}; then".format(cmd = cmd),
            '    echo "  PASS"',
            "    PASS=$((PASS + 1))",
            "else",
            '    echo "  FAIL"',
            "    FAIL=$((FAIL + 1))",
            "fi",
            "",
        ])

    lines.extend([
        'echo ""',
        'echo "Results: $PASS passed, $FAIL failed"',
        "",
        'if [ "$FAIL" -gt 0 ]; then',
        "    exit 1",
        "fi",
        "",
        'touch "{s}"'.format(s = stamp.path),
    ])

    script = ctx.actions.declare_file(ctx.label.name + "_check.sh")
    ctx.actions.write(script, "\n".join(lines), is_executable = True)

    ctx.actions.run(
        executable = script,
        inputs = depset(ctx.files.srcs + dep_files + toolchain.all_files),
        outputs = [stamp],
        env = {"LEAN_PATH": lean_path_str},
        mnemonic = "LeanProofCheck",
        progress_message = "Verifying Lean proofs %s" % ctx.label,
        execution_requirements = {"no-sandbox": "1"},
    )

    runner = ctx.actions.declare_file(ctx.label.name + "_runner.sh")
    ctx.actions.write(
        runner,
        "#!/bin/bash\necho 'All Lean proofs in {label} verified successfully.'\n".format(
            label = str(ctx.label),
        ),
        is_executable = True,
    )

    return [DefaultInfo(
        executable = runner,
        runfiles = ctx.runfiles(files = [stamp]),
    )]

lean_proof_test = rule(
    implementation = _lean_proof_test_impl,
    doc = "Verifies that Lean 4 source files typecheck (proofs are valid).",
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".lean"],
            mandatory = True,
            doc = "Lean source files to verify.",
        ),
        "deps": attr.label_list(
            providers = [LeanInfo],
            doc = "Other lean_library or lean_prebuilt_library targets.",
        ),
        "extra_flags": attr.string_list(
            default = [],
            doc = "Additional flags passed to the lean compiler.",
        ),
    },
    test = True,
    toolchains = ["//lean:toolchain_type"],
)

# ── lean_prebuilt_library ────────────────────────────────────────────────────

def _lean_prebuilt_library_impl(ctx):
    files = ctx.files.srcs
    marker = ctx.file.path_marker

    lean_path_entry = marker.dirname if marker else ""

    return [
        DefaultInfo(files = depset(files)),
        LeanInfo(
            srcs = [],
            stamp = None,
            lib_dir = None,
            lean_path_entries = [lean_path_entry] if lean_path_entry else [],
            all_files = depset(files + ([marker] if marker else [])),
            transitive_stamps = depset(),
        ),
    ]

lean_prebuilt_library = rule(
    implementation = _lean_prebuilt_library_impl,
    doc = "Wraps pre-built .olean files (e.g. Mathlib) as a Lean dependency.",
    attrs = {
        "srcs": attr.label_list(
            allow_files = True,
            mandatory = True,
            doc = "Pre-built .olean and related files.",
        ),
        "path_marker": attr.label(
            allow_single_file = True,
            doc = "Marker file at the root of the .olean directory tree.",
        ),
    },
    provides = [LeanInfo],
)
