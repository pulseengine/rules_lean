//! Minimal Rust crate used to smoke-test the charon_llbc Bazel rule.
//! Kept deliberately small: `charon rustc --preset=aeneas` should translate
//! this without hitting any unsupported features.
//!
//! MUTANT #5 (mutation-testing spike, rules_lean#23): `add` rewritten with a
//! raw-pointer dereference inside `unsafe`. Expect: TRANSLATION FAILURE (not
//! a proof outcome) — this is the control case for the pitfall the research
//! flagged: a mutant that fails to translate through Charon/Aeneas must be
//! bucketed separately from "proof survived", never conflated with it.

pub fn add(x: u32, y: u32) -> u32 {
    let px: *const u32 = &x;
    unsafe { *px + y }
}

pub fn identity(x: u64) -> u64 {
    x
}
