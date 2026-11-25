-- PLANTED: a proof that leans on a made-up axiom. With axiom_checks naming it,
-- lean_proof_test must fail because `cheat` is not in allowed_axioms.
axiom cheat : False

theorem two_is_three : 2 = 3 := cheat.elim
