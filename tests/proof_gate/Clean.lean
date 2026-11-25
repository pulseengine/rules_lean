-- Passes lean_proof_test: no sorry, and `ok` uses no axiom outside the default list.
theorem ok (a b : Nat) : a + b = b + a := by
  omega
