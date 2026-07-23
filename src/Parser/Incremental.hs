module Parser.Incremental
  ( ParseSuccess (..)
  , ParseOutcome (..)
  , runParser
  , parseSentence
  , rightReachableCategories
  ) where

import CCG.Category (CategoryId)
import CCG.CategoryStore (CategoryStore)
import CCG.Combinator (Combinator (..), applicationResults, compositionResults)
import CCG.Derivation
  ( DerivationArena, DerivationNode (..), DerivationRef, addDerivation, emptyArena )
import CCG.TypeRaising (TypeRaisingTemplate (..), raiseCategory)
import Data.List (sortBy)
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Map.Strict as Map
import Data.Maybe (mapMaybe)
import Data.Ord (comparing)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Lexicon.Types (Lexicon, categoriesForWord)
import Lexicon.Candidate (boundedCategoryUniverse)
import Parser.Config
import Parser.FailureFrontier (ParseFailure, makeFailure)
import Parser.State

data ParseSuccess = ParseSuccess
  { successfulLevel :: !ParseLevel
  , rootDerivation :: !DerivationRef
  , successfulCost :: !ParseCost
  , parseCount :: !Int
  , finalArena :: !DerivationArena
  , finalStore :: !CategoryStore
  } deriving (Eq, Show)

data ParseOutcome = Parsed !ParseSuccess | Failed !ParseFailure deriving (Eq, Show)

parseSentence :: Config -> CategoryStore -> Lexicon -> [TypeRaisingTemplate] -> CategoryId -> [Text] -> ParseOutcome
parseSentence config store lexicon templates root tokens = tryLevels [ApplicationOnly, WithComposition, WithTypeRaising]
  where
    tryLevels [] = Failed (makeFailure tokens [])
    tryLevels (level : levels) = case runParser config level store lexicon templates root tokens of
      success@Parsed{} -> success
      failure@Failed{} -> if null levels then failure else tryLevels levels

