"Public API for rules_lean."

load(
    "//lean/private:lean.bzl",
    _LeanInfo = "LeanInfo",
    _lean_library = "lean_library",
    _lean_prebuilt_library = "lean_prebuilt_library",
    _lean_proof_test = "lean_proof_test",
)

lean_library = _lean_library
lean_proof_test = _lean_proof_test
lean_prebuilt_library = _lean_prebuilt_library
LeanInfo = _LeanInfo
