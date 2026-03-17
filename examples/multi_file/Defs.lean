-- Basic definitions used by other files in the library
def square (n : Nat) : Nat := n * n

theorem square_zero : square 0 = 0 := by rfl

theorem square_pos (n : Nat) (h : n > 0) : square n > 0 := by
  unfold square
  exact Nat.mul_pos h h
