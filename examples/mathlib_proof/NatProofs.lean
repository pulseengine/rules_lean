import Mathlib.Data.Nat.Basic
import Mathlib.Tactic

-- Prove basic properties using Mathlib tactics and lemmas.

theorem nat_add_comm (a b : Nat) : a + b = b + a := by
  exact Nat.add_comm a b

theorem nat_mul_comm (a b : Nat) : a * b = b * a := by
  exact Nat.mul_comm a b

theorem nat_add_assoc (a b c : Nat) : (a + b) + c = a + (b + c) := by
  exact Nat.add_assoc a b c

theorem nat_le_refl (n : Nat) : n ≤ n := by
  exact Nat.le_refl n

theorem nat_zero_le (n : Nat) : 0 ≤ n := by
  exact Nat.zero_le n
