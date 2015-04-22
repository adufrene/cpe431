module Mini.Iloc.Expr where
    
import Data.HashMap.Strict
import Data.Maybe
import Data.List
import Mini.Types
import Mini.TypeCheck
import Mini.Iloc.Types

{-
converts an expression to ILOC and supplies register where result is

params:
  Expression - expression to evaluate as ILOC
  RegHash - maps local vars to the register they live in
  GlobalEnv - environment for global vars
  LocalEnv - environment for local vars
  Reg - next register to use when we need a new register

returns:
  The evaluated Iloc and the register containing the result of this expression

assumes no registers are used greater than result register
-}
evalExpr :: Expression -> Baggage -> Reg -> IlocRet
evalExpr expr@BinExp{} = evalBinopExpr expr
evalExpr expr@UExp{} = evalUopExpr expr
evalExpr expr@DotExp{} = evalDotExpr expr
evalExpr expr@InvocExp{} = evalInvocExpr expr
evalExpr expr@IdExp{} = \(_, _, regHash) reg -> evalIdExpr expr regHash reg
evalExpr (IntExp _ val) = \_ nextReg -> ([Movi val nextReg], nextReg)
evalExpr (TrueExp _) = \_ nextReg -> ([Movi 1 nextReg], nextReg)
evalExpr (FalseExp _) = \_ nextReg -> ([Movi 0 nextReg], nextReg)
evalExpr expr@NewExp{} = \(global, local, _) reg -> evalNewExpr expr global local reg
evalExpr expr@NullExp{} = \_ nextReg -> ([Movi 0 nextReg], nextReg)

evalBinopExpr :: Expression -> Baggage -> Reg -> IlocRet
evalBinopExpr (BinExp _ binop lhs rhs) baggage nextReg =
   (lhsIloc ++ rhsIloc ++ binopExprs, resultReg)
   where
      (lhsIloc, lhsReg) = evalExpr lhs baggage nextReg
      (rhsIloc, rhsReg) = evalExpr rhs baggage (lhsReg + 1)
      resultReg = rhsReg + 1
      binopExprs
        | binop == "+" = [Add lhsReg rhsReg resultReg]
        | binop == "-" = [Sub lhsReg rhsReg resultReg]
        | binop == "*" = [Mult lhsReg rhsReg resultReg]
        | binop == "/" = [Div lhsReg rhsReg resultReg]
        | binop == "<" = [ Movi 0 resultReg
                         , Comp lhsReg rhsReg
                         , Movlt 1 resultReg]
        | binop == "<=" = [ Movi 0 resultReg
                          , Comp lhsReg rhsReg
                          , Movle 1 resultReg]
        | binop == ">" = [ Movi 0 resultReg
                         , Comp lhsReg rhsReg
                         , Movgt 1 resultReg]
        | binop == ">=" = [ Movi 0 resultReg
                          , Comp lhsReg rhsReg
                          , Movge 1 resultReg]
        | binop == "==" = [ Movi 0 resultReg
                          , Comp lhsReg rhsReg
                          , Moveq 1 resultReg]
        | binop == "!=" = [ Movi 0 resultReg
                          , Comp lhsReg rhsReg
                          , Movne 1 resultReg]
        | binop == "&&" = [ Movi 1 resultReg
                          , Compi lhsReg 0
                          , Moveq 0 resultReg
                          , Compi rhsReg 0
                          , Moveq 0 resultReg]
        | binop == "||" = [ Movi 0 resultReg
                          , Compi lhsReg 0
                          , Movne 1 resultReg
                          , Compi rhsReg 0
                          , Moveq 1 resultReg]
        | otherwise = error $ "don't know what to do with " ++ binop

evalUopExpr :: Expression -> Baggage -> Reg -> IlocRet
evalUopExpr (UExp _ op operand) baggage nextReg =
   (operandIloc ++ uopIloc, resultReg)
   where
      (operandIloc, operandReg) = evalExpr operand baggage nextReg
      resultReg = operandReg + 1
      uopIloc
         | op == "-" = [Multi operandReg (-1) resultReg]
         | op == "!" = [ Movi 0 resultReg
                       , Compi operandReg 0
                       , Moveq 1 resultReg ]
         | otherwise = error $ "unexpected uop: " ++ op

evalDotExpr :: Expression -> Baggage -> Reg -> IlocRet
evalDotExpr (DotExp _ leftExpr dotId) bag@(globals, locals, regHash) nextReg =
  (recurIloc ++ currIloc, resultReg)
  where
    (recurIloc, leftReg) = evalLeft leftExpr
    currIloc = [Loadai leftReg fieldIdx resultReg]
    structType = getExprTypeOrDieTrying leftExpr globals locals
    structFields = getStructHash globals ! structType
    fieldIdx = fromJust $ elemIndex dotId $ fmap getFieldId structFields
    resultReg = leftReg + 1

    evalLeft leftExpr@(IdExp _ theId) = evalIdExpr leftExpr regHash nextReg
    evalLeft dotExpr = evalDotExpr dotExpr bag nextReg

getExprTypeOrDieTrying :: Expression -> GlobalEnv -> LocalEnv -> Type
getExprTypeOrDieTrying expr global local = extractTypeFromEither $ getExprType expr global local
  where
    extractTypeFromEither (Right t) = t

evalInvocExpr :: Expression -> Baggage -> Reg -> IlocRet
evalInvocExpr (InvocExp _ invocId args) = evalInvoc invocId args

evalInvoc :: Id -> Arguments -> Baggage -> Reg -> IlocRet
evalInvoc invocId args baggage nextReg =
  (argsIloc ++ outArgIloc ++ callIloc, retReg)
  where
    (argsIloc, argsRegs) = evalInvocArgs args [] [] baggage nextReg
    outArgIloc = [Storeoutargument (argsRegs !! idx) idx | idx <- [0..(length argsRegs - 1)]]
    callIloc = [ Call invocId
               , Loadret retReg ]
    retReg = 1 + last argsRegs

evalInvocArgs :: Arguments -> [Iloc] -> [Reg] -> Baggage -> Reg -> ([Iloc], [Reg])
evalInvocArgs (arg:rest) currIloc currRegs baggage nextReg =
  evalInvocArgs rest (currIloc ++ argIloc) (currRegs ++ [argReg]) baggage  (argReg + 1)
  where
    (argIloc, argReg) = evalExpr arg baggage nextReg
evalInvocArgs _ currIloc currRegs _ _ = (currIloc, currRegs)
  

evalIdExpr :: Expression -> RegHash -> Reg -> IlocRet
evalIdExpr (IdExp _  theId) regHash nextReg
  | isLocal = evalLocalIdExpr
  | otherwise = evalGlobalIdExpr
  where
    isLocal = theId `member` regHash
    evalLocalIdExpr = ([Mov varReg nextReg], nextReg)
      where
        varReg = regHash ! theId
    evalGlobalIdExpr = ([Loadglobal theId nextReg], nextReg)

evalNewExpr :: Expression -> GlobalEnv -> LocalEnv -> Reg -> IlocRet
evalNewExpr (NewExp _ newId) global local nextReg =
  ([New numWords nextReg], nextReg)  
  where numWords = length $ getStructHash global ! newId
