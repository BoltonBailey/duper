import Lean

namespace TPTP

namespace Tokenizer
open Lean

inductive Status :=
| default
| ident
deriving Repr

inductive Token :=
| op (op : String)
| ident (ident : String)
deriving Repr, Inhabited, BEq

def Token.toString : Token → String
| .op a => a
| .ident a => a

structure State where
(status : Status := .default)
(currToken : String := "")
(res : Array Token := #[])
deriving Repr

def tokens := [
  "@", "|", "&", "<=>", "=>", "<=", "<~>", "~|", "~&", ">", "=", "!=",
  "~", ",", "(", ")", "*", "!", "?", "^", ":", "[", "]", "!>"
]

def tokenHashMap : HashSet String := 
  HashSet.empty.insertMany tokens

def tokenPrefixes : HashSet String := 
  HashSet.empty.insertMany $ tokens.bind (fun t => Id.run do
    let mut res := []
    let mut pref := ""
    for c in t.data do
      pref := pref.push c
      res := pref :: res
    return res
)

abbrev TokenizerM := StateRefT State IO

def setStatus (status : Status) : TokenizerM Unit := do
  modify (fun (s : State) => {s with status := status})

def getStatus : TokenizerM Status := do
  return (← get).status

def addToCurrToken (char : Char) : TokenizerM Unit := do
  modify (fun (s : State) => {s with currToken := s.currToken.push char})

def getCurrToken : TokenizerM String := do
  return (← get).currToken
  
def addCurrToken : TokenizerM Unit := do
  modify fun (s : State) => 
    {s with 
      res := s.res.push $ match s.status with | .default => .op s.currToken | .ident => .ident s.currToken, 
      currToken := ""
    }

def finalizeToken : TokenizerM Unit := do
  if (← getCurrToken) != "" then
    match ← getStatus with
    | .default => 
      if tokenHashMap.contains (← getCurrToken)
      then addCurrToken
      else throw $ IO.userError s!"Invalid token: {(← getCurrToken)}"
    | .ident => addCurrToken
    setStatus .default

def tokenizeAux (str : String) : TokenizerM Unit := do
  for char in str.data do
    if char.isWhitespace then
        finalizeToken
    else
      match ← getStatus with
      | .default =>
        if char.isAlpha || char == '$' then
          finalizeToken
          setStatus .ident
          addToCurrToken char
        else if tokenPrefixes.contains ((← getCurrToken).push char) then
          addToCurrToken char
        else if tokenPrefixes.contains (⟨[char]⟩) then
          finalizeToken
          addToCurrToken char
        else throw $ IO.userError s!"Invalid token: {char}"
      | .ident => 
        if char.isAlpha
        then addToCurrToken char
        else
          finalizeToken
          addToCurrToken char
          setStatus .default
  
  finalizeToken

  def tokenize (s : String) : IO (Array Token) := do
    return (← (tokenizeAux s).run {}).2.res

end Tokenizer

namespace Parser
open Tokenizer
/- Pratt parser following `https://matklad.github.io/2020/04/13/simple-but-powerful-pratt-parsing.html`-/

structure State where
(tokens : Array Token)
(curr : Nat := 0)
deriving Repr


abbrev ParserM := StateRefT State IO

def peek : ParserM Token := do
  let i := (← get).curr
  let ts := (← get).tokens
  if i >= ts.size then throw $ IO.userError "Unexpected end of file"
  return ts[i]!

def next : ParserM Token := do
  let c ← peek
  modify (fun (s : State) => {s with curr := s.curr + 1})
  return c

def isEOF : ParserM Bool := do return (← get).curr ==  (← get).tokens.size

def infixBindingPower? : String → Option (Nat × Nat)
| "@" | "|" | "&" | "<=>" | "=>" | "<=" | "<~>" | "~|" | "~&" => (60,61)
| ">" => (61, 60)
| "=" | "!=" => (90, 90)
| _ => none

def prefixBindingPower? : String → Option Nat
| "~" => some 70
| _ => none

inductive Term where
| mk : Token → List Term → Term
deriving Inhabited, Repr

def Term.func : Term → Token := fun ⟨n, _⟩ => n
def Term.args : Term → List Term := fun ⟨_, as⟩ => as

partial def parseTerm (minbp : Nat := 0) : ParserM Term := do
  let parseLhs : ParserM Term := do
    let nextToken ← next
    if let .ident _ := nextToken then
      return Term.mk nextToken [] 
    if nextToken == .op "(" then
      let lhs ← parseTerm 0
      let nextToken ← next
      if nextToken != .op ")" then throw $ IO.userError s!"Expected ')', got '{repr nextToken}'"
      return lhs
    else if let some rbp := prefixBindingPower? nextToken.toString then
        let rhs ← parseTerm rbp
        return Term.mk nextToken [rhs]
    else
      throw $ IO.userError s!"Expected term, got '{repr nextToken}'"
  let rec addOpAndRhs (lhs : Term) : ParserM Term := do
      if ← isEOF then
        return lhs
      else
        let op ← peek
        let some (lbp, rbp) := infixBindingPower? op.toString
          | return lhs
        if lbp < minbp then
          return lhs
        else
          let op ← next
          let rhs ← parseTerm rbp
          return ← addOpAndRhs (Term.mk op [lhs, rhs])
          
  let lhs ← parseLhs 
  let res ← addOpAndRhs lhs
  return res

def parse (s : String) : IO Term := do
  let tokens ← Tokenizer.tokenize s
  let res ← parseTerm.run {tokens}
  return res.1


open Tokenizer
#eval tokenize "(a)"
#eval parse "(a)"



end Parser

open Parser
open Lean
open Meta

def Parser.Term.toLeanExpr (t : Parser.Term) : MetaM Expr := do
  match t with
  | ⟨.ident n, []⟩ => return mkConst n
  | ⟨.op "=", [a, b]⟩ =>
    let a ← a.toLeanExpr
    let b ← b.toLeanExpr
    return ← mkEq a b
  | ⟨.op "!=", [a, b]⟩ =>
    let a ← a.toLeanExpr
    let b ← b.toLeanExpr
    return ← mkAppM `Ne #[a, b]
  | _ => throwError ":-( {repr t}"

def toLeanExpr (s : String) : MetaM Expr := do
  let t ← Parser.parse s
  return ← t.toLeanExpr

#eval toLeanExpr "Nat != Nat"

end TPTP