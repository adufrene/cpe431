module Mini.CFG where

{-
- Functions for converting a function/list of statements into a Control
- Flow Graph made up of iloc instructions. Assumptions made in this module:
-
- Yes NodeGraph means that graph is guaranteed to hit an explicit return
- statement
-
- No NodeGraph means that at least one path taken in graph will result in
- no explicit return statement
-
- The '0' Vertex is the entry node to a function, and will point to the
- first node that will be run
-
- The '-1' Vertex is the exit node to a function, and anything pointing to
- it will return from the function
-
- Any True/False forks in graph will follow convention where true branch is
- the lower-numbered vertex of the two children. False branch will be the
- higher-numbered child.
-
- A node is a list of iloc instructions or statements in reverse order
-}

import Control.Applicative hiding (empty)
import Control.Arrow
import Control.Monad
import Data.Array
import Data.Either
import Data.Graph
import Data.Maybe
import Data.List (nub)
import Data.HashMap.Strict hiding (filter)
import Mini.Iloc
import Mini.Types

data YesNo a = Yes a | No a

instance Functor YesNo where
        fmap f (Yes a) = Yes $ f a
        fmap f (No a) = No $ f a

instance Monad YesNo where
        return = Yes
        (Yes x) >>= f = f x
        (No x) >>= f = No $ getData $ f x

instance Applicative YesNo where
        pure = return
        (<*>) = ap

-- Node will keep statements/iloc in reverse order
-- i.e. elements will be prepended to given node
-- MUCH more efficient
type Node = [Statement] -- [Iloc]

-- Entry point will be Vertex 0?
-- Exit point will be Vertex -1?
type NodeGraph = (Graph, HashMap Vertex Node)
type RegHash = HashMap Id Reg

emptyNode :: Node
emptyNode = []

initVertex :: Vertex
initVertex = 1

exitVertex :: Vertex
exitVertex = -1

entryVertex :: Vertex
entryVertex = 0

defaultBounds :: Bounds
defaultBounds = (exitVertex, initVertex)

createGraphs :: Program -> [NodeGraph]
createGraphs = fmap functionToGraph . getFunctions

functionToGraph :: Function -> NodeGraph
functionToGraph func = 
        getData $ stmtsToGraph argNode (getFunBody func) argHash
    where argNode = emptyNode -- Start node by storing args in regs
          argHash = empty -- create HashMap from args

-- Append 2nd graph to first one, 
-- creating edge from vertices arguments to Graph 2's Vertex 0's child
-- and transposing all of Graph 2's vertices by Graph 1's upper bound
-- If Graph 2 doesn't have a '0 child' then two graphs will not have an
-- edge connecting them
appendGraph :: NodeGraph -> [Vertex] -> NodeGraph -> NodeGraph
appendGraph (graph1, map1) vertices (graph2, map2) = 
        (buildG (exitVertex, newUpperB) newEdges, map1 `union` newMap2)
    where g1Upper = snd $ bounds graph1
          newUpperB = g1Upper + snd (bounds graph2)
          newEdges2 = fmap mapFun (edges graph2)
          replacedEdges = concat 
            (replaceFun <$> filter((==entryVertex) . fst) newEdges2)
          newEdges = edges graph1 ++ 
            filter ((/=entryVertex) . fst) newEdges2 ++ replacedEdges
          newMap2 = fromList 
            ((\(k, v)->(k+g1Upper,v)) <$> toList map2)
          mapFun = moveVertex *** moveVertex 
          replaceFun (_, v) = (\x -> (x,v)) <$> vertices
          moveVertex v = if v `notElem` [exitVertex, entryVertex]
                             then v + g1Upper
                             else v

-- RegHash will be important once we translate statements to iloc
-- Need a better function name
-- Yes means we will return in this graph
-- No means we may not return in this graph
stmtsToGraph :: Node -> [Statement] -> RegHash -> YesNo NodeGraph -- (NodeGraph, RegHash)
stmtsToGraph node [] hash = No $ fromNode node
stmtsToGraph node (stmt:rest) hash = 
        case stmt of
            Block body -> stmtsToGraph node (body ++ rest) hash
            Cond{} -> createCondGraph stmt node successorGraph hash
            Loop{} -> createLoopGraph stmt node successorGraph hash
            Ret _ expr -> Yes pointToExit
            _ -> stmtsToGraph newNode rest hash
    where successorGraph = stmtsToGraph emptyNode rest hash
          pointToExit = 
            (buildG defaultBounds 
                [(entryVertex,initVertex), (initVertex,exitVertex)],
                singleton initVertex newNode)
          newNode = stmt:node

-- Yes means we will return in this graph
-- No means we may not return in this graph
createCondGraph :: Statement -> Node -> YesNo NodeGraph -> RegHash -> YesNo NodeGraph
createCondGraph (Cond _ guard thenBlock maybeElseBlock) node nextGraph hash = 
        runIf Yes (\x -> appendGraph x ifVertices <$> nextGraph) ifGraph
    where newNode = node -- finish node with guard
          ifThenGraph = appendIf <$> graphFromBlock thenBlock
          appendIf = appendGraph (fromNode newNode) [initVertex]
          graphFromBlock block = stmtsToGraph emptyNode (getBlockStmts block) hash
          graphEnd g = snd $ bounds $ fst $ getData g
          ifVertices = nub $ fmap graphEnd [ifThenGraph, ifGraph]
          ifGraph = 
            case maybeElseBlock of
                Just elseBlock -> appendGraph <$> ifThenGraph <*> 
                    pure [initVertex] <*> graphFromBlock elseBlock
                Nothing -> ifThenGraph


createLoopGraph :: Statement -> Node -> YesNo NodeGraph -> RegHash -> YesNo NodeGraph 
createLoopGraph (Loop _ guard body) node nextGraph hash = 
        appendGraph cyclicTG [initVertex, ctgEnd] <$> nextGraph
    where newNode = node -- finish node with guard
          startGraph = fromNode newNode
          -- start with node checking loop condition
          bodyGraph = stmtsToGraph emptyNode (getBlockStmts body) hash
          trueGraph = appendGraph startGraph [initVertex] $ 
            getData bodyGraph
          trueChild = snd $ head $ filter ((==initVertex) . fst) $ 
            edges $ fst trueGraph
          cyclicTG = trueGraph `addEdge` (trueChild, initVertex)
          ctgEnd = snd $ bounds $ fst cyclicTG

fromNode :: Node -> NodeGraph
fromNode node = (buildG defaultBounds [(entryVertex,initVertex)], 
                    singleton initVertex node)

addEdge :: NodeGraph -> Edge -> NodeGraph
addEdge (graph, hash) edge = (buildG (bounds graph) (edge:edges graph), hash)

-- If 3rd arg is yes, run 1st function
-- else run 2nd function
runIf :: (a -> b) -> (a -> b) -> YesNo a -> b
runIf f _ (Yes a) = f a
runIf _ f (No a) = f a

getData :: YesNo a -> a
getData (Yes x) = x
getData (No x) = x
