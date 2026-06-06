/-
Formal verification of the translated Rust crate (src/lib.rs).

  Rust  →  Charon (LLBC)  →  Aeneas (Lean)  →  these proofs

`hello_lean` is the Aeneas translation of `add`/`identity`; here we state and
kernel-check properties about that translation, using Aeneas's `⦃ ⦄`
progress-spec notation. This is the verification payoff: a property of the Rust
code, proved in Lean, checked in CI with zero `sorry`/axiom.
-/
import Aeneas
import hello_lean
open Aeneas Std Result

#setup_aeneas_simps

namespace hello

/-- `add` returns exactly the sum when it doesn't overflow. -/
theorem add.spec (x y : U32) (h : x.val + y.val ≤ U32.max) :
    add x y ⦃ z => z.val = x.val + y.val ⦄ := by
  unfold add
  step as ⟨ z ⟩
  scalar_tac

/-- `identity` returns its input unchanged. -/
theorem identity.spec (x : U64) :
    identity x ⦃ y => y = x ⦄ := by
  unfold identity

end hello
