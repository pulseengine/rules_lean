import Mathlib.Data.Real.Basic
import Mathlib.Tactic

/-
Real-number (ℝ) proofs that exercise the ordered-field / Mathlib path the
Nat-only example cannot reach: `ring`, `linarith`, `nlinarith`, `sq_nonneg`,
and `mul_nonneg`. This is the proof shape that surfaced the downstream
Mathlib-fetch bugs (full clone, version skew) — building it from a clean cache
is the regression guard for those fixes.
-/

theorem real_ring (a b : ℝ) : (a + b) ^ 2 = a ^ 2 + 2 * a * b + b ^ 2 := by
  ring

theorem real_sq_nonneg (a : ℝ) : 0 ≤ a ^ 2 :=
  sq_nonneg a

theorem real_mul_nonneg (a b : ℝ) (ha : 0 ≤ a) (hb : 0 ≤ b) : 0 ≤ a * b :=
  mul_nonneg ha hb

theorem real_linarith (a b : ℝ) (h : a ≤ b) : a - 1 < b + 1 := by
  linarith

theorem real_amgm (a b : ℝ) : 2 * a * b ≤ a ^ 2 + b ^ 2 := by
  nlinarith [sq_nonneg (a - b)]
