//! Minimal Rust crate used to smoke-test the charon_llbc Bazel rule.
//! Kept deliberately small: `charon rustc --preset=aeneas` should translate
//! this without hitting any unsupported features.
//!
//! MUTANT #1 (mutation-testing spike, rules_lean#23): `+` swapped to `-` in
//! `add`. Expect: KILLED — add.spec requires z.val = x.val + y.val exactly.

pub fn add(x: u32, y: u32) -> u32 {
    x - y
}

pub fn identity(x: u64) -> u64 {
    x
}
