module Parser.Incremental
  ( ParseSuccess (..)
  , ParseOutcome (..)
  , ReductionRule (..)
  , Reduction (..)
  , runParser
  , parseSentence
  , pairReductions
  , rightReachableCategories
  ) where

import CCG.Category (CategoryId, categoryArity, categoryDepth, categorySlashCount)
import CCG.CategoryStore (CategoryStore, lookupCategory)
import CCG.Combinator (Combinator (..), applicationResults, argumentSwap, compositionResults)
import CCG.Derivation
  ( DerivationArena, DerivationNode (..), DerivationRef, addDerivation, emptyArena )
import CCG.SpecialRules
  ( SpecialCategories (..), coordination, periodAbsorption, punctuationAbsorption )
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

-- | The rule behind one reduction.  Coordination and the two absorption rules
-- belong to the Application level: they are available at every parser level
-- and block Composition on the same pair, like Application.
data ReductionRule
  = CombinatorRule !Combinator
  | CoordinationRule
  | PeriodAbsorptionRule
  | PunctuationAbsorptionRule
  deriving (Eq, Show)

-- | One way to reduce adjacent constituents.
data Reduction = Reduction
  { reductionRule :: !ReductionRule
  , reductionResult :: !CategoryId
  , reductionUsesTypeRaising :: !Bool
  } deriving (Eq, Show)

parseSentence :: Config -> CategoryStore -> Lexicon -> GrammarRules -> CategoryId -> [Text] -> ParseOutcome
parseSentence config store lexicon grammarRules root tokens = tryLevels [ApplicationOnly, WithComposition, WithTypeRaising]
  where
    tryLevels [] = Failed (makeFailure tokens [])
    tryLevels (level : levels) = case runParser config level store lexicon grammarRules root tokens of
      success@Parsed{} -> success
      failure@Failed{} -> if null levels then failure else tryLevels levels

