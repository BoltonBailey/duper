import Lean
import Duper.Saturate

open Lean
open Lean.Meta
open Duper
open ProverM
open Lean.Parser

initialize 
  registerTraceClass `TPTP_Testing
  registerTraceClass `Print_Proof
  registerTraceClass `Saturate.debug

namespace Lean.Elab.Tactic

partial def printProof (state : ProverM.State) : TacticM Unit := do
  Core.checkMaxHeartbeats "printProof"
  let rec go c (hm : Array (Nat × Clause) := {}) : TacticM (Array (Nat × Clause)) := do
    let info ← getClauseInfo! c
    if hm.contains (info.number, c) then return hm
    let mut hm := hm.push (info.number, c)
    let parentInfo ← info.proof.parents.mapM (fun pp => getClauseInfo! pp.clause) 
    let parentIds := parentInfo.map fun info => info.number
    trace[Print_Proof] "Clause #{info.number} (by {info.proof.ruleName} {parentIds}): {c}"
    for proofParent in info.proof.parents do
      hm ← go proofParent.clause hm
    return hm
  let _ ← go Clause.empty
where 
  getClauseInfo! (c : Clause) : TacticM ClauseInfo := do
    let some ci := state.allClauses.find? c
      | throwError "clause info not found: {c}"
    return ci

def getClauseInfo! (state : ProverM.State) (c : Clause) : TacticM ClauseInfo := do
  let some ci := state.allClauses.find? c
    | throwError "clause info not found: {c}"
  return ci

partial def collectClauses (state : ProverM.State) (c : Clause) (acc : (HashSet Nat × ClauseHeap × HashMap Name Level)) :
    TacticM (HashSet Nat × ClauseHeap × HashMap Name Level) := do
  Core.checkMaxHeartbeats "collectClauses"
  let info ← getClauseInfo! state c
  if acc.1.contains info.number then return acc -- No need to recall collectClauses on c because we've already collected c
  let mut acc := acc
  -- recursive calls
  acc := (acc.1.insert info.number, acc.2.1.insert (info.number, c), acc.2.2)
  for proofParent in info.proof.parents do
    for (paramName, paramSubst) in proofParent.clause.paramNames.zip proofParent.paramSubst do
      let paramSubst:= paramSubst.replace fun l =>
        match l with
        | .param n => acc.2.2.find? n
        | _ => none
      acc := (acc.1, acc.2.1, acc.2.2.insert paramName paramSubst)

    acc ← collectClauses state proofParent.clause acc
  return acc

partial def mkProof (state : ProverM.State) : List Clause → TacticM Expr
| [] => panic! "empty clause list"
| c :: cs => do
  Core.checkMaxHeartbeats "mkProof"
  let info ← getClauseInfo! state c
  let newTarget := c.toForallExpr
  let mut parents := []
  for parent in info.proof.parents do
    let number := (← getClauseInfo! state parent.clause).number
    parents := ((← getLCtx).findFromUserName? (Name.mkNum `clause number)).get!.toExpr :: parents
  parents := parents.reverse
  -- Now `parents[i] : info.proof.parents[i].toForallExpr`, for all `i`
  let mut lctx ← getLCtx
  let mut skdefs : List Expr := []
  for (fvarId, mkSkProof) in info.proof.introducedSkolems do
    trace[Print_Proof] "Reconstructing skolem, fvar = {mkFVar fvarId}"
    let ty := (state.lctx.get! fvarId).type
    trace[Meta.debug] "Reconstructing skolem, type = {ty}"
    let userName := (state.lctx.get! fvarId).userName
    trace[Print_Proof] "Reconstructed skloem, userName = {userName}"
    let skdef ← mkSkProof parents.toArray
    trace[Meta.debug] "Reconstructed skolem definition: {skdef}"
    trace[Meta.debug] "Reconstructed skolem definition, toString: {toString skdef}"
    skdefs := skdef :: skdefs
    lctx := lctx.mkLetDecl fvarId userName ty skdef
  let proof ← withLCtx lctx (← getLocalInstances) do
    trace[Meta.debug] "Reconstructing proof for #{info.number}: {c}, Rule Name: {info.proof.ruleName}"
    let newProof ← info.proof.mkProof parents info.proof.parents c
    trace[Meta.debug] "#{info.number}'s newProof: {newProof}"
    if cs == [] then return newProof
    let proof ←
      withLetDecl (Name.mkNum `clause info.number) newTarget newProof fun g => do
        let remainingProof ← mkProof state cs
        let mut remainingProof ← mkLambdaFVars (usedLetOnly := false) #[g] remainingProof
        for (fvarId, _) in info.proof.introducedSkolems do
          remainingProof ← mkLambdaFVars (usedLetOnly := false) #[mkFVar fvarId] remainingProof
        return remainingProof
    return proof
  return proof

def applyProof (state : ProverM.State) : TacticM Unit := do
  let collection ← collectClauses state Clause.empty ({}, Std.BinomialHeap.empty, {})
  let l := collection.2.1.toList.eraseDups.map Prod.snd
  trace[Meta.debug] "{l}"
  let proof ← mkProof state l
  let proof := proof.replaceLevel fun l =>
    match l with
    | .param n => collection.2.2.find? n
    | _ => none
  logInfo m!"{proof}"

  trace[Print_Proof] "Proof: {proof}"
  Lean.MVarId.assign (← getMainGoal) proof -- TODO: List.last?

def elabFact (stx : Term) : TacticM (Array Expr) := do
  match stx with
  | `($id:ident) =>
    -- Try to look up any defining equations for this identifier
    let some expr ← Term.resolveId? id
      | throwError "Unknown identifier {id}"
    match ← getEqnsFor? expr.constName! (nonRec := true) with -- TODO: use mkSimpleEqThm
    | some eqns => do
      logInfo m!"eqns {← eqns.mapM fun id => do return (← Term.resolveId? (mkIdent id))}"
      eqns.mapM fun eq => do elabFactAux (← `($(mkIdent eq)))
    | none =>
      -- Identifier is not a definition
      return #[← elabFactAux stx]
  | _ => return #[← elabFactAux stx]
where elabFactAux (stx : Term) : TacticM Expr :=
  -- elaborate term as much as possible:
  withRef stx <| Term.withoutErrToSorry do
    let e ← Term.elabTerm stx none
    Term.synthesizeSyntheticMVars (mayPostpone := false) (ignoreStuckTC := true)
    let e ← instantiateMVars e
    return e

def collectAssumptions (facts : Array Term) : TacticM (List (Clause × Expr)) := do
  let mut formulas := []
  -- Load all local decls:
  for fVarId in (← getLCtx).getFVarIds do
    let ldecl ← Lean.FVarId.getDecl fVarId
    unless ldecl.isAuxDecl ∨ not (← instantiateMVars (← inferType ldecl.type)).isProp do
      formulas := (Clause.fromSingleExpr (← instantiateMVars ldecl.type), ← mkAppM ``eq_true #[mkFVar fVarId]) :: formulas
  -- load user-provided facts
  for facts in ← facts.mapM elabFact do
    for fact in facts do
      let type ← inferType fact
      if ← isProp type then
        IO.println s!"Hello {fact}"
        let s ← abstractMVars fact
        let fact' := s.expr
        formulas := (Clause.fromSingleExpr (paramNames := s.paramNames) (← inferType fact'), ← mkAppM ``eq_true #[fact']) :: formulas
      else
        throwError "invalid fact for duper, proposition expected {indentExpr fact}"

  return formulas

syntax (name := duper) "duper" (colGt ident)? ("[" term,* "]")? : tactic

macro_rules
| `(tactic| duper) => `(tactic| duper [])

def runDuper (facts : Syntax.TSepArray `term ",") : TacticM ProverM.State := do
  let formulas ← collectAssumptions facts.getElems
  trace[Meta.debug] "Formulas from collectAssumptions: {formulas}"
  let (_, state) ←
    ProverM.run (s := {lctx := ← getLCtx, mctx := ← getMCtx}) do
      for (c, proof) in formulas do
        let mkProof := fun _ _ _ => pure proof
        addNewToPassive c {ruleName := "assumption", mkProof := mkProof} []
      ProverM.saturateNoPreprocessingClausification
  return state

@[tactic duper]
def evalDuper : Tactic
| `(tactic| duper [$facts,*]) => withMainContext do
  let startTime ← IO.monoMsNow
  Elab.Tactic.evalTactic (← `(tactic| intros; apply Classical.byContradiction _; intro))
  withMainContext do
    let state ← runDuper facts
    match state.result with
    | Result.contradiction => do
      logInfo s!"Contradiction found. Time: {(← IO.monoMsNow) - startTime}ms"
      trace[TPTP_Testing] "Final Active Set: {state.activeSet.toArray}"
      printProof state
      applyProof state
      logInfo s!"Constructed proof. Time: {(← IO.monoMsNow) - startTime}ms"
    | Result.saturated =>
      trace[Saturate.debug] "Final Active Set: {state.activeSet.toArray}"
      throwError "Prover saturated."
    | Result.unknown => throwError "Prover was terminated."
