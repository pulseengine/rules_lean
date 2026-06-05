"Public API for Aeneas rules."

load(
    "//aeneas/private:aeneas.bzl",
    _AeneasInfo = "AeneasInfo",
    _aeneas_translate = "aeneas_translate",
    _aeneas_verified_library = "aeneas_verified_library",
)
load(
    "//aeneas/private:charon.bzl",
    _CharonLlbcInfo = "CharonLlbcInfo",
    _charon_llbc = "charon_llbc",
)

aeneas_translate = _aeneas_translate
aeneas_verified_library = _aeneas_verified_library
AeneasInfo = _AeneasInfo

charon_llbc = _charon_llbc
CharonLlbcInfo = _CharonLlbcInfo
