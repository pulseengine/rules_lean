//! Minimal Rust crate used to smoke-test the charon_llbc Bazel rule.
//! Kept deliberately small: `charon rustc --preset=aeneas` should translate
//! this without hitting any unsupported features.
//!
//! MUTANT #3 (mutation-testing spike, rules_lean#23): `identity` adds a
//! constant. Expect: KILLED — identity.spec requires y = x exactly.

pub fn add(x: u32, y: u32) -> u32 {
    x + y
}

pub fn identity(x: u64) -> u64 {
    x + 1
}