runParser :: Config -> ParseLevel -> CategoryStore -> Lexicon -> GrammarRules -> CategoryId -> [Text] -> ParseOutcome
runParser config level initialStore lexicon grammarRules root tokens =
  let initialStates = [initialState level]
      (states, arena, finalStore', failureFrontier) =
        foldl' shiftPosition (initialStates, emptyArena, chartStore, initialStates) (zip [0 ..] tokens)
      complete = [state | state <- states, map itemCategory (categoryStack state) == [root]]
   in case sortBy (comparing parseCost <> comparing semanticKey) complete of
        winner : _ -> case categoryStack winner of
          item : _ -> Parsed (ParseSuccess level (itemDerivation item) (parseCost winner) (boundedParseCount winner) arena finalStore')
          [] -> Failed (makeFailure tokens failureFrontier)
        [] -> Failed (makeFailure tokens failureFrontier)
  where
    parserConfig = parser config
    ruleConfig = rules config
    special = ruleSpecialCategories grammarRules
    tokenCount = length tokens
    (_, boundedStore) = boundedCategoryUniverse (categories config) initialStore
    preparedStore = foldl' preInternTemplate boundedStore (ruleRaisingTemplates grammarRules)
    preInternTemplate store template = maybe store snd (raiseCategory template store (sourceCategory template))
    -- The chart is only consulted to filter Composition results.
    (rightReachable, chartStore)
      | level >= WithComposition = rightReachableCategories config level grammarRules preparedStore lexicon tokens
      | otherwise = (IntMap.empty, preparedStore)

    -- The category store is threaded through shifting and every reduction so
    -- each derived category is interned exactly once.
    shiftPosition accumulator@([], _, _, _) _ = accumulator
    shiftPosition (states, arena, store, _) (position, token) =
      let (shifted, arena') = foldl' (shiftOne position token) ([], arena) states
          (closedGroups, store') = foldl' closeState ([], store) shifted
          closed = concat (reverse closedGroups)
          pruned = prune closed
       in if null pruned
            then ([], arena', store', states)
            else (pruned, arena', store', pruned)

    shiftOne position token (acc, arena) state =
      foldl' (makeShift state position token) (acc, arena) (categoriesForWord token lexicon)

    makeShift state position token (acc, arena) categoryId =
      let (lexRef, arena') = addDerivation (LexicalNode position token categoryId) arena
          cost = parseCost state
          cost' = cost { derivationSteps = derivationSteps cost + 1 }
          item = StackItem categoryId lexRef True False False
          shifted = state { inputPosition = position + 1, categoryStack = item : categoryStack state, parseCost = cost' }
       in if length (categoryStack shifted) <= maxStackDepth parserConfig
            then (shifted : acc, arena')
            else (acc, arena')

    -- Groups are accumulated in reverse and concatenated once, keeping the
    -- deterministic state order without quadratic appends.
    closeState (groups, store) state =
      let (closed, store') = closure store state
       in (closed : groups, store')

    -- Every state reachable by reducing the stack top keeps both its reduced
    -- and unreduced alternatives, so all bracketings stay in the beam.
    closure store0 state = go (0 :: Int) [state] [state] store0
      where
        go depth frontier accumulated store
          | depth >= maxReductionsPerShift parserConfig = (accumulated, store)
          | otherwise =
              let (nextGroups, store') = foldl' reduceInto ([], store) frontier
                  next = concat (reverse nextGroups)
               in if null next then (accumulated, store') else go (depth + 1) next (next ++ accumulated) store'
        reduceInto (groups, store) current =
          let (reduced, store') = reduceTop store current
           in (reduced : groups, store')

    reduceTop store state =
      let (combined, store') = combineTop store state
          (swapped, store'') = swapTop store' state
       in (combined ++ swapped, store'')

    combineTop store state = case categoryStack state of
      right : left : rest ->
        let (reductions, store') = pairReductions config level grammarRules store
              (itemCategory left, itemRaisable left) (itemCategory right, itemRaisable right)
            kept = filter (keepReduction store' state rest) reductions
            binary = map (buildReduction state right rest) kept
            ternary = case rest of
              leftConjunct : below
                | allowCoordination ruleConfig && not (itemCoordinated leftConjunct)
                , Just result <- coordination special (itemCategory leftConjunct) (itemCategory left) (itemCategory right) ->
                    [coordinated state right below result]
              _ -> []
         in (binary ++ ternary, store')
      _ -> ([], store)

    -- ASP is a unary step on the stack top.  A constituent is swapped right
    -- after it is created, while it is on top; swapping later would make no
    -- difference because nothing can change it before it is combined.
    swapTop store state = case categoryStack state of
      top : rest | allowArgumentSwap ruleConfig && not (itemSwapped top) ->
        case swapWithinBounds config store (itemCategory top) of
          Just (swappedCategory, store') ->
            let cost = parseCost state
                item = top { itemCategory = swappedCategory, itemSwapped = True }
             in ( [ state
                      { categoryStack = item : rest
                      , parseCost = cost
                          { argumentSwapUses = argumentSwapUses cost + 1
                          , derivationSteps = derivationSteps cost + 1
                          }
                      } ]
                , store' )
          Nothing -> ([], store)
      _ -> ([], store)

    keepReduction store state rest reduction = case reductionRule reduction of
      CombinatorRule combinator | not (isApplication combinator) ->
        usefulComposition store state rest (reductionResult reduction)
      _ -> True

    -- A Composition result C on top of the stack at input position p is
    -- kept only if C can still take part in a derivation.  C's first
    -- combination is with the constituent directly below it (which cannot
    -- change before C is reduced), with a constituent built from a prefix of
    -- the remaining input, or as a conjunct next to a CONJ on either side;
    -- otherwise C must already be the complete root.  'rightReachable'
    -- over-approximates the right constituents, so this test never discards a
    -- derivable state.
    --
    -- With ASP, C may be swapped before its first combination, so both forms
    -- of C are tested.
    usefulComposition store state rest result = any useful variants
      where
        variants = (result, store) : case swapWithinBounds config store result of
          Just swapped | allowArgumentSwap ruleConfig -> [swapped]
          _ -> []
        position = inputPosition state
        reachable = IntMap.findWithDefault Set.empty position rightReachable
        useful (candidate, candidateStore) =
          completeRoot candidate || leftUseful candidateStore candidate || rightUseful candidateStore candidate
        completeRoot candidate = null rest && position == tokenCount && candidate == root
        leftUseful candidateStore candidate = case rest of
          left : _ -> combines candidateStore (itemCategory left, itemRaisable left) (candidate, True)
            || isConjunction (itemCategory left)
          [] -> False
        rightUseful candidateStore candidate =
          any (\other -> combines candidateStore (candidate, True) (other, True)) (Set.toAscList reachable)
            || any isConjunction (Set.toAscList reachable)
        combines candidateStore left right =
          not (null (fst (pairReductions config level grammarRules candidateStore left right)))
        isConjunction categoryId =
          allowCoordination ruleConfig && Just categoryId == conjunctionCategory special

    buildReduction state right rest reduction =
      let usedTypeRaising = reductionUsesTypeRaising reduction
          isComposition = case reductionRule reduction of
            CombinatorRule combinator -> not (isApplication combinator)
            _ -> False
          item = StackItem (reductionResult reduction) (itemDerivation right) (not usedTypeRaising) False False
          cost = parseCost state
          cost' = cost
            { typeRaisingUses = typeRaisingUses cost + if usedTypeRaising then 1 else 0
            , compositionUses = compositionUses cost + if isComposition then 1 else 0
            , derivationSteps = derivationSteps cost + if usedTypeRaising then 2 else 1
            }
       in state { categoryStack = item : rest, parseCost = cost' }

    coordinated state right below result =
      let item = StackItem result (itemDerivation right) True True False
          cost = parseCost state
       in state
            { categoryStack = item : below
            , parseCost = cost { derivationSteps = derivationSteps cost + 1 }
            }

    prune = take (min (beamWidth parserConfig) (maxStatesPerPosition parserConfig)) . dedupe . sortBy stateOrder
    stateOrder = comparing parseCost <> comparing semanticKey
    dedupe = Map.elems . foldl' insertBest Map.empty
    insertBest acc state = Map.insertWith choose (semanticKey state) state acc
    choose new old
      | parseCost new < parseCost old = new { boundedParseCount = capped }
      | otherwise = old { boundedParseCount = capped }
      where capped = min (parseCountCap parserConfig) (boundedParseCount new + boundedParseCount old)

-- | Every binary reduction the parser may apply to two adjacent constituents at
-- a level, given whether each side may be type-raised.
--
-- * Application, period absorption and punctuation absorption are available
--   at every level.  When any of them applies, the pair is not composed.
-- * Composition and fused Type-raising are tried only from their levels on.
-- * A raised side must be consumed immediately by Composition, so raised
--   categories never enter the beam on their own.
-- * Composition and Type-raising results must stay within category bounds.
--
-- Coordination is ternary and handled by the callers.  New categories are
-- interned into the returned store.
pairReductions
  :: Config
  -> ParseLevel
  -> GrammarRules
  -> CategoryStore
  -> (CategoryId, Bool)
  -> (CategoryId, Bool)
  -> ([Reduction], CategoryStore)
pairReductions config level grammarRules store (left, leftRaisable) (right, rightRaisable)
  | not (null applicationLevel) = (applicationLevel, store)
  | level < WithComposition = ([], store)
  | otherwise =
      let (composed, store1) = compositionResults degree store left right
          (raised, store2)
            | level >= WithTypeRaising = foldl' raiseAndCompose ([], store1) raisingChoices
            | otherwise = ([], store1)
          plain = [Reduction (CombinatorRule combinator) result False | (combinator, result) <- composed, compositionEnabled combinator]
       in (filter (withinCategoryBounds config store2 . reductionResult) (plain ++ raised), store2)
  where
    ruleConfig = rules config
    special = ruleSpecialCategories grammarRules
    degree = maxCompositionDegree ruleConfig
    applicationLevel = application ++ absorption
    application =
      [ Reduction (CombinatorRule combinator) result False
      | (combinator, result, _) <- applicationResults store left right
      , applicationEnabled combinator
      ]
    absorption = mapMaybe (\(enabled, rule, result) -> if enabled then (\category -> Reduction rule category False) <$> result else Nothing)
      [ (allowPeriodAbsorption ruleConfig, PeriodAbsorptionRule, periodAbsorption special left right)
      , (allowPunctuationAbsorption ruleConfig, PunctuationAbsorptionRule, punctuationAbsorption special store left right)
      ]
    raisingChoices =
      [(True, template) | leftRaisable, template <- ruleRaisingTemplates grammarRules]
        ++ [(False, template) | rightRaisable, template <- ruleRaisingTemplates grammarRules]
    raiseAndCompose (acc, current) (raiseLeft, template) =
      case raiseCategory template current (if raiseLeft then left else right) of
        Nothing -> (acc, current)
        Just (raisedId, raisedStore) ->
          let (composed, composedStore)
                | raiseLeft = compositionResults degree raisedStore raisedId right
                | otherwise = compositionResults degree raisedStore left raisedId
           in ( acc ++ [Reduction (CombinatorRule combinator) result True | (combinator, result) <- composed, compositionEnabled combinator]
              , composedStore )
    applicationEnabled ForwardApplication = allowForwardApplication ruleConfig
    applicationEnabled BackwardApplication = allowBackwardApplication ruleConfig
    applicationEnabled _ = False
    compositionEnabled combinator = case combinator of
      ForwardComposition -> allowForwardComposition ruleConfig
      BackwardComposition -> allowBackwardComposition ruleConfig
      ForwardCrossedComposition -> allowForwardComposition ruleConfig && allowCrossedComposition ruleConfig
      BackwardCrossedComposition -> allowBackwardComposition ruleConfig && allowCrossedComposition ruleConfig
      ForwardGeneralizedComposition -> allowForwardComposition ruleConfig && allowGeneralizedComposition ruleConfig
      BackwardGeneralizedComposition -> allowBackwardComposition ruleConfig && allowGeneralizedComposition ruleConfig
      ForwardGeneralizedCrossedComposition ->
        allowForwardComposition ruleConfig && allowCrossedComposition ruleConfig
          && allowGeneralizedComposition ruleConfig
      BackwardGeneralizedCrossedComposition ->
        allowBackwardComposition ruleConfig && allowCrossedComposition ruleConfig
          && allowGeneralizedComposition ruleConfig
      _ -> False

withinCategoryBounds :: Config -> CategoryStore -> CategoryId -> Bool
withinCategoryBounds config store categoryId =
  categoryDepth (`lookupCategory` store) categoryId <= maxDepth bounds
    && categorySlashCount (`lookupCategory` store) categoryId <= maxSlashes bounds
    && categoryArity (`lookupCategory` store) categoryId <= maxArity bounds
  where bounds = categories config

-- | ASP applied to a category, if its result stays within category bounds.
swapWithinBounds :: Config -> CategoryStore -> CategoryId -> Maybe (CategoryId, CategoryStore)
swapWithinBounds config store categoryId = case argumentSwap store categoryId of
  Just (swapped, store') | withinCategoryBounds config store' swapped -> Just (swapped, store')
  _ -> Nothing

isApplication :: Combinator -> Bool
isApplication combinator = combinator `elem` [ForwardApplication, BackwardApplication]

-- | For each token position, collect every category derivable from a non-empty
-- prefix of the remaining input with the reductions of the given level,
-- including coordination.
--
-- The chart applies the reductions without beam limits, usefulness filtering,
-- or the coordination bracketing restriction, and lets every constituent be
-- raised, so it over-approximates what the beam can build over the same span.
-- That makes it a sound right-context test for Composition results.  Cost is
-- cubic in sentence length times the square of the per-span category count,
-- plus a quartic coordination pass over spans that derive CONJ.  With ASP
-- enabled every cell is closed under argument swapping.
rightReachableCategories
  :: Config
  -> ParseLevel
  -> GrammarRules
  -> CategoryStore
  -> Lexicon
  -> [Text]
  -> (IntMap.IntMap (Set CategoryId), CategoryStore)
rightReachableCategories config level grammarRules initialStore lexicon tokens = (reachable, chartStore)
  where
    tokenCount = length tokens
    conjunction = if allowCoordination (rules config)
      then conjunctionCategory (ruleSpecialCategories grammarRules)
      else Nothing
    (bases, baseStore) = foldl' addBase (Map.empty, initialStore) (zip [0 ..] tokens)
    addBase (cells, store) (position, token) =
      let (categoriesHere, store') = closeUnderSwap (Set.fromList (categoriesForWord token lexicon), store)
       in (Map.insert (position, position + 1) categoriesHere cells, store')
    (chart, chartStore) = foldl' addLength (bases, baseStore) [2 .. tokenCount]
    addLength acc spanLength = foldl' (addSpan spanLength) acc [0 .. tokenCount - spanLength]
    addSpan spanLength (cells, store) start =
      let end = start + spanLength
          pairs =
            [ (left, right)
            | split <- [start + 1 .. end - 1]
            , left <- Set.toAscList (cell start split cells)
            , right <- Set.toAscList (cell split end cells)
            ]
          (derived, store') = foldl' reducePair (Set.empty, store) pairs
          coordinatedCategories = case conjunction of
            Nothing -> Set.empty
            Just conj -> Set.unions
              [ Set.intersection (cell start leftEnd cells) (cell rightStart end cells)
              | leftEnd <- [start + 1 .. end - 2]
              , rightStart <- [leftEnd + 1 .. end - 1]
              , Set.member conj (cell leftEnd rightStart cells)
              ]
          (closedCell, store'') = closeUnderSwap (Set.union derived coordinatedCategories, store')
       in (Map.insert (start, end) closedCell cells, store'')
    reducePair (found, store) (left, right) =
      let (reductions, store') = pairReductions config level grammarRules store (left, True) (right, True)
       in (foldl' (flip (Set.insert . reductionResult)) found reductions, store')
    -- ASP is an involution, so one pass closes a set under swapping.
    closeUnderSwap (categorySet, store)
      | allowArgumentSwap (rules config) = foldl' addSwap (categorySet, store) (Set.toAscList categorySet)
      | otherwise = (categorySet, store)
    addSwap (found, store) categoryId = case swapWithinBounds config store categoryId of
      Just (swapped, store') -> (Set.insert swapped found, store')
      Nothing -> (found, store)
    cell start end = Map.findWithDefault Set.empty (start, end)
    reachable = IntMap.fromAscList
      [ (start, Set.unions [cell start end chart | end <- [start + 1 .. tokenCount]])
      | start <- [0 .. tokenCount - 1]
      ]
