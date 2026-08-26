"""Shared host-platform detection for repository rule implementations.

MUST be called from a `repository_rule` implementation (`repository_ctx`),
never from a `module_extension` implementation (`module_ctx`). Both expose
the same `.os.name` / `.os.arch` shape, so the temptation is to detect the
host once in the extension and pass it down as a repo-rule attribute — but
attributes of repos a module extension generates are frozen verbatim into a
committed `MODULE.bazel.lock` (see `generatedRepoSpecs`). A lock generated on
macOS would then pin `darwin_aarch64` forever, shipping the wrong `lake`
binary to any other platform that reuses the lock without re-running the
extension (rules_lean#30). Detecting inside the repo rule instead means the
rule takes no such attribute, so there is nothing to freeze: `rctx.os` is
read fresh every time the rule actually fetches, on whichever machine that
happens to be.
"""

def detect_host_platform(rctx):
    """Returns one of darwin_aarch64/darwin_x86_64/linux_aarch64/linux_x86_64."""
    os_name = rctx.os.name.lower()
    os_arch = rctx.os.arch.lower()

    if "mac" in os_name or "darwin" in os_name:
        if "aarch64" in os_arch or "arm64" in os_arch:
            return "darwin_aarch64"
        return "darwin_x86_64"
    elif "linux" in os_name:
        if "aarch64" in os_arch or "arm64" in os_arch:
            return "linux_aarch64"
        return "linux_x86_64"
    else:
        fail("Unsupported host platform: {} {}".format(os_name, os_arch))
