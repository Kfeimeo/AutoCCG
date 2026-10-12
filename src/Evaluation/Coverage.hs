module Evaluation.Coverage
  ( CoverageResult (..)
  , SentenceCoverage (..)
  , evaluateCoverage
  , evaluateCoverageWithJobs
  , sentenceCoverageDetailsWithJobs
  , sentenceCoverageWithJobs
  ) where

import CCG.Category (CategoryId)
import Control.Parallel.Strategies (parListChunk, rseq, using)
import Corpus.Types (Sentence (sentenceId, tokens))
import qualified Data.Set as Set
import Data.Text (Text)
import Grammar.Types (Grammar (..))
import Lexicon.Types (categoriesForWord)
import Parser.Config (Config)
import Parser.Incremental (ParseOutcome (..), ParseSuccess (successfulLevel), parseSentence)
import Parser.FailureFrontier (ParseFailure (..), ParseStateSummary (summaryStack))
import Parser.State (ParseLevel)

data CoverageResult = CoverageResult
  { sentenceCount :: !Int
  , coveredSentenceCount :: !Int
  , rootSSuccessRate :: !Double
  } deriving (Eq, Show)

-- | Sentence-level lexical and parser coverage diagnostics.  Token coverage
-- counts occurrences, while word-type coverage counts distinct surface forms.
-- Keeping both makes repeated unknown words visible without overstating the
-- learned lexicon's vocabulary coverage.
data SentenceCoverage = SentenceCoverage
  { coverageSentenceId :: !Text
  , coverageCovered :: !Bool
  , coverageTokenCount :: !Int
  , coverageCategorizedTokenCount :: !Int
  , coverageCategorizedTokenRate :: !Double
  , coverageWordTypeCount :: !Int
  , coverageCategorizedWordTypeCount :: !Int
  , coverageCategorizedWordTypeRate :: !Double
  , coverageCategoryAssignmentCount :: !Int
  , coverageUncategorizedWords :: ![Text]
  , coverageFarthestPosition :: !(Maybe Int)
  , coverageFrontierStacks :: ![[CategoryId]]
  , coverageSuccessfulLevel :: !(Maybe ParseLevel)
  } deriving (Eq, Show)

evaluateCoverage :: Config -> Grammar -> [Sentence] -> CoverageResult
evaluateCoverage = evaluateCoverageWithJobs 1

evaluateCoverageWithJobs :: Int -> Config -> Grammar -> [Sentence] -> CoverageResult
evaluateCoverageWithJobs jobs config grammar corpus = CoverageResult total covered rate
  where
    total = length corpus
    covered = length (filter id results)
    rate = if total == 0 then 0 else fromIntegral covered / fromIntegral total
    results = sentenceCoverageWithJobs jobs config grammar corpus

sentenceCoverageDetailsWithJobs :: Int -> Config -> Grammar -> [Sentence] -> [SentenceCoverage]
sentenceCoverageDetailsWithJobs jobs config grammar corpus =
  map diagnose corpus `using` parListChunk (chunkSize jobs (length corpus)) rseq
  where
    lexicon = grammarLexicon grammar
    diagnose sentence =
      let sentenceTokens = tokens sentence
          distinctWords = Set.toAscList (Set.fromList sentenceTokens)
          hasCategory word = not (null (categoriesForWord word lexicon))
          categorizedTokens = length (filter hasCategory sentenceTokens)
          categorizedWords = length (filter hasCategory distinctWords)
          tokenCount = length sentenceTokens
          wordCount = length distinctWords
          assignmentCount = sum (map (length . (`categoriesForWord` lexicon)) distinctWords)
          tokenRate = ratio categorizedTokens tokenCount
          wordRate = ratio categorizedWords wordCount
          missing = filter (not . hasCategory) distinctWords
       in case parseSentence config (grammarCategories grammar) lexicon
            (raisingTemplates grammar) (rootCategory grammar) sentenceTokens of
              Parsed success ->
                SentenceCoverage (sentenceId sentence) True tokenCount categorizedTokens tokenRate
                  wordCount categorizedWords wordRate assignmentCount missing Nothing []
                  (Just (successfulLevel success))
              Failed failure ->
                SentenceCoverage (sentenceId sentence) False tokenCount categorizedTokens tokenRate
                  wordCount categorizedWords wordRate assignmentCount missing
                  (Just (farthestPosition failure))
                  (map summaryStack (survivingStates failure))
                  Nothing

sentenceCoverageWithJobs :: Int -> Config -> Grammar -> [Sentence] -> [Bool]
sentenceCoverageWithJobs jobs config grammar corpus =
  map coverageCovered (sentenceCoverageDetailsWithJobs jobs config grammar corpus)

ratio :: Int -> Int -> Double
ratio _ 0 = 0
ratio numerator denominator = fromIntegral numerator / fromIntegral denominator

chunkSize :: Int -> Int -> Int
chunkSize jobs itemCount = max 1 ((itemCount + workerCount - 1) `div` workerCount)
  where workerCount = max 1 jobs
