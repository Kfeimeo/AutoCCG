module Evaluation.Coverage
  ( CoverageResult (..)
  , evaluateCoverage
  , evaluateCoverageWithJobs
  , sentenceCoverageWithJobs
  ) where

import Control.Parallel.Strategies (parListChunk, rdeepseq, using)
import Corpus.Types (Sentence (tokens))
import Grammar.Types (Grammar (..))
import Parser.Config (Config)
import Parser.Incremental (ParseOutcome (..), parseSentence)

data CoverageResult = CoverageResult
  { sentenceCount :: !Int
  , coveredSentenceCount :: !Int
  , rootSSuccessRate :: !Double
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

sentenceCoverageWithJobs :: Int -> Config -> Grammar -> [Sentence] -> [Bool]
sentenceCoverageWithJobs jobs config grammar corpus =
  map succeeds corpus `using` parListChunk (chunkSize jobs (length corpus)) rdeepseq
  where
    succeeds sentence = case parseSentence config (grammarCategories grammar) (grammarLexicon grammar)
      (raisingTemplates grammar) (rootCategory grammar) (tokens sentence) of
        Parsed _ -> True
        Failed _ -> False

chunkSize :: Int -> Int -> Int
chunkSize jobs itemCount = max 1 ((itemCount + workerCount - 1) `div` workerCount)
  where workerCount = max 1 jobs