| `(tactic| duper $ident:ident [$facts,*]) => withMainContext do
  Elab.Tactic.evalTactic (← `(tactic| intros; apply Classical.byContradiction _; intro))
  withMainContext do
    let state ← runDuper facts
    match state.result with
    | Result.contradiction => do
      logInfo s!"{ident} test succeeded in finding a contradiction"
      trace[TPTP_Testing] "Final Active Set: {state.activeSet.toArray}"
      printProof state
      applyProof state
    | Result.saturated =>
      logInfo s!"{ident} test resulted in prover saturation"
      trace[Saturate.debug] "Final Active Set: {state.activeSet.toArray}"
      Lean.Elab.Tactic.evalTactic (← `(tactic| sorry))
    | Result.unknown => throwError "Prover was terminated."
| _ => throwUnsupportedSyntax

syntax (name := duper_no_timing) "duper_no_timing" ("[" term,* "]")? : tactic

macro_rules
| `(tactic| duper_no_timing) => `(tactic| duper_no_timing [])

@[tactic duper_no_timing]
def evalDuperNoTiming : Tactic
| `(tactic| duper_no_timing [$facts,*]) => withMainContext do
  Elab.Tactic.evalTactic (← `(tactic| intros; apply Classical.byContradiction _; intro))
  withMainContext do
    let state ← runDuper facts
    match state.result with
    | Result.contradiction => do
      logInfo s!"Contradiction found"
      trace[TPTP_Testing] "Final Active Set: {state.activeSet.toArray}"
      printProof state
      applyProof state
      logInfo s!"Constructed proof"
    | Result.saturated =>
      trace[Saturate.debug] "Final Active Set: {state.activeSet.toArray}"
      throwError "Prover saturated."
    | Result.unknown => throwError "Prover was terminated."
| _ => throwUnsupportedSyntax

end Lean.Elab.Tactic

