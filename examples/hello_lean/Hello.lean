-- A simple Lean 4 proof to verify the toolchain works.

theorem add_comm_nat (a b : Nat) : a + b = b + a := by
  omega

theorem zero_add (n : Nat) : 0 + n = n := by
  simp

def double (n : Nat) : Nat := n + n

theorem double_eq (n : Nat) : double n = n + n := by
  rfl

#check add_comm_nat
#check zero_add
#check double_eq
