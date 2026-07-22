//! Aeneas coverage experiment: a REAL relay primitive translated verbatim.
//!
//! Source: pulseengine/relay `crates/relay-primitives/plain/src/crc32.rs`
//! (test module stripped). Exercises features beyond the trivial example:
//! a const-eval array, `&[u8]` slices, indexing, `as` casts, `%`, bit ops,
//! `while` loops. The point is to discover what Aeneas can translate from
//! relay's verification-oriented `plain` code.

/// CRC32 lookup table for polynomial 0xEDB88320 (standard reflected).
///
/// WORKAROUND: computed by a runtime fn instead of a `const`. Aeneas
/// (build-2026.04.22) hits an internal error translating the const-eval'd
/// global array form (the identical body as a `const` fails at src/lib.rs:10).
pub fn crc32_table() -> [u32; 256] {
    let mut table = [0u32; 256];
    let mut i: usize = 0;
    while i < 256 {
        let mut crc: u32 = i as u32;
        let mut j: usize = 0;
        while j < 8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xEDB8_8320u32;
            } else {
                crc = crc >> 1;
            }
            j = j + 1;
        }
        table[i] = crc;
        i = i + 1;
    }
    table
}

/// Compute CRC32 over a byte slice. Pure, deterministic, total.
pub fn crc32_compute(data: &[u8]) -> u32 {
    let table = crc32_table();
    let mut crc: u32 = 0xFFFF_FFFFu32;
    let mut i: usize = 0;
    while i < data.len() {
        let byte = data[i];
        let raw_index = ((crc ^ (byte as u32)) % 256u32) as usize;
        crc = (crc >> 8) ^ table[raw_index];
        i = i + 1;
    }
    crc ^ 0xFFFF_FFFFu32
}
