import Duper.Tactic
import Duper.Tests.Testduper

axiom f : Nat → Nat
axiom a : Nat

-- set_option trace.Prover.saturate true

example (h : f a = a) : 
f (f (f (f (f (f (f (f (f (f (
f (f (f (f (f (f (f (f (f (f (
f (f (f (f (f (f (f (f (f (f (
f (f (f (f (f (f (f (f (f (f (
f (f (f (f (f (f (f (f (f (f (
a
))))))))))
))))))))))
))))))))))
))))))))))
)))))))))) = a
 := by duper

 example (h : f a = a) : 
f (f (f (f (f (f (f (f (f (f (
f (f (f (f (f (f (f (f (f (f (
f (f (f (f (f (f (f (f (f (f (
f (f (f (f (f (f (f (f (f (f (
f (f (f (f (f (f (f (f (f (f (
a
))))))))))
))))))))))
))))))))))
))))))))))
)))))))))) = a
 := by testduper