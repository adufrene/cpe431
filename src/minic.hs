module Main where

import Control.Applicative
import Control.Arrow (second)
import Control.Monad
import Data.Aeson
import qualified Data.ByteString.Lazy.Char8 as BS 
import Data.List
import Data.Maybe
import qualified Data.HashMap.Strict as HM
import System.Environment
import System.FilePath

import Mini.Asm.Types
import Mini.Graph
import Mini.CFG
import Mini.Parser
import Mini.Iloc.Types
import Mini.Optimize
import Mini.Types
import Mini.TypeCheck
import Mini.RegAlloc
import Mini.CopyProp
import Mini.LVN

testJSON :: String
testJSON = "--testJSON"

printProg :: String
printProg = "--printProgram"

printEnv :: String
printEnv = "--printEnv"

printGraphs :: String
printGraphs = "--printGraphs"

testAlloc :: String
testAlloc = "--testAlloc"

dumpIL :: String
dumpIL = "--dumpIL"

noAlloc :: String
noAlloc = "--noAlloc"

checkColors :: String
checkColors = "--checkColors"

noUCR :: String
noUCR = "--noUCR"

noCP :: String
noCP = "--noCP"

printDefs :: String
printDefs = "--printDefs"

printMarks :: String
printMarks = "--printMarks"

noLVN :: String
noLVN = "--noLVN"

optList :: [(String, IlocGraph -> IlocGraph)]
optList = [ (noCP, copyPropOptimize)
          , (noUCR, removeUselessCode) ]

main :: IO ()
main = do
        args <- getArgs
        let fileName = safeGetFile args
        file <- readFile fileName
        let program = parse file
        when (testJSON `elem` args) $ 
            putStrLn $ BS.unpack $ encode program
        when (printProg `elem` args) $ print program
        let env = checkTypes program
        when (printEnv `elem` args) $ print env
        when (shouldPrint args) $
            do 
               globalEnv <- envReport env
               let graphs = globalEnv `createGraphs` program
                   copied = getOptFun noCP args <$> graphs
                   removed = getOptFun noUCR args <$> copied
--                    numberFun = if noLVN `elem` args then numberGraph else id
                   optimized = foldLVN 0 removed args
               if printDefs `elem` args
               then print $ createReachingDefs <$> copied
               else if printMarks `elem` args
               then print $ debugMarked <$> copied
               else if printGraphs `elem` args
               then print optimized
               else if testAlloc `elem` args
               then print $ fmap testIntGraph optimized
               else if checkColors `elem` args
               then print $ fmap getRegLookup optimized
               else if dumpIL `elem` args
               then writeIloc optimized $ fileNameToIL fileName
               else writeAsm (noAlloc `notElem` args) optimized 
                     (getDeclarations program) $ fileNameToS fileName 

foldLVN :: Reg -> [IlocGraph] -> [String] -> [IlocGraph]
foldLVN nextReg graphs args
    | noLVN `elem` args = graphs
    | otherwise = snd $ foldl' foldFun (nextReg, []) graphs
    where foldFun (next, il) graph = second (:il) $ numberGraph next graph

getOptFun :: String -> [String] -> IlocGraph -> IlocGraph
getOptFun flag args = if flag `elem` args
                           then id
                           else fromJust $ lookup flag optList

shouldPrint :: [String] -> Bool
shouldPrint = not . any (\x -> x `elem` [testJSON, printProg, printEnv])

envReport :: Either ErrType GlobalEnv -> IO GlobalEnv
envReport (Left msg) = error msg
envReport (Right env) = return env

fileNameToIL :: String -> String
fileNameToIL oldFile = takeBaseName oldFile ++ ".il"

writeIloc :: [IlocGraph] -> String -> IO ()
writeIloc graphs fileName = do
        let print = foldl' (\msg ng -> msg ++ "\n" ++ showNodeGraph ng) "" graphs
        writeFile fileName print

fileNameToS :: String -> String
fileNameToS oldFile = takeBaseName oldFile ++ ".s"

writeAsm :: Bool -> [IlocGraph] -> [Declaration] -> String -> IO ()
writeAsm shouldAlloc graphs decls fileName = writeFile fileName print 
    where regHashes = fmap getRegLookup graphs
          funAsms = (if shouldAlloc
                        then colorProgramToAsm regHashes
                        else programToAsm) graphs decls
          print = foldl' (\msg insn -> msg ++ show insn ++ "\n") 
                    "" funAsms

safeGetFile :: [String] -> String
safeGetFile args
    | null fileList = error "Please provide mini file as argument"
    | otherwise = head fileList
    where fileList = filter (not . isPrefixOf "--") args
