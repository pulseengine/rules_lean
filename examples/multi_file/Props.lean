import Defs

-- Properties that depend on Defs
theorem square_one : square 1 = 1 := by rfl

theorem square_monotone (a b : Nat) (h : a ≤ b) : square a ≤ square b := by
  unfold square
  exact Nat.mul_le_mul h h
