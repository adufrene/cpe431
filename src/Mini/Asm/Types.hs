{-# LANGUAGE DeriveDataTypeable #-}

module Mini.Asm.Types 
        ( Asm
        , programToAsm
        , colorProgramToAsm
        , AsmReg (..)
        , RegLookup
        , argRegs
        , numArgRegs
        , calleeSaved
        , callerSaved
        , returnReg
        , getSrcAsmRegs
        , getDstAsmRegs
        ) where

import Control.Applicative
import Data.Char
import Data.Data
import Data.Graph
import Data.HashMap.Strict ((!), HashMap)
import Data.List (intercalate, elem, concatMap, minimum, intersect, foldl', delete, nub)

import Mini.Graph
import Mini.Iloc.Types
import Mini.Types

data AsmSrc = AsmSOReg OffsetReg
            | AsmSReg AsmReg
            | AsmImmed Immed
            | AsmSLabel Label
            | AsmSAddr Label
            deriving (Eq)

data AsmDest = AsmDOReg OffsetReg
             | AsmDReg AsmReg
             | AsmDLabel Label
             | AsmDAddr Label
             deriving (Eq)

data CompArg = CompReg AsmReg
             | CompImm Immed 
             deriving (Eq)

data AsmReg = Rax
            | Rbx
            | Rcx
            | Rdx
            | Rsp
            | Rbp
            | Rsi
            | Rdi
            | R8
            | R9
            | R10
            | R11
            | R12
            | R13
            | R14
            | R15
            | Rip
            | LocalReg Immed
            | RegNum Reg
            deriving (Eq, Data, Typeable, Ord)

data OffsetReg = OffsetReg AsmReg Immed deriving (Eq)

instance Show AsmReg where
        show (RegNum i) = "r" ++ show i
        show (LocalReg i) = show (-i * wordSize) ++ "(%rbp)"
        show reg = "%" ++ map toLower (show $ toConstr reg)

instance Show OffsetReg where
        show (OffsetReg r 0) = "(" ++ show r ++ ")"
        show (OffsetReg r i) = show (wordSize * i) ++ "(" ++ show r ++ ")"

data Asm = AsmPush AsmReg
         | AsmPop AsmReg
         | AsmShift Immed AsmReg
         | AsmSection
         | AsmText
         | AsmData
         | AsmAlign
         | AsmString String
         | AsmVarSize Label Immed
         | AsmFunSize Label
         | AsmQuad Immed
         | AsmGlobal Label
         | AsmFunGlobal Label
         | AsmType Label AsmType
         | AsmAdd AsmReg CompArg
         | AsmDiv AsmReg
         | AsmMult AsmReg AsmReg
         | AsmMulti Immed AsmReg AsmReg
         | AsmSub AsmReg CompArg
         | AsmCmp CompArg AsmReg
         | AsmJe Label
         | AsmJmp Label
         | AsmCall Label
         | AsmRet
         | AsmMov AsmSrc AsmDest
         | AsmCmoveq AsmReg AsmReg
         | AsmCmovgeq AsmReg AsmReg
         | AsmCmovgq AsmReg AsmReg
         | AsmCmovleq AsmReg AsmReg
         | AsmCmovlq AsmReg AsmReg
         | AsmCmovneq AsmReg AsmReg
         | AsmLabel Label
         | AsmAddSp Immed
         | AsmSubSp Immed
         deriving (Eq)

instance Show Asm where
        show (AsmPush r) = showAsm "pushq" [show r]
        show (AsmPop r) = showAsm "popq" [show r]
        show (AsmShift i r) = showAsm "sarq" [immStr i, show r]
        show AsmSection = "\t.section\t\t.rodata"
        show AsmText = "\t.text"
        show AsmData = "\t.data"
        show AsmAlign = "\t.align 8"
        show (AsmString s) = "\t.string\t\"" ++ s ++ "\""
        show (AsmVarSize l i) = showAsm ".size" [l, show i]
        show (AsmQuad i) = "\t.quad\t" ++ show i
        show (AsmGlobal l) = "\t.comm " ++ l ++ ",8,8"
        show (AsmFunGlobal l) = ".global " ++ l
        show (AsmType l t) = showAsm ".type" [l, show t]
        show (AsmFunSize l) = showAsm ".size" [l, ".-" ++ l]
        show (AsmAdd r arg) = showAsm "addq" [show r, compArgStr arg]
        show (AsmDiv r) = showAsm "idivq" [show r]
        show (AsmMult r1 r2) = showAsm "imulq" [show r1, show r2]
        show (AsmMulti i r1 r2) = showAsm "imulq" [immStr i, show r1, show r2]
        show (AsmSub r arg) = showAsm "subq" [show r, compArgStr arg]
        show (AsmCmp arg r) = showAsm "cmp " [compArgStr arg, show r]
        show (AsmJe l) = showAsm "je  " [l]
        show (AsmJmp l) = showAsm "jmp " [l]
        show (AsmCall l) = showAsm "call" [l]
        show AsmRet = showAsm "ret " []
        show (AsmMov r1 r2) = showAsm "movq" [srcStr r1, destStr r2]
        show (AsmCmoveq r1 r2) = showAsm "cmoveq" [show r1, show r2]
        show (AsmCmovgeq r1 r2) = showAsm "cmovgeq" [show r1, show r2]
        show (AsmCmovgq r1 r2) = showAsm "cmovgq" [show r1, show r2]
        show (AsmCmovleq r1 r2) = showAsm "cmovleq" [show r1, show r2]
        show (AsmCmovlq r1 r2) = showAsm "cmovlq" [show r1, show r2]
        show (AsmCmovneq r1 r2) = showAsm "cmovneq" [show r1, show r2]
        show (AsmLabel l) = l ++ ":"
        show (AsmAddSp i) = showAsm "addq" [immStr i, show Rsp]
        show (AsmSubSp i) = showAsm "subq" [immStr i, show Rsp]

data AsmType = FunctionType 
             | ObjectType
             deriving (Eq,Enum)

instance Show AsmType where
        show FunctionType = functionType
        show ObjectType = objectType

type RegLookup = HashMap Reg AsmReg

regsPerAsm :: Asm -> [AsmReg]
regsPerAsm (AsmPush r) = [r]
regsPerAsm (AsmPop r) = [r]
regsPerAsm (AsmShift i r) = [r]
regsPerAsm (AsmAdd r arg) = r : getAsmFromCmp arg
regsPerAsm (AsmDiv r) = [r]
regsPerAsm (AsmMult r1 r2) = [r1,r2]
regsPerAsm (AsmMulti i r1 r2) = [r1,r2]
regsPerAsm (AsmSub r arg) = r : getAsmFromCmp arg
regsPerAsm (AsmCmp arg r) = r : getAsmFromCmp arg
regsPerAsm (AsmMov r1 r2) = getAsmFromSrc r1 ++ getAsmFromDest r2
regsPerAsm (AsmCmoveq r1 r2) = [r1, r2]
regsPerAsm (AsmCmovgeq r1 r2) = [r1, r2]
regsPerAsm (AsmCmovgq r1 r2) = [r1, r2]
regsPerAsm (AsmCmovleq r1 r2) = [r1, r2]
regsPerAsm (AsmCmovlq r1 r2) = [r1, r2]
regsPerAsm (AsmCmovneq r1 r2) = [r1, r2]
regsPerAsm _ = []

getAsmFromCmp :: CompArg -> [AsmReg]
getAsmFromCmp (CompReg r) = [r]
getAsmFromCmp _ = []

getAsmFromSrc :: AsmSrc -> [AsmReg]
getAsmFromSrc (AsmSReg r) = [r]
getAsmFromSrc (AsmSOReg (OffsetReg r _)) = [r]
getAsmFromSrc _ = []

getAsmFromDest :: AsmDest -> [AsmReg]
getAsmFromDest (AsmDReg r) = [r]
getAsmFromDest (AsmDOReg (OffsetReg r _)) = [r]
getAsmFromDest _ = []

swapRegs :: Asm -> AsmReg -> AsmReg -> Asm
swapRegs asm@(AsmPush r) old new = if r == old then AsmPush new else asm
swapRegs asm@(AsmPop r) old new = if r == old then AsmPop new else asm
swapRegs (AsmShift i r) old new = AsmShift i $ if r == old then new else r
swapRegs asm@(AsmDiv r) old new = if r == old then AsmDiv new else asm
swapRegs asm@(AsmMov r1 r2) old new = AsmMov (swapSReg r1 old new) (swapDReg r2 old new)
swapRegs asm@(AsmMult r1 r2) old new = swap2 AsmMult r1 r2 old new
swapRegs asm@(AsmMulti i r1 r2) old new = swap2 (AsmMulti i) r1 r2 old new
swapRegs asm@(AsmCmoveq r1 r2) old new = swap2 AsmCmoveq r1 r2 old new
swapRegs asm@(AsmCmovgeq r1 r2) old new = swap2 AsmCmovgeq r1 r2 old new
swapRegs asm@(AsmCmovgq r1 r2) old new = swap2 AsmCmovgq r1 r2 old new
swapRegs asm@(AsmCmovleq r1 r2) old new = swap2 AsmCmovleq r1 r2 old new
swapRegs asm@(AsmCmovlq r1 r2) old new = swap2 AsmCmovlq r1 r2 old new
swapRegs asm@(AsmCmovneq r1 r2) old new = swap2 AsmCmovneq r1 r2 old new
swapRegs asm@(AsmAdd r arg) old new = AsmAdd
                                       (if r == old then new else r)
                                       (convertArg arg old new)
swapRegs asm@(AsmSub r arg) old new = AsmSub
                                       (if r == old then new else r)
                                       (convertArg arg old new)
swapRegs asm@(AsmCmp arg r) old new = AsmCmp
                                       (convertArg arg old new)
                                       (if r == old then new else r)
swapRegs asm _ _ = asm

swap2 :: (AsmReg -> AsmReg -> Asm)-> AsmReg -> AsmReg -> AsmReg -> AsmReg -> Asm
swap2 constr r1 r2 old new = constr (if r1 == old then new else r1)
                                    (if r2 == old then new else r2)

convertArg :: CompArg -> AsmReg -> AsmReg -> CompArg
convertArg arg@(CompReg r) old new = if r == old then CompReg new else arg
convertArg arg _ _ = arg

swapSReg :: AsmSrc -> AsmReg -> AsmReg -> AsmSrc
swapSReg reg@(AsmSReg r) old new = if r == old then AsmSReg new else reg
swapSReg reg@(AsmSOReg (OffsetReg r i)) old new = if r == old then AsmSOReg (OffsetReg new i) else reg
swapSReg reg _ _ = reg

swapDReg :: AsmDest -> AsmReg -> AsmReg -> AsmDest
swapDReg reg@(AsmDReg r) old new = if r == old then AsmDReg new else reg
swapDReg reg@(AsmDOReg (OffsetReg r i)) old new = if r == old then AsmDOReg (OffsetReg new i) else reg
swapDReg reg _ _ = reg

{- Create initial global variables and other file-specific data -}
programToAsm :: [IlocGraph] -> [Declaration] -> [Asm]
programToAsm graphs globals = asmProgramHelper globals bodyAsm 
    where bodyAsm = concatMap (functionToAsm RegNum) graphs

colorProgramToAsm :: [RegLookup] -> [IlocGraph] -> [Declaration] -> [Asm]
colorProgramToAsm colorHashes graphs globals = asmProgramHelper globals body
    where body = concatMap (\(g,h) -> functionToAsm (h !) g) $ zip graphs colorHashes

asmProgramHelper :: [Declaration] -> [Asm] -> [Asm]
asmProgramHelper globals bodyAsm = createGlobals ++ bodyAsm
    where createGlobals = concat [ globalString printLabel printStr
                                 , globalString printlnLabel printlnStr
                                 , globalString scanLabel scanStr
                                 , [AsmGlobal scanVar]
                                 , createGlobal <$> globals ]
          createGlobal = AsmGlobal . getDecId 

globalString :: Label -> String -> [Asm]
globalString l s = [ AsmSection
                   , AsmLabel l
                   , AsmString s ]

functionToAsm :: (Reg -> AsmReg) -> IlocGraph -> [Asm]
functionToAsm regFun nodeG@(graph, hash) = prologue ++ body ++ epilogue
    where prologue = createPrologue nodeG ++ stackBegin
          body = concatMap spillVars unfiltered
          regsUsed = concatMap regsPerAsm body
          (stackBegin, stackEnd) = manageStack regsUsed
          unfiltered = concatMap (functionMapFun regFun nodeG) $ topSort graph 
          epilogue = stackEnd ++ createEpilogue nodeG
          filterFun (AsmMov (AsmSReg r1) (AsmDReg r2)) = r1 /= r2
          filterFun _ = True

spillVars :: Asm -> [Asm]
spillVars asm
    | null localRegs = [asm]
    | otherwise = loadRegs ++ [newAsm] ++ storeRegs
    where regsUsed = regsPerAsm asm
          localRegs = [x | x@LocalReg{} <- regsUsed]
          localLookup = zip localRegs tempRegs
          loadRegs = foldl' loadFoldFun [] localLookup
          storeRegs = foldl' storeFoldFun [] localLookup
          loadFoldFun l (r,r') = AsmMov (AsmSReg r) (AsmDReg r') : l
          storeFoldFun l (r,r') = AsmMov (AsmSReg r') (AsmDReg r) : l
          newAsm = foldl' (\a (r,r') -> swapRegs a r r') asm localLookup

functionMapFun :: (Reg -> AsmReg) -> IlocGraph -> Vertex -> [Asm]
functionMapFun regFun nodeG@(graph, hash) x
    | x == entryVertex = []
    | x == exitVertex = labelInsn
    | otherwise = labelInsn ++ concat (ilocToAsm regFun <$> getData node)
    where node = hash ! x
          sv = startVert nodeG
          labelInsn = if x == sv then [] else [AsmLabel $ getLabel node]

manageStack :: [AsmReg] -> ([Asm], [Asm])
manageStack regs = (pushInsns ++ subSp, addSp ++ popInsns)
    where localOffsets = [ i | (LocalReg i) <- regs ]
          totalOffset = abs $ wordSize * (maximum localOffsets + 1)
          savedRegs = nub $ regs `intersect` delete Rbp calleeSaved
          pushInsns = foldl' (\l r -> l ++ [AsmPush r]) [] savedRegs
                        ++ [AsmPush Rbp, AsmMov (AsmSReg Rsp) (AsmDReg Rbp)]
          popInsns = AsmMov (AsmSReg Rbp) (AsmDReg Rsp) : AsmPop Rbp
                        : foldl' (\l r -> AsmPop r : l) [] savedRegs
          (subSp, addSp) = if null localOffsets
                            then ([], [])
                            else ([AsmSubSp totalOffset],
                                 [AsmAddSp totalOffset]) 

createPrologue :: IlocGraph -> [Asm]
createPrologue (graph, hash) = [ AsmText
                               , AsmFunGlobal funLabel
                               , AsmType funLabel FunctionType
                               , AsmLabel funLabel
--                                , AsmPush Rbp
--                                , AsmPush Rbx
--                                , AsmPush Rsp
--                                , AsmPush R12
--                                , AsmPush R13
--                                , AsmPush R14
--                                , AsmPush R15
                               {-, AsmMov (AsmSReg Rsp) (AsmDReg Rbp)-} ]
    where funLabel = funName (graph, hash) 

createEpilogue :: IlocGraph -> [Asm]
createEpilogue (graph, hash) = [ {-AsmMov (AsmSReg Rbp) (AsmDReg Rsp)
--                                , AsmPop R15
--                                , AsmPop R14
--                                , AsmPop R13
--                                , AsmPop R12
--                                , AsmPop Rsp
--                                , AsmPop Rbx
--                                , AsmPop Rbp
                               ,-} AsmRet
                               , AsmFunSize $ funName (graph, hash)]

functionType :: String
functionType = "@function"

objectType :: String
objectType = "@object"

numArgRegs :: Int
numArgRegs = length argRegs

argRegs :: [AsmReg]
argRegs = [Rdi, Rsi, Rdx, Rcx, R8, R9]

callerSaved :: [AsmReg]
callerSaved = [Rax, Rcx, Rdx, Rsi, Rdi, R8, R9, R10, R11]

calleeSaved :: [AsmReg]
calleeSaved = [Rbx, Rsp, Rbp, R12, R13, R14, R15]

tempRegs :: [AsmReg]
tempRegs = [R13, R14, R15]

returnReg :: AsmReg
returnReg = Rax

wordSize :: Int
wordSize = 8

printLabel :: Label
printLabel = ".PRINT"

printStr :: String
printStr = "%ld "

printlnStr :: String
printlnStr = "%ld\\n"

printlnLabel :: Label
printlnLabel = ".PRINTLN"

printf :: Label
printf = "printf"

scanLabel :: Label
scanLabel = ".SCAN"

scanStr :: String
scanStr = "%ld"

scanVar :: Label
scanVar = ".SCANVAR"

scanf :: Label
scanf = "scanf"

free :: Label
free = "free"

malloc :: Label
malloc = "malloc"

funName :: IlocGraph -> Label
funName ng@(_, hash) = getLabel $ hash ! startVert ng

startVert :: IlocGraph -> Vertex
startVert = snd . head . filter ((==entryVertex) . fst) . edges . fst

srcStr :: AsmSrc -> String
srcStr (AsmSOReg r) = show r
srcStr (AsmImmed i) = immStr i
srcStr (AsmSLabel l) = labStr l
srcStr (AsmSReg r) = show r
srcStr (AsmSAddr l) = addrStr l

destStr :: AsmDest -> String
destStr (AsmDOReg r) = show r
destStr (AsmDLabel l) = labStr l
destStr (AsmDReg r) = show r
destStr (AsmDAddr l) = addrStr l

labStr :: Label -> String
labStr l = l ++ "(%rip)"

addrStr :: Label -> String
addrStr l = "$" ++ l

immStr :: Immed -> String
immStr i = "$" ++ show i

compArgStr :: CompArg -> String
compArgStr (CompReg r) = show r
compArgStr (CompImm i) = immStr i

showAsm :: String -> [String] -> String
showAsm name args = "\t" ++ name ++ "\t" ++ intercalate ", " args

ilocToAsm :: (Reg -> AsmReg) -> Iloc -> [Asm]
ilocToAsm f (Add r1 r2 r3) = createAdd f r1 r2 r3
ilocToAsm f (Div r1 r2 r3) = createDiv f r1 r2 r3
ilocToAsm f (Mult r1 r2 r3) = createMult f r1 r2 r3
ilocToAsm f (Multi r1 i r2) = [ AsmMulti i (f r1) (f r2) ]
ilocToAsm f (Sub r1 r2 r3) = createSub f r1 r2 r3
ilocToAsm f (Comp r1 r2) = [AsmCmp (CompReg $ f r2) (f r1)]
ilocToAsm f (Compi r i) = [AsmCmp (CompImm i) (f r)]
ilocToAsm _ (Jumpi l) = [AsmJmp l]
ilocToAsm f (Brz r l1 l2) = brz f r l1 l2
ilocToAsm f (Loadai r1 i r2) = [AsmMov (AsmSOReg $ OffsetReg (f r1) i) 
                                (AsmDReg $ f r2)]
ilocToAsm f (Loadglobal l r) = [AsmMov (AsmSLabel l) (AsmDReg $ f r)]
ilocToAsm f (Loadinargument l i r) = loadArg f i r
ilocToAsm f (Loadret r) = [AsmMov (AsmSReg returnReg) (AsmDReg $ f r)]
ilocToAsm f (Storeai r1 r2 i) = [AsmMov (AsmSReg $ f r1) 
                                (AsmDOReg $ OffsetReg (f r2) i)] 
ilocToAsm f (Storeglobal r l) = [AsmMov (AsmSReg $ f r) (AsmDLabel l)]
ilocToAsm f (Storeoutargument r i) = storeArg f r i
ilocToAsm f (Storeret r) = [AsmMov (AsmSReg $ f r) (AsmDReg returnReg)]
ilocToAsm _ (Call l) = [AsmCall l]
ilocToAsm _ RetILOC = [AsmRet]
ilocToAsm f (New i r) = createNew f i r
ilocToAsm f (Del r) = createDelete f r
ilocToAsm f (PrintILOC r) = createPrint f r False
ilocToAsm f (Println r) = createPrint f r True
ilocToAsm f (ReadILOC r) = createRead f r
ilocToAsm f (Mov r1 r2) = [AsmMov (AsmSReg $ f r1) 
                            (AsmDReg $ f r2)]
ilocToAsm f (Movi i r) = [AsmMov (AsmImmed i) (AsmDReg $ f r)]
ilocToAsm f (Moveq r1 r2) = [AsmCmoveq (f r1) (f r2)]
ilocToAsm f (Movge r1 r2) = [AsmCmovgeq (f r1) (f r2)]
ilocToAsm f (Movgt r1 r2) = [AsmCmovgq (f r1) (f r2)]
ilocToAsm f (Movle r1 r2) = [AsmCmovleq (f r1) (f r2)]
ilocToAsm f (Movlt r1 r2) = [AsmCmovlq (f r1) (f r2)]
ilocToAsm f (Movne r1 r2) = [AsmCmovneq (f r1) (f r2)]
ilocToAsm _ (PrepArgs i) = [AsmSub Rsp $ CompImm $ wordSize * (i - numArgRegs) | i > numArgRegs]
ilocToAsm _ (UnprepArgs i) = [AsmAdd Rsp $ CompImm $ wordSize * (i - numArgRegs) | i > numArgRegs]
ilocToAsm _ iloc = error $ "No Asm translation for " ++ show iloc

createAdd :: (Reg -> AsmReg) -> Reg -> Reg -> Reg -> [Asm]
createAdd f r1 r2 r3 = [ AsmMov (AsmSReg $ f r1) (AsmDReg $ f r3)
                     , AsmAdd (f r2) (CompReg $ f r3) ]

createDiv :: (Reg -> AsmReg) -> Reg -> Reg -> Reg -> [Asm]
createDiv f r1 r2 r3 = [ AsmMov (AsmSReg $ f r1) (AsmDReg Rdx)
                     , AsmShift 63 Rdx
                     , AsmMov (AsmSReg $ f r1) (AsmDReg Rax)
                     , AsmDiv (f r2)
                     , AsmMov (AsmSReg returnReg) (AsmDReg $ f r3) ]

createMult :: (Reg -> AsmReg) -> Reg -> Reg -> Reg -> [Asm]
createMult f r1 r2 r3 = [ AsmMov (AsmSReg $ f r1) (AsmDReg $ f r3)
                      , AsmMult (f r2) (f r3) ]

createSub :: (Reg -> AsmReg) -> Reg -> Reg -> Reg -> [Asm]
createSub f r1 r2 r3 = [ AsmMov (AsmSReg $ f r1) (AsmDReg $ f r3)
                     , AsmSub (f r2) (CompReg $ f r3) ]

brz :: (Reg -> AsmReg) -> Reg -> Label -> Label -> [Asm]
brz f r l1 l2 = [ AsmCmp (CompImm 0) (f r)
              , AsmJe l1
              , AsmJmp l2 ]

loadArg :: (Reg -> AsmReg) -> Immed -> Reg -> [Asm]
loadArg f i r
    | i < numArgRegs = [AsmMov (AsmSReg $ argRegs !! i) (AsmDReg $ f r)]
    | otherwise = [AsmMov (AsmSOReg $ OffsetReg Rbp offset) (AsmDReg $ f r)]
    where offset = i - numArgRegs + 2

storeArg :: (Reg -> AsmReg) -> Reg -> Immed -> [Asm]
storeArg f r i
    | i < numArgRegs = [AsmMov (AsmSReg $ f r) (AsmDReg $ argRegs !! i)] 
    | otherwise = [AsmMov (AsmSReg $ f r) (AsmDOReg $ OffsetReg Rsp offset)]
    where offset = i - numArgRegs

createNew :: (Reg -> AsmReg) -> Immed -> Reg -> [Asm]
createNew f words res = [ AsmMov (AsmImmed $ words * wordSize) (AsmDReg Rdi)
                      , AsmCall malloc
                      , AsmMov (AsmSReg returnReg) (AsmDReg $ f res) ]

createDelete :: (Reg -> AsmReg) -> Reg -> [Asm]
createDelete f r = [ AsmMov (AsmSReg $ f r) (AsmDReg Rdi)
                 , AsmCall free ]

createPrint :: (Reg -> AsmReg) -> Reg -> Bool -> [Asm]
createPrint f r endl = [ AsmMov (AsmSAddr printString) (AsmDReg Rdi)
                     , AsmMov (AsmSReg $ f r) (AsmDReg Rsi)
                     , AsmMov (AsmImmed 0) (AsmDReg Rax)
                     , AsmCall printf ]
    where printString = if endl then printlnLabel else printLabel

createRead :: (Reg -> AsmReg) -> Reg -> [Asm]
createRead f r = [ AsmMov (AsmSAddr scanLabel) (AsmDReg Rdi)
               , AsmMov (AsmSAddr scanVar) (AsmDReg Rsi)
               , AsmMov (AsmImmed 0) (AsmDReg Rax)
               , AsmCall scanf
               , AsmMov (AsmSLabel scanVar) (AsmDReg $ f r) ]

-- asm registers we will read from for this instuction
getSrcAsmRegs :: Iloc -> [AsmReg]
getSrcAsmRegs (Div r1 r2 r3) = [Rdx, Rax]
getSrcAsmRegs (Loadinargument _ i _) = getArgRegister i
getSrcAsmRegs Call{} = argRegs
getSrcAsmRegs New{} = [Rax, Rdi]
getSrcAsmRegs (Del r1) = [Rdi]
getSrcAsmRegs (PrintILOC r1) = [Rdi, Rsi, Rax]
getSrcAsmRegs (Println r1) = [Rdi, Rsi, Rax]
getSrcAsmRegs ReadILOC{} = [Rdi, Rsi, Rax]
getSrcAsmRegs _ = []

-- get the asm dest registers
getDstAsmRegs :: Iloc -> [AsmReg]
getDstAsmRegs (Div _ _ r3) = [Rax, Rdx]
getDstAsmRegs (Storeoutargument _ i) = getArgRegister i
getDstAsmRegs Call{} = callerSaved
getDstAsmRegs (New _ r1) = callerSaved
getDstAsmRegs Del{} = callerSaved
getDstAsmRegs PrintILOC{} = callerSaved
getDstAsmRegs Println{} = callerSaved
getDstAsmRegs (ReadILOC r) = callerSaved
getDstAsmRegs iloc = []

getArgRegister :: Immed -> [AsmReg]
getArgRegister i
    | i < numArgRegs = [argRegs !! i]
    | otherwise = []
