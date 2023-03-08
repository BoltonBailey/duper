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

partial def printProof (state : ProverM.State) : MetaM Unit := do
  Core.checkMaxHeartbeats "printProof"
  let rec go c (hm : Array (Nat × Clause) := {}) : MetaM (Array (Nat × Clause)) := do
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
  getClauseInfo! (c : Clause) : MetaM ClauseInfo := do
    let some ci := state.allClauses.find? c
      | throwError "clause info not found: {c}"
    return ci

def getClauseInfo! (state : ProverM.State) (c : Clause) : MetaM ClauseInfo := do
  let some ci := state.allClauses.find? c
    | throwError "clause info not found: {c}"
  return ci

abbrev ClauseHeap := Std.BinomialHeap (Nat × Clause) fun c d => c.1 ≤ d.1

partial def collectClauses (state : ProverM.State) (c : Clause) (acc : (Array Nat × ClauseHeap)) : MetaM (Array Nat × ClauseHeap) := do
  Core.checkMaxHeartbeats "collectClauses"
  let info ← getClauseInfo! state c
  if acc.1.contains info.number then return acc -- No need to recall collectClauses on c because we've already collected c
  let mut acc := acc
  -- recursive calls
  acc := (acc.1.push info.number, acc.2.insert (info.number, c))
  for proofParent in info.proof.parents do
    acc ← collectClauses state proofParent.clause acc
  return acc

-- Map from clause `id` to Array of request of levels
abbrev LevelRequests := HashMap Nat (HashMap (Array Level) Nat)

partial def collectLevelRequests (state : ProverM.State) (c : Clause)
  (lvls : Array Level) (acc : LevelRequests) : MetaM LevelRequests := do
  Core.checkMaxHeartbeats "collectLevelRequests"
  let info ← getClauseInfo! state c
  if let some set := acc.find? info.number then
    if set.contains lvls then
      return acc
  let mut acc := acc
  let lvlset :=
    match acc.find? info.number with
    | some set => set
    | none     => HashMap.empty
  trace[Meta.debug] "Request {lvls} for {c}"
  acc := acc.insert info.number (lvlset.insert lvls lvlset.size)
  for proofParent in info.proof.parents do
    let lvls' := proofParent.paramSubst.map
      (fun lvl => lvl.instantiateParams c.paramNames.data lvls.data)
    acc ← collectLevelRequests state proofParent.clause lvls' acc
  return acc

partial def mkSkProof (state : ProverM.State) : List Clause → MetaM Expr → MetaM Expr
| [], mexpr => mexpr
| c :: cs, mexpr => do
  Core.checkMaxHeartbeats "mkSkProof"
  let info ← getClauseInfo! state c
  if let some ⟨skProof, fvarId⟩ := info.proof.introducedSkolems then
    trace[Print_Proof] "Reconstructing skolem, fvar = {mkFVar fvarId}"
    let ty := (state.lctx.get! fvarId).type
    trace[Meta.debug] "Reconstructing skolem, type = {ty}"
    let userName := (state.lctx.get! fvarId).userName
    trace[Print_Proof] "Reconstructed skloem, userName = {userName}"
    trace[Meta.debug] "Reconstructed skolem definition: {skProof}"
    let lctx ← getLCtx
    let lctx' := lctx.mkLetDecl fvarId userName ty skProof
    withLCtx lctx' (← getLocalInstances) do
      mkLambdaFVars (usedLetOnly := false) #[mkFVar fvarId] (← mkSkProof state cs mexpr)
  else
    mkSkProof state cs mexpr

-- `Nat` is the id of the clause
-- `Array Level` is the requested levels for the clause
-- `Expr` is the fvarId corresponding to the proof for the clause in the current `lctx`
abbrev ConstructedClauses := HashMap (Nat × Array Level) Expr

partial def mkClauseProofHelper (state : ProverM.State) (reqs : LevelRequests) :
  List Clause → ConstructedClauses → MetaM (Expr × ConstructedClauses)
