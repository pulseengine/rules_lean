"Core Lean 4 rule implementations."

LeanInfo = provider(
    doc = "Information about a compiled Lean 4 library.",
    fields = {
        "srcs": "Source .lean files (list of Files)",
        "stamp": "Verification stamp file (File or None)",
        "oleans": "Compiled .olean files (list of Files)",
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

# lean_proof_test's per-file check. Lean exits 0 on `sorry` (it is a warning),
# so the exit code alone cannot carry "proved". This script fails on:
#   - a non-zero lean exit;
#   - any "declaration uses `sorry`" warning (either quote style), unless allow_sorry = True;
#   - a theorem named in axiom_checks that depends on an axiom outside
#     allowed_axioms, or that `#print axioms` did not report at all.
# Args: lean src stamp display allow_sorry allowed_csv theorems_csv [extra flags...]
_PROOF_CHECK_SH = """#!/bin/bash
set -uo pipefail
lean="$1"; src="$2"; stamp="$3"; shown="$4"; allow_sorry="$5"; allowed="$6"; theorems="$7"
shift 7
out="$("$lean" "$@" "$src" 2>&1)"; rc=$?
printf '%s\\n' "$out"
if [ "$rc" -ne 0 ]; then echo "lean_proof_test: $shown: lean exited $rc" >&2; exit "$rc"; fi
if [ "$allow_sorry" != 1 ] && printf '%s\\n' "$out" | grep -qE "declaration uses .sorry."; then
  echo "lean_proof_test: $shown: a declaration uses 'sorry' (set allow_sorry = True to accept)" >&2
  exit 1
fi
fail=0
want=()
[ -z "$theorems" ] || IFS=, read -r -a want <<< "$theorems"
for t in ${want[@]+"${want[@]}"}; do
  [ -n "$t" ] || continue
  line="$(printf '%s\\n' "$out" | grep -F "'$t' " | grep -E "depends on axioms|does not depend on any axioms" | head -1)"
  if [ -z "$line" ]; then
    echo "lean_proof_test: $shown: no axiom report for $t (is the name right?)" >&2; fail=1; continue
  fi
  case "$line" in *"does not depend on any axioms"*) continue ;; esac
  used="$(printf '%s' "$line" | sed -e 's/.*depends on axioms: \\[//' -e 's/\\].*//')"
  IFS=, read -r -a axs <<< "$used"
  for a in "${axs[@]}"; do
    a="$(printf '%s' "$a" | tr -d ' ')"
    case ",$allowed," in *",$a,"*) ;; *) echo "lean_proof_test: $shown: $t depends on $a, which is not in allowed_axioms" >&2; fail=1 ;; esac
  done
done
[ "$fail" -eq 0 ] || exit 1
touch "$stamp"
"""

def _copy_src(ctx, src, rel):
    """Copy a source file into the build output tree (dereferences symlinks).

    Lean 4's moduleNameOfFileName resolves symlinks and validates that the
    canonical path is within its root directory (cwd). In Bazel, source files
    in the execroot are symlinks pointing outside, so we must copy them into
    the build output tree where their canonical path IS within the execroot.
    """
    copy = ctx.actions.declare_file(ctx.label.name + "_src/" + rel)
    ctx.actions.run_shell(
        inputs = [src],
        outputs = [copy],
        command = 'cp -L "$1" "$2"',
        arguments = [src.path, copy.path],
        mnemonic = "LeanCopySrc",
    )
    return copy

# ── lean_library ─────────────────────────────────────────────────────────────

def _lean_library_impl(ctx):
    toolchain = ctx.toolchains["//lean:toolchain_type"].lean_toolchain_info

    dep_path_entries, dep_files, transitive_stamps = _collect_dep_info(ctx.attr.deps)

    prefix = _lean_prefix(toolchain)
    stdlib_path = prefix + "/lib/lean/library"

    pkg = ctx.label.package
    pkg_prefix = pkg + "/" if pkg else ""

    compiled_oleans = []
    olean_dir = None
    src_dir = None

    for src in ctx.files.srcs:
        rel = src.short_path
        if rel.startswith(pkg_prefix):
            rel = rel[len(pkg_prefix):]
        olean_rel = rel[:-5] + ".olean"

        # Copy source into build tree so Lean sees a real file within the execroot
        src_copy = _copy_src(ctx, src, rel)
        if src_dir == None:
            src_dir = src_copy.path[:-(len(rel))]

        olean = ctx.actions.declare_file(ctx.label.name + "_oleans/" + olean_rel)
        if olean_dir == None:
            olean_dir = olean.path[:-(len(olean_rel))]

        # LEAN_PATH: stdlib + deps + our output dir + our source dir (for intra-library imports)
        all_entries = [stdlib_path] + dep_path_entries
        if olean_dir:
            all_entries.append(olean_dir)
        if src_dir:
            all_entries.append(src_dir)
        lean_path_str = ":".join(all_entries)

        args = ctx.actions.args()
        args.add(src_copy)
        args.add("-o", olean)
        for flag in ctx.attr.extra_flags:
            args.add(flag)

        ctx.actions.run(
            executable = toolchain.lean,
            arguments = [args],
            inputs = depset(
                [src_copy] + compiled_oleans + dep_files,
                transitive = [depset(toolchain.all_files)],
            ),
            outputs = [olean],
            env = {"LEAN_PATH": lean_path_str},
            mnemonic = "LeanCompile",
            progress_message = "Compiling %s" % src.short_path,
            execution_requirements = {"no-sandbox": "1"},
        )

        compiled_oleans.append(olean)

    # Stamp file
    stamp = ctx.actions.declare_file(ctx.label.name + ".verified")
    stamp_script = ctx.actions.declare_file(ctx.label.name + "_stamp.sh")
    ctx.actions.write(stamp_script, "#!/bin/bash\ntouch \"$1\"\n", is_executable = True)
    ctx.actions.run(
        executable = stamp_script,
        arguments = [stamp.path],
        inputs = compiled_oleans,
        outputs = [stamp],
        mnemonic = "LeanStamp",
    )

    lean_path_entries_out = [olean_dir] if olean_dir else []

    return [
        DefaultInfo(files = depset([stamp])),
        LeanInfo(
            srcs = ctx.files.srcs,
            stamp = stamp,
            oleans = compiled_oleans,
            lean_path_entries = lean_path_entries_out,
            all_files = depset(compiled_oleans + [stamp]),
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

    dep_path_entries, dep_files, _ = _collect_dep_info(ctx.attr.deps)

    prefix = _lean_prefix(toolchain)
    stdlib_path = prefix + "/lib/lean/library"

    all_entries = [stdlib_path] + dep_path_entries
    lean_path_str = ":".join(all_entries)

    pkg = ctx.label.package
    pkg_prefix = pkg + "/" if pkg else ""

    # Typecheck each source file individually
    check_stamps = []

    for i, src in enumerate(ctx.files.srcs):
        rel = src.short_path
        if rel.startswith(pkg_prefix):
            rel = rel[len(pkg_prefix):]

        # Copy source into build tree (Lean resolves symlinks)
        src_copy = _copy_src(ctx, src, rel)

        base = src.basename
        theorems = ctx.attr.axiom_checks.get(base, [])
        check_src = src_copy
        if theorems:
            # Append one `#print axioms` per named theorem to a copy of the file,
            # so Lean itself reports what each theorem depends on.
            check_src = ctx.actions.declare_file(ctx.label.name + "_axcheck/" + rel)
            ctx.actions.run_shell(
                inputs = [src_copy],
                outputs = [check_src],
                command = 'src="$1"; dst="$2"; shift 2; cat "$src" > "$dst" && printf "\\n" >> "$dst" && for t in "$@"; do printf "#print axioms %s\\n" "$t" >> "$dst"; done',
                arguments = [src_copy.path, check_src.path] + theorems,
                mnemonic = "LeanAxiomCheckSrc",
            )

        check_stamp = ctx.actions.declare_file(ctx.label.name + "_check_%d" % i)
        check_script = ctx.actions.declare_file(ctx.label.name + "_check_%d.sh" % i)
        ctx.actions.write(check_script, _PROOF_CHECK_SH, is_executable = True)

        ctx.actions.run(
            executable = check_script,
            arguments = [
                toolchain.lean.path,
                check_src.path,
                check_stamp.path,
                src.short_path,
                "1" if ctx.attr.allow_sorry else "0",
                ",".join(ctx.attr.allowed_axioms),
                ",".join(theorems),
            ] + ctx.attr.extra_flags,
            inputs = depset(
                [check_src] + dep_files,
                transitive = [depset(toolchain.all_files)],
            ),
            outputs = [check_stamp],
            env = {"LEAN_PATH": lean_path_str},
            mnemonic = "LeanProofCheck",
            progress_message = "Verifying %s" % src.short_path,
            execution_requirements = {"no-sandbox": "1"},
        )

        check_stamps.append(check_stamp)

    # Final stamp
    stamp = ctx.actions.declare_file(ctx.label.name + ".verified")
    final_script = ctx.actions.declare_file(ctx.label.name + "_final.sh")
    ctx.actions.write(final_script, "#!/bin/bash\ntouch \"$1\"\n", is_executable = True)
    ctx.actions.run(
        executable = final_script,
        arguments = [stamp.path],
        inputs = check_stamps,
        outputs = [stamp],
        mnemonic = "LeanStamp",
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
    doc = "Verifies that Lean 4 source files typecheck, contain no `sorry` (unless allow_sorry), and that named theorems use only allowed axioms.",
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
            doc = "Additional flags passed to lean for every file.",
        ),
        "allow_sorry": attr.bool(
            default = False,
            doc = "Accept `sorry`. Off by default: Lean only warns on `sorry`, so without this check an unfinished proof passes.",
        ),
        "axiom_checks": attr.string_list_dict(
            default = {},
            doc = "File basename -> theorem names. For each, Lean's `#print axioms` output must list only allowed_axioms, and a missing report fails.",
        ),
        "allowed_axioms": attr.string_list(
            default = ["propext", "Quot.sound", "Classical.choice"],
            doc = "Axioms a theorem in axiom_checks may depend on. Lean's three standard axioms by default.",
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
            oleans = [],
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