runParser :: Config -> ParseLevel -> CategoryStore -> Lexicon -> [TypeRaisingTemplate] -> CategoryId -> [Text] -> ParseOutcome
runParser config level initialStore lexicon templates root tokens =
  let (states, arena, finalStore') = foldl' shiftPosition ([initialState level], emptyArena, preparedStore) (zip [0 ..] tokens)
      complete = [state | state <- states, map itemCategory (categoryStack state) == [root]]
   in case sortBy (comparing parseCost <> comparing semanticKey) complete of
        winner : _ -> case categoryStack winner of
          item : _ -> Parsed (ParseSuccess level (itemDerivation item) (parseCost winner) (boundedParseCount winner) arena finalStore')
          [] -> Failed (makeFailure tokens states)
        [] -> Failed (makeFailure tokens states)
  where
    parserConfig = parser config
    ruleConfig = rules config
    (_, boundedStore) = boundedCategoryUniverse (categories config) initialStore
    preparedStore = foldl' preInternTemplate boundedStore templates
    rightReachable = rightReachableCategories preparedStore lexicon tokens
    preInternTemplate store template = maybe store snd (raiseCategory template store (sourceCategory template))

    shiftPosition (states, arena, store) (position, token) =
      let (shifted, arena', store') = foldl' (shiftOne position token) ([], arena, store) states
          closed = concatMap (closure store') shifted
       in (prune closed, arena', store')

    shiftOne position token (acc, arena, store) state =
      foldl' (makeShift state position token) (acc, arena, store) (categoriesForWord token lexicon)

    makeShift state position token (acc, arena, store) categoryId =
      let (lexRef, arena') = addDerivation (LexicalNode position token categoryId) arena
          cost = parseCost state
          cost' = cost { derivationSteps = derivationSteps cost + 1 }
          item = StackItem categoryId lexRef (Just position)
          shifted = state { inputPosition = position + 1, categoryStack = item : categoryStack state, parseCost = cost' }
       in if length (categoryStack shifted) <= maxStackDepth parserConfig
            then (shifted : acc, arena', store)
            else (acc, arena', store)

    closure store state = go 0 [state] [state]
      where
        go depth frontier accumulated
          | depth >= maxReductionsPerShift parserConfig = accumulated
          | otherwise =
              let next = concatMap (reduceTop store) frontier
               in if null next then accumulated else go (depth + 1) next (next ++ accumulated)

    reduceTop store state = case categoryStack state of
      right : left : rest ->
        let application = filter enabledApplication (applicationResults store (itemCategory left) (itemCategory right))
            composition = if level >= WithComposition && null application
              then filter (usefulComposition state) . filter enabledComposition $
                compositionResults store (itemCategory left) (itemCategory right)
              else []
            fusedRaising = if level >= WithTypeRaising && null application
              then filter (usefulComposition state) (fusedTypeRaisingComposition store left right)
              else []
         in mapMaybe (buildReduction state left right rest False) application
              ++ mapMaybe (buildReduction state left right rest False) composition
              ++ mapMaybe (buildReduction state left right rest True) fusedRaising
      _ -> []

    usefulComposition state (_, result, resultStore) =
      any (not . null . applicationResults resultStore result)
        (Set.toAscList (IntMap.findWithDefault Set.empty (inputPosition state) rightReachable))

    fusedTypeRaisingComposition store left right =
      raiseLeft ++ raiseRight
      where
        raiseLeft = case itemTypeRaisingPosition left of
          Nothing -> []
          Just _ -> concatMap (composeRaisedLeft store right . raiseCategoryFor left) templates
        raiseRight = case itemTypeRaisingPosition right of
          Nothing -> []
          Just _ -> concatMap (composeRaisedRight store left . raiseCategoryFor right) templates
        raiseCategoryFor item template = raiseCategory template store (itemCategory item)
        composeRaisedLeft _ _ Nothing = []
        composeRaisedLeft _ other (Just (raisedId, raisedStore)) =
          filter enabledComposition (compositionResults raisedStore raisedId (itemCategory other))
        composeRaisedRight _ _ Nothing = []
        composeRaisedRight _ other (Just (raisedId, raisedStore)) =
          filter enabledComposition (compositionResults raisedStore (itemCategory other) raisedId)

    enabledApplication (ForwardApplication, _, _) = allowForwardApplication ruleConfig
    enabledApplication (BackwardApplication, _, _) = allowBackwardApplication ruleConfig
    enabledApplication _ = False
    enabledComposition (ForwardComposition, _, _) = allowForwardComposition ruleConfig
    enabledComposition (BackwardComposition, _, _) = allowBackwardComposition ruleConfig
    enabledComposition _ = False

    buildReduction state _ right rest usedTypeRaising (combinator, result, _) =
      let isComposition = combinator `elem` [ForwardComposition, BackwardComposition]
          -- Reduction results are constituents, never lexical TR candidates.  Fused TR
          -- therefore cannot leave a raised category or a pending constraint in the beam.
          item = StackItem result (itemDerivation right) Nothing
          cost = parseCost state
          cost' = cost
            { typeRaisingUses = typeRaisingUses cost + if usedTypeRaising then 1 else 0
            , compositionUses = compositionUses cost + if isComposition then 1 else 0
            , derivationSteps = derivationSteps cost + if usedTypeRaising then 2 else 1
            }
       in Just state { categoryStack = item : rest, parseCost = cost' }

    prune = take (min (beamWidth parserConfig) (maxStatesPerPosition parserConfig)) . dedupe . sortBy stateOrder
    stateOrder = comparing parseCost <> comparing semanticKey
    dedupe = Map.elems . foldl' insertBest Map.empty
    insertBest acc state = Map.insertWith choose (semanticKey state) state acc
    choose new old
      | parseCost new < parseCost old = new { boundedParseCount = capped }
      | otherwise = old { boundedParseCount = capped }
      where capped = min (parseCountCap parserConfig) (boundedParseCount new + boundedParseCount old)

-- | For each token position, collect every category derivable from a non-empty
-- prefix of the remaining input using Application only.  Composition uses this
-- bounded chart as a conservative right-context usefulness test.
rightReachableCategories :: CategoryStore -> Lexicon -> [Text] -> IntMap.IntMap (Set CategoryId)
rightReachableCategories store lexicon tokens =
  IntMap.fromAscList
    [ (start, Set.unions [cell start end chart | end <- [start + 1 .. tokenCount]])
    | start <- [0 .. tokenCount - 1]
    ]
  where
    tokenCount = length tokens
    bases = Map.fromList
      [ ((position, position + 1), Set.fromList (categoriesForWord token lexicon))
      | (position, token) <- zip [0 ..] tokens
      ]
    chart = foldl' addLength bases [2 .. tokenCount]
    addLength cells spanLength = foldl' (addSpan spanLength) cells [0 .. tokenCount - spanLength]
    addSpan spanLength cells start =
      let end = start + spanLength
          derived = Set.fromList
            [ result
            | split <- [start + 1 .. end - 1]
            , left <- Set.toAscList (cell start split cells)
            , right <- Set.toAscList (cell split end cells)
            , (_, result, _) <- applicationResults store left right
            ]
       in Map.insert (start, end) derived cells
    cell start end = Map.findWithDefault Set.empty (start, end)
