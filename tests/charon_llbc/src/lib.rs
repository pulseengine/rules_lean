//! Minimal Rust crate used to smoke-test the charon_llbc Bazel rule.
//! Kept deliberately small: `charon rustc --preset=aeneas` should translate
//! this without hitting any unsupported features.
//!
//! MUTANT #4 (mutation-testing spike, rules_lean#23): operands commuted in
//! `add`. Expect: SURVIVES, as an EQUIVALENT MUTANT (u32 addition is
//! commutative) — control case to validate the bucketing methodology itself,
//! not a real spec gap.

pub fn add(x: u32, y: u32) -> u32 {
    y + x
}

pub fn identity(x: u64) -> u64 {
    x
}
