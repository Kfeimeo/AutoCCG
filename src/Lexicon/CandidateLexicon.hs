{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Lexicon.CandidateLexicon
  ( CandidateSource (..)
  , CandidateCategory (..)
  , CandidateLexicon
  , CandidateLexiconStats (..)
  , emptyCandidateLexicon
  , candidateCategoriesForWord
  , candidateLexiconEntries
  , candidateLexiconStats
  , loadCandidateLexicon
  , decodeCandidateLexicon
  , WordNetInventory
  , emptyWordNetInventory
  , loadWordNetInventory
  , buildCandidateLexiconFromConfig
  , configuredAtomTable
  , categoryWithinBounds
  ) where

import CCG.Atom (AtomTable, addConfiguredAtoms, atomCount)
import CCG.Category (CategoryId, categoryArity, categoryDepth, categorySlashCount)
import CCG.CategoryStore (CategoryStore, lookupCategory, parseCategory)
import Corpus.Types (Sentence (..))
import Control.Monad (foldM)
import Data.Aeson
import qualified Data.ByteString.Lazy as Lazy
import Data.Char (isDigit)
import Data.List (partition, sortOn)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)
import Lexicon.PosMapping (resolvePosTemplates)
import Parser.Config
import qualified Parser.Config as Config

data CandidateSource
  = FromSeedLexicon
  | FromPosTemplate
  | FromWordNetPos
  | FromUnknownFallback
  deriving (Eq, Ord, Show, Generic)

instance FromJSON CandidateSource where
  parseJSON = withText "candidate source" $ \source -> case source of
    "FromSeedLexicon" -> pure FromSeedLexicon
    "FromPosTemplate" -> pure FromPosTemplate
    "FromWordNetPos" -> pure FromWordNetPos
    "FromUnknownFallback" -> pure FromUnknownFallback
    _ -> fail ("unknown candidate source: " <> Text.unpack source)

instance ToJSON CandidateSource where
  toJSON = String . Text.pack . show

data CandidateCategory = CandidateCategory
  { candidateCategoryId :: !CategoryId
  , candidatePriorCost :: !Int
  , candidateSource :: !CandidateSource
  , candidateLocked :: !Bool
  } deriving (Eq, Ord, Show, Generic)

newtype CandidateLexicon = CandidateLexicon (Map Text [CandidateCategory])
  deriving (Eq, Show)

data CandidateLexiconStats = CandidateLexiconStats
  { candidateWordCount :: !Int
  , candidateCategoryCount :: !Int
  , candidateCategoriesPerWordMean :: !Double
  , candidateCategoriesPerWordMedian :: !Double
  , candidateCategoriesPerWordMax :: !Int
  } deriving (Eq, Show)

data CandidateDocument = CandidateDocument !Int ![CandidateEntryDocument]
data CandidateEntryDocument = CandidateEntryDocument !Text !(Maybe Text) !(Maybe Text) ![CandidateDocumentCategory]
data CandidateDocumentCategory = CandidateDocumentCategory !Text !Int !CandidateSource !Bool

instance FromJSON CandidateDocument where
  parseJSON = withObject "CandidateLexicon" $ \o -> CandidateDocument <$> o .: "version" <*> o .: "entries"
instance FromJSON CandidateEntryDocument where
  parseJSON = withObject "candidate entry" $ \o -> CandidateEntryDocument
    <$> o .: "word" <*> o .:? "lemma" <*> o .:? "pos" <*> o .: "candidates"
instance FromJSON CandidateDocumentCategory where
  parseJSON = withObject "candidate category" $ \o -> CandidateDocumentCategory
    <$> o .: "category" <*> o .:? "prior_cost" .!= 0
    <*> o .: "source" <*> o .:? "locked" .!= False

emptyCandidateLexicon :: CandidateLexicon
emptyCandidateLexicon = CandidateLexicon Map.empty

candidateCategoriesForWord :: Text -> CandidateLexicon -> [CandidateCategory]
candidateCategoriesForWord word (CandidateLexicon entries) =
  Map.findWithDefault (Map.findWithDefault [] (Text.toLower word) entries) word entries

