-- | Exhaustive CKY chart parsing with Eisner's (1996) normal-form constraints
-- ("Efficient Normal-Form Parsing for Combinatory Categorial Grammar").
--
-- Only Application and the configured Composition rules are used; Type-raising,
-- ASP, coordination, and absorption are not part of this parser (configuration
-- loading rejects them for @parser.algorithm: eisner@).
--
-- Normal form.  Every chart item records whether it was produced by forward
-- Composition, backward Composition, or anything else.  A constituent produced
-- by a forward Composition rule (@>B^n@, n >= 1) never serves as the primary,
-- left functor of a forward rule (@>@ or @>B^m@); symmetrically, a constituent
-- produced by backward Composition never serves as the primary, right functor of
-- a backward rule.  This removes spurious ambiguity: with Application and
-- Composition, each semantic reading has exactly one normal-form derivation,
-- so the root's derivations are its distinct readings.
--
-- Unlike the shift-reduce parser, Application never blocks Composition on the
-- same pair, so no reading is lost.  The chart is exact; only the number of
-- derivations kept per item is capped by @parser.parse_count_cap@.
module Parser.Eisner
  ( NormalFormTag (..)
  , parseEisner
  ) where

import CCG.Category (CategoryId)
import CCG.CategoryStore (CategoryStore)
import CCG.Combinator (Combinator (..), applicationResults, compositionResults)
import CCG.Derivation (DerivationArena, DerivationNode (..), DerivationRef, addDerivation, emptyArena)
import Data.List (sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Data.Text (Text)
import Lexicon.CandidateLexicon (categoryWithinBounds)
import Lexicon.Types (Lexicon, categoriesForWord)
import Parser.Config
import Parser.FailureFrontier
  ( BlockingPair (..), ParseFailure (..), ParseStateSummary (..), RightContextSummary (..) )
import Parser.Outcome (ParseOutcome (..), ParseSuccess (..))
import Parser.State (ParseCost (..), ParseLevel (..))

-- | The rule that produced a chart item, as far as the normal form needs it.
data NormalFormTag
  = FromForwardComposition
  | FromBackwardComposition
  | FromOtherRule
  deriving (Eq, Ord, Show)

type ItemKey = (CategoryId, NormalFormTag)

type Span = (Int, Int)

data Backpointer
  = LexicalPointer !Int !Text
  | BinaryPointer !Combinator !Int !ItemKey !ItemKey
  deriving (Eq, Show)

-- | Composition uses, then derivation steps.  Lower is better.
type ItemCost = (Int, Int)

data Entry = Entry
  { entryCost :: !ItemCost
  -- ^ Cost of the best derivation of the item.
  , entryCount :: !Int
  -- ^ Normal-form derivations of the item, capped.
  , entryPointers :: ![(ItemCost, Backpointer)]
  -- ^ Best first.  One pointer with @derivations: first@, all with @all@.
  } deriving (Eq, Show)

type Cell = Map ItemKey Entry

type Chart = Map Span Cell

parseEisner :: Config -> CategoryStore -> Lexicon -> CategoryId -> [Text] -> ParseOutcome
parseEisner config initialStore lexicon root tokens =
  case sortOn (entryCost . snd) rootItems of
    [] -> Failed (chartFailure tokens chart)
    best@((_, bestEntry) : _) ->
      let cap = parseCountCap (parser config)
          (refs, arena) = materializeRoots config chart tokenCount best
          (compositions, steps) = entryCost bestEntry
          level = if compositions > 0 then WithComposition else ApplicationOnly
          count = min cap (sum (map (entryCount . snd) best))
       in case refs of
            ref : _ -> Parsed (ParseSuccess level ref (ParseCost 0 compositions 0 steps) count arena finalChartStore refs)
            [] -> Failed (chartFailure tokens chart)
  where
    tokenCount = length tokens
    (chart, finalChartStore) = buildChart config initialStore lexicon tokens
    rootItems =
      [ (key, entry)
      | (key@(category, _), entry) <- Map.toAscList (cellAt chart (0, tokenCount))
      , category == root
      , tokenCount > 0
      ]

buildChart :: Config -> CategoryStore -> Lexicon -> [Text] -> (Chart, CategoryStore)
buildChart config initialStore lexicon tokens = foldl' addLength (bases, initialStore) [2 .. tokenCount]
  where
    tokenCount = length tokens
    bases = Map.fromList
      [ ( (position, position + 1)
        , Map.fromList
            [ ((category, FromOtherRule), Entry (0, 1) 1 [((0, 1), LexicalPointer position token)])
            | category <- categoriesForWord token lexicon
            ]
        )
      | (position, token) <- zip [0 ..] tokens
      ]
    addLength acc spanLength = foldl' (addSpan spanLength) acc [0 .. tokenCount - spanLength]
    addSpan spanLength (cells, store) start =
      let end = start + spanLength
          pairs =
            [ (split, left, right)
            | split <- [start + 1 .. end - 1]
            , left <- Map.toAscList (cellAt cells (start, split))
            , right <- Map.toAscList (cellAt cells (split, end))
            ]
          (cell, store') = foldl' (combinePair config) (Map.empty, store) pairs
       in (Map.insert (start, end) cell cells, store')

-- | Add every normal-form combination of two adjacent items to a cell.
combinePair :: Config -> (Cell, CategoryStore) -> (Int, (ItemKey, Entry), (ItemKey, Entry)) -> (Cell, CategoryStore)
combinePair config (cell, store) (split, (leftKey, leftEntry), (rightKey, rightEntry)) =
  (foldl' insertResult cell results, store')
  where
    ruleConfig = rules config
    (leftCategory, leftTag) = leftKey
    (rightCategory, rightTag) = rightKey
    applications =
      [ (combinator, result)
      | (combinator, result, _) <- applicationResults store leftCategory rightCategory
      ]
    (compositions, store') = compositionResults (maxCompositionDegree ruleConfig) store leftCategory rightCategory
    results =
      [ (combinator, result)
      | (combinator, result) <- applications ++ compositions
      , combinatorEnabled ruleConfig combinator
      , normalForm combinator
      , isApplication combinator || categoryWithinBounds (categories config) store' result
      ]
    -- Eisner's constraints: a Composition result is never the primary
    -- functor of a rule in the same direction.
    normalForm combinator
      | isForward combinator = leftTag /= FromForwardComposition
      | otherwise = rightTag /= FromBackwardComposition
    cap = parseCountCap (parser config)
    keepAll = derivationOutput (parser config) == AllDerivations
    insertResult current (combinator, result) =
      let tag
            | isApplication combinator = FromOtherRule
            | isForward combinator = FromForwardComposition
            | otherwise = FromBackwardComposition
          (leftCompositions, leftSteps) = entryCost leftEntry
          (rightCompositions, rightSteps) = entryCost rightEntry
          cost =
            ( leftCompositions + rightCompositions + (if isApplication combinator then 0 else 1)
            , leftSteps + rightSteps + 1 )
          pointer = (cost, BinaryPointer combinator split leftKey rightKey)
          count = min cap (entryCount leftEntry * entryCount rightEntry)
          fresh = Entry cost count [pointer]
       in Map.insertWith (mergeEntries keepAll cap) (result, tag) fresh current

-- | Merge a new derivation of an existing item.  Earlier pointers win ties, so
-- the kept best derivation is the first found in deterministic chart order.
mergeEntries :: Bool -> Int -> Entry -> Entry -> Entry
mergeEntries keepAll cap new old = Entry
  { entryCost = min (entryCost old) (entryCost new)
  , entryCount = min cap (entryCount old + entryCount new)
  , entryPointers = if keepAll
      then sortOn fst (entryPointers old ++ entryPointers new)
      else take 1 (sortOn fst (entryPointers old ++ entryPointers new))
  }

-- | Write root derivations into a fresh arena: one with @first@, up to the
-- cap with @all@.  Sub-derivations are memoized per item, so shared subtrees
-- are stored once.
materializeRoots :: Config -> Chart -> Int -> [(ItemKey, Entry)] -> ([DerivationRef], DerivationArena)
materializeRoots config chart tokenCount roots =
  let (refs, _, arena) = foldl' addRoot ([], Map.empty, emptyArena) roots
   in (take limit refs, arena)
  where
    keepAll = derivationOutput (parser config) == AllDerivations
    limit = if keepAll then parseCountCap (parser config) else 1
    addRoot (refs, memo, arena) (key, _)
      | length refs >= limit = (refs, memo, arena)
      | otherwise =
          let (rootRefs, memo', arena') = derivations (0, tokenCount) key (memo, arena)
           in (refs ++ take (limit - length refs) rootRefs, memo', arena')
    derivations itemSpan key (memo, arena) = case Map.lookup (itemSpan, key) memo of
      Just refs -> (refs, memo, arena)
      Nothing ->
        let pointers = maybe [] entryPointers (Map.lookup key (cellAt chart itemSpan))
            (refs, memo', arena') = foldl' (expand itemSpan key) ([], memo, arena) pointers
            kept = take limit refs
         in (kept, Map.insert (itemSpan, key) kept memo', arena')
    expand (start, end) (category, _) (refs, memo, arena) (_, pointer)
      | length refs >= limit = (refs, memo, arena)
      | otherwise = case pointer of
          LexicalPointer position token ->
            let (ref, arena') = addDerivation (LexicalNode position token category) arena
             in (refs ++ [ref], memo, arena')
          BinaryPointer combinator split leftKey rightKey ->
            let (lefts, memo1, arena1) = derivations (start, split) leftKey (memo, arena)
                (rights, memo2, arena2) = derivations (split, end) rightKey (memo1, arena1)
                children = take (limit - length refs) [(left, right) | left <- lefts, right <- rights]
                (newRefs, arena3) = foldl' (addBinary combinator category) ([], arena2) children
             in (refs ++ reverse newRefs, memo2, arena3)
    addBinary combinator category (acc, arena) (left, right) =
      let (ref, arena') = addDerivation (BinaryNode combinator category left right) arena
       in (ref : acc, arena')

-- | A failure frontier in the shape the repair search expects, matching the
-- shift-reduce parser: the farthest position up to which the input can be
-- segmented into chart constituents (so a word without categories stops it),
-- the constituents ending there, and the pairs they form with the next token.
chartFailure :: [Text] -> Chart -> ParseFailure
chartFailure tokens chart =
  ParseFailure far summaries pairs Set.empty (RightContextSummary (drop far tokens))
  where
    tokenCount = length tokens
    reachable = foldl' extend (Set.singleton 0) [1 .. tokenCount]
    extend reached end
      | any (\start -> Set.member start reached && not (Map.null (cellAt chart (start, end)))) [0 .. end - 1] =
          Set.insert end reached
      | otherwise = reached
    far = Set.findMax reachable
    -- Constituents ending at the frontier, from the longest reachable one.
    frontierCategories = concat
      [ uniqueCategories (cellAt chart (start, far))
      | start <- [0 .. far - 1]
      , Set.member start reachable
      ]
    summaries = take 32 [ParseStateSummary far [category] | category <- frontierCategories]
    pairs = Set.toAscList (Set.fromList
      [ BlockingPair left right
      | left <- frontierCategories
      , right <- uniqueCategories (cellAt chart (far, far + 1))
      ])
    uniqueCategories = Set.toAscList . Set.fromList . map fst . Map.keys

cellAt :: Chart -> Span -> Cell
cellAt chart itemSpan = Map.findWithDefault Map.empty itemSpan chart

isApplication :: Combinator -> Bool
isApplication combinator = combinator `elem` [ForwardApplication, BackwardApplication]

-- | Forward rules have their primary functor on the left.
isForward :: Combinator -> Bool
isForward combinator = combinator `elem`
  [ ForwardApplication, ForwardComposition, ForwardCrossedComposition
  , ForwardGeneralizedComposition, ForwardGeneralizedCrossedComposition
  ]
