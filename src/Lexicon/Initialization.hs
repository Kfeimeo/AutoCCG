{-# LANGUAGE OverloadedStrings #-}

module Lexicon.Initialization
  ( emptyGrammar
  , initializeSentenceWords
  , initializeLearnedLexicon
  , internNamedCategory
  ) where

import CCG.Atom (defaultAtomTable, lookupAtom)
import CCG.Category (CategoryId, Slash (..))
import CCG.CategoryStore
import CCG.TypeRaising (TypeRaisingTemplate (..))
import Corpus.Types (Sentence (..))
import Data.Maybe (fromMaybe)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Grammar.Types (CategoryProvenance (..), Grammar (..))
import Lexicon.CandidateLexicon
import Lexicon.Types (categoriesForWord, emptyLexicon, insertEntry)
import Parser.Config (InitializationConfig (..))

emptyGrammar :: Grammar
emptyGrammar =
  let atoms0 = defaultAtomTable
      sAtom = fromMaybe (error "default atom table invariant: S") (lookupAtom "S" atoms0)
      npAtom = fromMaybe (error "default atom table invariant: NP") (lookupAtom "NP" atoms0)
      (s, store1) = internAtomic sAtom emptyCategoryStore
      (np, store2) = internAtomic npAtom store1
      templates = [TypeRaisingTemplate np s ForwardSlash BackwardSlash, TypeRaisingTemplate np s BackwardSlash ForwardSlash]
   in Grammar atoms0 store2 emptyLexicon s templates Map.empty

internNamedCategory :: Text -> Grammar -> Either Text (CategoryId, Grammar)
internNamedCategory text grammar = do
  (categoryId, atoms, store) <- parseCategory text (grammarAtoms grammar) (grammarCategories grammar)
  pure (categoryId, grammar { grammarAtoms = atoms, grammarCategories = store })

initializeSentenceWords :: Sentence -> Grammar -> Grammar
initializeSentenceWords sentence grammar = foldl' initialize grammar (zip3 [0 :: Int ..] (tokens sentence) paddedPos)
  where
    paddedPos = posTags sentence ++ repeat ""
    tokenCount = length (tokens sentence)
    initialize current (index, word, pos)
      | not (null (categoriesForWord word (grammarLexicon current))) = current
      | otherwise = case internNamedCategory (guess index tokenCount pos) current of
          Left _ -> current
          Right (categoryId, updated) -> updated { grammarLexicon = insertEntry word categoryId (grammarLexicon updated) }

    guess index count pos
      | pos `elem` ["DT", "PDT", "WDT"] = "NP/N"
      | Text.isPrefixOf "JJ" pos = "N/N"
      | Text.isPrefixOf "NN" pos = if pos `elem` ["NN", "NNS"] then "N" else "NP"
      | Text.isPrefixOf "VB" pos = if index < count - 1 then "(S\\NP)/NP" else "S\\NP"
      | count == 1 = "S"
      | index == 0 || index == count - 1 = "NP"
      | otherwise = "(S\\NP)/NP"

-- | Activate only explicitly permitted initial candidates.  Candidate entries
-- remain separate; the parser continues to see only 'grammarLexicon'.
initializeLearnedLexicon :: InitializationConfig -> CandidateLexicon -> Grammar -> Grammar
initializeLearnedLexicon config candidates grammar = foldl' activateWord grammar (candidateLexiconEntries candidates)
  where
    activateWord current (word, options) = foldl' (activate word) current selected
      where
        affordable = filter ((<= maxInitialPriorCost config) . candidatePriorCost) options
        locked = if useLockedSeedEntries config then filter candidateLocked affordable else []
        activatable = filter ((/= FromSeedLexicon) . candidateSource) options
        affordableActivatable = filter ((<= maxInitialPriorCost config) . candidatePriorCost) activatable
        selected
          | not (null locked) = locked
          | activateSingleCandidateWords config && length activatable == 1 = affordableActivatable
          | activateBestCandidatePerWord config = take 1 affordableActivatable
          | otherwise = []
    activate word current candidate = current
      { grammarLexicon = insertEntry word categoryId (grammarLexicon current)
      , grammarProvenance = Map.insert (word, categoryId)
          (CategoryProvenance (candidateSource candidate) (candidatePriorCost candidate) Nothing "InitialCandidate")
          (grammarProvenance current)
      }
      where categoryId = candidateCategoryId candidate