candidateLexiconEntries :: CandidateLexicon -> [(Text, [CandidateCategory])]
candidateLexiconEntries (CandidateLexicon entries) = Map.toAscList entries

candidateLexiconStats :: CandidateLexicon -> CandidateLexiconStats
candidateLexiconStats lexicon = CandidateLexiconStats wordCount total mean median maximumCount
  where
    counts = sortOn id (map (length . snd) (candidateLexiconEntries lexicon))
    wordCount = length counts
    total = sum counts
    mean = if wordCount == 0 then 0 else fromIntegral total / fromIntegral wordCount
    median = case splitAt (wordCount `div` 2) counts of
      (_, middle : _) | odd wordCount -> fromIntegral middle
      (lower, upper : _) -> case reverse lower of
        lowerMiddle : _ -> fromIntegral (lowerMiddle + upper) / 2
        [] -> 0
      _ -> 0
    maximumCount = maximum (0 : counts)

loadCandidateLexicon
  :: CategoryBounds
  -> Bool
  -> Int
  -> FilePath
  -> AtomTable
  -> CategoryStore
  -> IO (Either Text (AtomTable, CategoryStore, CandidateLexicon))
loadCandidateLexicon bounds rejectNewAtoms maxPerWord path atoms store =
  decodeCandidateLexicon bounds rejectNewAtoms maxPerWord path atoms store <$> Lazy.readFile path

-- | Decode and intern a version-1 candidate lexicon document.  The 'FilePath'
-- only labels diagnostics.
decodeCandidateLexicon
  :: CategoryBounds
  -> Bool
  -> Int
  -> FilePath
  -> AtomTable
  -> CategoryStore
  -> Lazy.ByteString
  -> Either Text (AtomTable, CategoryStore, CandidateLexicon)
decodeCandidateLexicon bounds rejectNewAtoms maxPerWord path atoms store bytes =
  if maxPerWord < 1
    then Left (Text.pack path <> ": max_candidates_per_word must be at least 1")
    else case eitherDecode bytes of
      Left message -> Left (Text.pack path <> ": " <> Text.pack message)
      Right (CandidateDocument version entries)
        | version /= 1 -> Left (Text.pack path <> ": unsupported candidate lexicon version: " <> tshow version)
        | otherwise -> do
            (atoms', store', lexicon) <- foldM addEntry (atoms, store, emptyCandidateLexicon) (zip [1 :: Int ..] entries)
            pure (atoms', store', limitCandidates maxPerWord lexicon)
  where
    addEntry state (entryIndex, CandidateEntryDocument word _ _ categories) =
      foldM (addDocumentCandidate entryIndex word) state (zip [1 :: Int ..] categories)
    addDocumentCandidate entryIndex word (atoms0, store0, lexicon) (candidateIndex, CandidateDocumentCategory text prior source locked)
      | Text.null (Text.strip word) = Left (location entryIndex candidateIndex <> "empty word")
      | prior < 0 = Left (location entryIndex candidateIndex <> "prior_cost must be non-negative")
      | otherwise = case parseCategory text atoms0 store0 of
          Left message -> Left (location entryIndex candidateIndex <> "invalid category " <> text <> ": " <> message)
          Right (categoryId, atoms1, store1)
            | rejectNewAtoms && atomCount atoms1 > atomCount atoms0 ->
                Left (location entryIndex candidateIndex <> "category introduces an unconfigured atom: " <> text)
            | not (categoryWithinBounds bounds store1 categoryId) ->
                Left (location entryIndex candidateIndex <> "category exceeds configured bounds: " <> text)
            | otherwise -> Right
                (atoms1, store1, insertCandidate word (CandidateCategory categoryId prior source locked) lexicon)
    location entryIndex candidateIndex =
      Text.pack path <> ": entry " <> tshow entryIndex <> ", candidate " <> tshow candidateIndex <> ": "

