---
title: STPA Safety Analysis Overview
---

# STPA Safety Analysis — rules_lean

This document summarizes the Systems-Theoretic Process Analysis (STPA)
performed on the rules_lean build system. The full artifacts are in
`artifacts/safety.yaml`.

## System Under Analysis

**rules_lean** is a Bazel rules package that downloads, configures, and
invokes the Lean 4 compiler and Mathlib library for formal proof
verification. The system is used to produce certification evidence in
safety-critical projects (e.g., ASIL-D formal proofs for the gale
kernel library).

## Losses (Step 1a)

| ID | Loss | Stakeholders |
|----|------|-------------|
| L-001 | Undetected proof unsoundness | developers, safety-engineers, certification-authorities |
| L-002 | Silent build corruption | developers, ci-operators |
| L-003 | Supply-chain compromise of toolchain | developers, security-engineers, certification-authorities |
| L-004 | Loss of reproducibility | developers, certification-authorities |

## Hazards (Step 1b)

| ID | Hazard | Severity | Losses |
|----|--------|----------|--------|
| H-001 | Lean/Mathlib version mismatch | critical | L-001, L-002 |
| H-002 | SHA-256 hash verification bypassed | critical | L-003 |
| H-003 | LEAN_PATH includes stale directories | critical | L-001, L-002 |
| H-004 | Source symlink TOCTOU | marginal | L-001 |
| H-005 | Wrong platform binary selected | critical | L-002 |
| H-006 | Non-hermetic Mathlib fetch | marginal | L-004 |
| H-007 | Sandbox disabled, untracked host deps | marginal | L-004 |

## Control Structure (Step 2)

```
Developer (CTRL-004)
  │
  ├─ configures → Module Extension (CTRL-002)
  │                  ├─ downloads → Toolchain (CP-002)
  │                  └─ fetches  → Mathlib (CP-003)
  │
  └─ writes    → lean_library rule (CTRL-003)
                    └─ compiles → Lean compilation (CP-001)
                         │
  Bazel (CTRL-001) ──────┘ orchestrates all actions
```

## Unsafe Control Actions (Step 3)

| ID | UCA | Type | Hazard |
|----|-----|------|--------|
| UCA-001 | Mismatched Lean version to Mathlib | providing | H-001 |
| UCA-002 | Empty SHA-256 for production builds | not-providing | H-002 |
| UCA-003 | Stale LEAN_PATH from cached dep | providing | H-003 |
| UCA-004 | Source copy omitted, lean gets symlink | not-providing | H-004 |
| UCA-005 | Wrong platform constraints in hub | providing | H-005 |
| UCA-006 | Mathlib consolidation misses packages | not-providing | H-003 |

## Mitigations Implemented

| Constraint | Status | Implementation |
|-----------|--------|---------------|
| SC-002 / CC-002 | **implemented** | Extension `fail()`s on empty SHA-256. `require_hashes=False` opt-out. CI test verifies. |
| SC-001 / CC-001 | **implemented** | Single version string used for both Lean and Mathlib. |
| SC-003 / CC-003 | **implemented** | LEAN_PATH built from declared action inputs only. |
| SC-004 / CC-004 | **implemented** | `_copy_src()` via `cp -L` before every lean invocation. |
| SC-005 | **implemented** | Platform constraint maps + artifact name translation. |
| SC-006 | **implemented** | Mathlib fetched at pinned git revision via `@` operator. |
| SC-007 | **implemented** | All inputs declared in `ctx.actions.run()`. |
| CC-005 | draft | Per-platform download test not yet in CI. |
| CC-006 | **implemented** | Validates `lib/Mathlib/` contains ≥100 oleans. |

## Traceability

Full traceability chain from losses to implementation:

```
Loss → Hazard → System Constraint → Requirement → Design Decision → Feature
 (4)     (7)          (7)               (9)            (6)            (6)
                                                               100% coverage
```

Run `rivet coverage` to verify current state.