| [], _ => panic! "mkClauseProof :: empty clause list"
| c :: cs, ctrc => do
  Core.checkMaxHeartbeats "mkClauseProof"
  let info ← getClauseInfo! state c
  let lvlreqs := reqs.find! info.number
  -- let mut parentss := #[]
  let mut remainingProofConsCode : ConstructedClauses → MetaM (Expr × ConstructedClauses) :=
    mkClauseProofHelper state reqs cs
  for (req, reqid) in lvlreqs.toList do
    let mut parents : Array Expr := #[]
    let mut instantiatedProofParents := #[]
    for parent in info.proof.parents do
      let parentInfo ← getClauseInfo! state parent.clause
      let parentNumber := parentInfo.number
      let instantiatedParentParamSubst := parent.paramSubst.map (fun lvl => lvl.instantiateParams c.paramNames.data req.data)
      let parentPrfFvar := ctrc.find! (parentNumber, instantiatedParentParamSubst)
      parents := parents.push parentPrfFvar
      let instPP := {parent with paramSubst := instantiatedParentParamSubst}
      instantiatedProofParents := instantiatedProofParents.push instPP
    -- Now `parents[i] : info.proof.parents[i].toForallExpr`, for all `i`
    let instCLits := c.lits.map (fun l => l.instantiateLevelParamsArray c.paramNames req)
    let instBvarTys := c.bVarTypes.map (fun e => e.instantiateLevelParamsArray c.paramNames req)
    let instC := {c with lits := instCLits, bVarTypes := instBvarTys}
    trace[Meta.debug] "Reconstructing proof for #{info.number}: {instC}, Rule Name: {info.proof.ruleName}"
    let instTr := info.proof.transferExprs.map (fun e => e.instantiateLevelParamsArray c.paramNames req)
    let newProof ← (do
      let prf ← info.proof.mkProof parents.data instantiatedProofParents.data instTr instC
      if info.proof.ruleName != "assumption" then
        return prf
      else
        -- If the rule is "assumption", then there is no proofparent and
        --   we have to manually instantiate the universe mvars
        return prf.instantiateLevelParamsArray c.paramNames req)
    let newTarget := instC.toForallExpr
    trace[Meta.debug] "#{info.number}'s newProof: {newProof}"
    if cs == [] then return (newProof, ctrc)
    remainingProofConsCode := fun ctrc =>
      withLetDecl (Name.mkNum (Name.mkNum `clause info.number) reqid) newTarget newProof fun g => do
        let ctrc' := ctrc.insert (info.number, req) g
        let (remainingProof, ctrc') ← remainingProofConsCode ctrc'
        let rexpr ← mkLambdaFVars (usedLetOnly := false) #[g] remainingProof
        return (rexpr, ctrc')
  remainingProofConsCode ctrc

partial def mkClauseProof (state : ProverM.State) (cs : List Clause) : MetaM Expr := do
  let cs := Array.mk cs
  let cslen := cs.size
  if cslen == 0 then
    throwError "mkClauseProof :: Empty Clause List"
  -- The final empty clause
  let emptyClause := cs[cslen - 1]!
  -- Other clauses
  let zeroLvlsForEmptyClause := emptyClause.paramNames.map (fun _ => Level.zero)
  let reqs ← collectLevelRequests state emptyClause zeroLvlsForEmptyClause HashMap.empty
  let (e, _) ← mkClauseProofHelper state reqs cs.data HashMap.empty
  return e

def applyProof (state : ProverM.State) : TacticM Unit := do
  let l := (← collectClauses state Clause.empty (#[], Std.BinomialHeap.empty)).2.toList.eraseDups.map Prod.snd
  trace[Meta.debug] "{l}"
  -- First make proof for skolems, then make proof for clauses
  let proof ← mkSkProof state l (mkClauseProof state l)
  trace[Print_Proof] "Proof: {proof}"
  Lean.MVarId.assign (← getMainGoal) proof -- TODO: List.last?

/-- Produces definional equations for a recursor `recVal` such as

  `@Nat.rec m z s (Nat.succ n) = s n (@Nat.rec m z s n)`
  
  The returned list contains one equation
  for each constructor, a proof of the equation, and the contained level
  parameters. -/
def addRecAsFact (recVal : RecursorVal): TacticM (List (Expr × Expr × Array Name)) := do
  let some (.inductInfo indVal) := (← getEnv).find? recVal.getInduct
    | throwError "Expected inductive datatype: {recVal.getInduct}"
      
  let expr := mkConst recVal.name (recVal.levelParams.map Level.param)
  let res ← forallBoundedTelescope (← inferType expr) recVal.getMajorIdx fun xs _ => do
    let expr := mkAppN expr xs
    return ← indVal.ctors.mapM fun ctorName => do
      let ctor ← mkAppOptM ctorName #[]
      let (eq, proof) ← forallTelescope (← inferType ctor) fun ys _ => do
        let ctor := mkAppN ctor ys
        let expr := mkApp expr ctor
        let some redExpr ← reduceRecMatcher? expr
          | throwError "Could not reduce recursor application: {expr}"
        let redExpr ← Core.betaReduce redExpr -- TODO: The prover should be able to beta-reduce!
        let eq ← mkEq expr redExpr
        let proof ← mkEqRefl expr
        return (← mkForallFVars ys eq, ← mkLambdaFVars ys proof)
      return (← mkForallFVars xs eq, ← mkLambdaFVars xs proof, recVal.levelParams.toArray)

  return res

/-- From a user-provided fact `stx`, produce a suitable fact, its proof, and a
    list of universe parameter names-/
def elabFact (stx : Term) : TacticM (Array (Expr × Expr × Array Name)) := do
  match stx with
  | `($id:ident) =>
    let some expr ← Term.resolveId? id
      | throwError "Unknown identifier {id}"

    match (← getEnv).find? expr.constName! with
    | some (.recInfo val) =>
      let facts ← addRecAsFact val
      let facts ← facts.mapM fun (fact, proof, paramNames) => do
        return (← instantiateMVars fact, ← instantiateMVars proof, paramNames)
      return facts.toArray
    | some (.defnInfo val) =>
      let some eqns ← getEqnsFor? expr.constName! (nonRec := true)
        | throwError "Could not generate definition equations for {expr.constName!}"
        eqns.mapM fun eq => do elabFactAux (← `($(mkIdent eq)))
    | some (.axiomInfo _)  => return #[← elabFactAux stx]
    | some (.thmInfo _)    => return #[← elabFactAux stx]
    | some (.opaqueInfo _) => throwError "Opaque constants cannot be provided as facts"
    | some (.quotInfo _)   => throwError "Quotient constants cannot be provided as facts"
    | some (.inductInfo _) => throwError "Inductive types cannot be provided as facts"
    | some (.ctorInfo _)   => throwError "Constructors cannot be provided as facts"
    | none => throwError "Unknown constant {expr.constName!}"
  | _ => return #[← elabFactAux stx]
where elabFactAux (stx : Term) : TacticM (Expr × Expr × Array Name) :=
  -- elaborate term as much as possible and abstract any remaining mvars:
  Term.withoutModifyingElabMetaStateWithInfo <| withRef stx <| Term.withoutErrToSorry do
    let e ← Term.elabTerm stx none
    Term.synthesizeSyntheticMVars (mayPostpone := false) (ignoreStuckTC := true)
    let e ← instantiateMVars e
    let abstres ← abstractMVars e
    let e := abstres.expr
    let paramNames := abstres.paramNames
    return (← inferType e, e, paramNames)

def collectAssumptions (facts : Array Term) : TacticM (List (Expr × Expr × Array Name)) := do
  let mut formulas := []
  -- Load all local decls:
  for fVarId in (← getLCtx).getFVarIds do
    let ldecl ← Lean.FVarId.getDecl fVarId
    unless ldecl.isAuxDecl ∨ not (← instantiateMVars (← inferType ldecl.type)).isProp do
      formulas := (← instantiateMVars ldecl.type, ← mkAppM ``eq_true #[mkFVar fVarId], #[]) :: formulas
  -- load user-provided facts
  for facts in ← facts.mapM elabFact do
    for (fact, proof, params) in facts do
      if ← isProp fact then
        formulas := (fact, ← mkAppM ``eq_true #[proof], params) :: formulas
      else
        throwError "invalid fact for duper, proposition expected {indentExpr fact}"

  return formulas

syntax (name := duper) "duper" (colGt ident)? ("[" term,* "]")? : tactic

macro_rules
| `(tactic| duper) => `(tactic| duper [])

-- Add the constant `skolemSorry` to the environment.
-- Add suitable number of trailing underscores to avoid name conflict.
def addSkolemSorry : CoreM Name := do
  let mut nameS := "skolemSorry"
  let env := (← get).env
  let currNameSpace := (← read).currNamespace
  while true do
    let name := Name.str currNameSpace nameS
    if env.constants.contains name then
      nameS := nameS ++ "_"
    else
      break
  let name := Name.str currNameSpace nameS
  let lvlName := `u
  let lvl := Level.param lvlName
  -- Type = ∀ (n : Nat) (α : Sort u), α
  let type := Expr.forallE `n (Expr.const ``Nat []) (
    Expr.forallE `α (Expr.sort lvl) (.bvar 0) .default
  ) .default
  let term := Expr.lam `n (Expr.const ``Nat []) (
    Expr.lam `α (Expr.sort lvl) (
      Expr.app (Expr.app (Expr.const ``sorryAx [lvl]) (.bvar 0)) (Expr.const ``false [])
    ) .default
  ) .default
  let opaqueVal : OpaqueVal := {name := name, levelParams := [lvlName],
                                type := type, value := term, isUnsafe := true, all := [name]}
  let decl : Declaration := (.opaqueDecl opaqueVal)
  match (← getEnv).addDecl decl with
  | Except.ok    env => setEnv env
  | Except.error ex  => throwKernelException ex
  return name

def runDuper (facts : Syntax.TSepArray `term ",") : TacticM ProverM.State := withNewMCtxDepth do
  let formulas ← collectAssumptions facts.getElems
  -- Add the constant `skolemSorry` to the environment
  let skSorryName ← addSkolemSorry
  trace[Meta.debug] "Formulas from collectAssumptions: {formulas}"
  let (_, state) ←
    ProverM.runWithExprs (s := {lctx := ← getLCtx, mctx := ← getMCtx, skolemSorryName := skSorryName})
      ProverM.saturateNoPreprocessingClausification
      formulas
  return state

def evalDuperUnsafe : Tactic
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

-- We save the `CoreM` state. This is because we will add a constant
-- `skolemSorry` to the environment to support skolem constants with
-- universe levels. We want to erase this constant after the saturation
-- procedure ends
def withoutModifyingCoreEnv (m : TacticM α) : TacticM α := do
  let coreEnv := (← liftM (get : CoreM Core.State)).env
  try
    -- Add the `skolemSorry` constant
    let a ← m
    liftM (modify (fun s => {s with env := coreEnv}) : CoreM Unit)
    return a
  catch e =>
    liftM (modify (fun s => {s with env := coreEnv}) : CoreM Unit)
    throw e

@[tactic duper]
def evalDuper : Tactic
| `(tactic| $stx) => withoutModifyingCoreEnv <|
  evalDuperUnsafe stx

syntax (name := duper_no_timing) "duper_no_timing" ("[" term,* "]")? : tactic

macro_rules
| `(tactic| duper_no_timing) => `(tactic| duper_no_timing [])

def evalDuperNoTimingUnsafe : Tactic
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

@[tactic duper_no_timing]
def evalDuperNoTiming : Tactic
| `(tactic| $stx) => withoutModifyingCoreEnv <|
  evalDuperNoTimingUnsafe stx

end Lean.Elab.Tactic