-- | Lemma to Universal POS values, as written by
-- @python_tools/build_wordnet_inventory.py@.  WordNet supplies lemma-level
-- possible POS only; it is consulted only for tokens without corpus POS.
type WordNetInventory = Map Text [Text]

emptyWordNetInventory :: WordNetInventory
emptyWordNetInventory = Map.empty

loadWordNetInventory :: FilePath -> IO (Either Text WordNetInventory)
loadWordNetInventory path =
  either (Left . ((Text.pack path <> ": ") <>) . Text.pack) Right . eitherDecode <$> Lazy.readFile path

-- | Build the bounded candidate layer from seeds and corpus POS.
--
-- Per token, the tag driving the 'PosMapping' cascade is chosen as:
--
-- 1. explicit corpus POS (UPOS @PUNCT@ is refined by token shape so that
--    final punctuation does not inherit comma candidates);
-- 2. otherwise a closed-form token shape ('FromUnknownFallback');
-- 3. otherwise every WordNet POS of the lemma ('FromWordNetPos'), when
--    @use_wordnet_inventory@ is enabled.
buildCandidateLexiconFromConfig
  :: Config
  -> WordNetInventory
  -> [Sentence]
  -> AtomTable
  -> CategoryStore
  -> Either Text (AtomTable, CategoryStore, CandidateLexicon)
buildCandidateLexiconFromConfig config inventory corpus atoms store = do
  configuredAtoms <- configuredAtomTable config atoms
  if maxCandidatesPerWord constraints < 1
    then Left "max_candidates_per_word must be at least 1"
    else Right ()
  seeded <- if useSeedLexicon constraints
    then foldM addSeed (configuredAtoms, store, emptyCandidateLexicon) (Map.toAscList (seedLexicon config))
    else Right (configuredAtoms, store, emptyCandidateLexicon)
  generated <- if usePosTemplates constraints then foldM addSentence seeded corpus else Right seeded
  let (atoms', store', lexicon) = generated
  pure (atoms', store', limitCandidates (maxCandidatesPerWord constraints) lexicon)
  where
    constraints = candidateConstraints config
    addSeed state (word, entries) = addSeedEntries state word entries
    addSeedEntries state word entries = addConfigured word FromSeedLexicon state
      [CandidateTemplateConfig (seedCategory entry) (seedPriorCost entry) | entry <- entries]
      >>= \(atoms', store', lexicon) ->
        let lockedIds = [(seedCategory entry, seedLocked entry) | entry <- entries]
         in foldM (markLock word) (atoms', store', lexicon) lockedIds
    markLock word state@(atoms0, store0, lexicon) (categoryText, locked)
      | not locked = Right state
      | otherwise = do
          (categoryId, _, _) <- parseCategory categoryText atoms0 store0
          let updated = map (\candidate -> if candidateCategoryId candidate == categoryId then candidate { candidateLocked = True } else candidate)
              CandidateLexicon entries = lexicon
          Right (atoms0, store0, CandidateLexicon (Map.adjust updated word entries))
    addSentence state sentence = foldM addToken state (zip3 (tokens sentence) paddedLemmas paddedPos)
      where
        paddedPos = posTags sentence ++ repeat ""
        paddedLemmas = lemmas sentence ++ drop (length (lemmas sentence)) (tokens sentence)
    addToken state (word, lemma, pos) = do
      let shape = inferShapePos word
          evidence
            | pos == "PUNCT" && not (Text.null shape) = [(shape, FromPosTemplate)]
            | not (Text.null pos) = [(pos, FromPosTemplate)]
            | not (Text.null shape) = [(shape, FromUnknownFallback)]
            | useWordNetInventory constraints =
                [(tag, FromWordNetPos) | tag <- Map.findWithDefault [] (Text.toLower lemma) inventory]
            | otherwise = []
          addEvidence current (tag, source) = case resolvePosTemplates (posMapping config) word tag of
            Nothing -> Right current
            Just templates -> addConfigured word source current templates
      withPos <- foldM addEvidence state evidence
      if useSeedLexicon constraints
        then case Map.lookup (Text.toLower word) (seedLexicon config) of
          Nothing -> Right withPos
          Just entries -> addSeedEntries withPos word entries
        else Right withPos
    addConfigured word source = foldM (addOne word source)
    addOne word source (atoms0, store0, lexicon) template
      | templatePriorCost template < 0 = Left ("negative prior cost for " <> word)
      | otherwise = do
          (categoryId, atoms1, store1) <- parseCategory (templateCategory template) atoms0 store0
          if rejectCandidatesOutsideCategoryBounds constraints && atomCount atoms1 > atomCount atoms0
            then Left ("configured category introduces an unconfigured atom for " <> word <> ": " <> templateCategory template)
          else if not (categoryWithinBounds (categories config) store1 categoryId)
            then Left ("configured category exceeds bounds for " <> word <> ": " <> templateCategory template)
            else Right (atoms1, store1, insertCandidate word (CandidateCategory categoryId (templatePriorCost template) source False) lexicon)

