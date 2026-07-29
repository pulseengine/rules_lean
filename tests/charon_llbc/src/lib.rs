//! Minimal Rust crate used to smoke-test the charon_llbc Bazel rule.
//! Kept deliberately small: `charon rustc --preset=aeneas` should translate
//! this without hitting any unsupported features.
//!
//! MUTANT #2 (mutation-testing spike, rules_lean#23): `add` drops the `y`
//! term entirely. Expect: KILLED — add.spec requires z.val = x.val + y.val.

pub fn add(x: u32, y: u32) -> u32 {
    let _ = y;
    x
}

pub fn identity(x: u64) -> u64 {
    x
}