-- | A deliberately small fallback for closed-form token shapes.  It supplies
-- evidence only when the corpus has no token POS, and never enumerates the
-- category universe.
inferShapePos :: Text -> Text
inferShapePos word
  | word `elem` [",", "，"] = "PUNCT_COMMA"
  | word `elem` [".", "!", "?", "。", "！", "？"] = "PUNCT_FINAL"
  | isNumericToken word = "NUM"
  | otherwise = ""

isNumericToken :: Text -> Bool
isNumericToken word =
  let unsigned = case Text.uncons word of
        Just (sign, rest) | sign `elem` ['+', '-'] -> rest
        _ -> word
      body = case Text.unsnoc unsigned of
        Just (rest, '%') -> rest
        _ -> unsigned
      boundaryDigits = case (Text.uncons body, Text.unsnoc body) of
        (Just (first, _), Just (_, lastCharacter)) -> isDigit first && isDigit lastCharacter
        _ -> False
   in boundaryDigits && Text.all (\character -> isDigit character || character `elem` ['.', ',']) body

configuredAtomTable :: Config -> AtomTable -> Either Text AtomTable
configuredAtomTable config =
  addConfiguredAtoms
    (predefinedAtoms (Config.atoms config))
    (maxAtomCount (Config.atoms config))

insertCandidate :: Text -> CandidateCategory -> CandidateLexicon -> CandidateLexicon
insertCandidate word candidate (CandidateLexicon entries) = CandidateLexicon (Map.alter update word entries)
  where
    update Nothing = Just [candidate]
    update (Just current) = Just (mergeCandidate candidate current)

mergeCandidate :: CandidateCategory -> [CandidateCategory] -> [CandidateCategory]
mergeCandidate candidate current = sortOn candidateOrdering (chosen : others)
  where
    (same, others) = partition ((== candidateCategoryId candidate) . candidateCategoryId) current
    chosen = case same of
      existing : _ ->
        let preferred = minBy candidateOrdering candidate existing
         in preferred { candidateLocked = candidateLocked candidate || any candidateLocked same }
      [] -> candidate
    minBy ordering left right = if ordering left <= ordering right then left else right

candidateOrdering :: CandidateCategory -> (Int, CandidateSource, CategoryId)
candidateOrdering candidate = (candidatePriorCost candidate, candidateSource candidate, candidateCategoryId candidate)

limitCandidates :: Int -> CandidateLexicon -> CandidateLexicon
limitCandidates maximumCount (CandidateLexicon entries) =
  CandidateLexicon (Map.map (take (max 0 maximumCount) . sortOn candidateOrdering) entries)

categoryWithinBounds :: CategoryBounds -> CategoryStore -> CategoryId -> Bool
categoryWithinBounds bounds store categoryId =
  categoryDepth (`lookupCategory` store) categoryId <= maxDepth bounds
    && categorySlashCount (`lookupCategory` store) categoryId <= maxSlashes bounds
    && categoryArity (`lookupCategory` store) categoryId <= maxArity bounds

tshow :: Show a => a -> Text
tshow = Text.pack . show
