{-# LANGUAGE OverloadedStrings #-}

-- | Version-1 candidate lexicon documents, the format read by
-- 'Lexicon.CandidateLexicon.loadCandidateLexicon'.
module Serialization.CandidateLexicon
  ( encodeCandidateLexicon
  , saveCandidateLexicon
  ) where

import CCG.Atom (AtomTable)
import CCG.CategoryStore (CategoryStore, prettyCategory)
import Data.Aeson (Value, encode, object, (.=))
import qualified Data.ByteString.Lazy as Lazy
import qualified Data.ByteString.Lazy.Char8 as Lazy8
import Data.Text (Text)
import Lexicon.CandidateLexicon

-- | Entries are written in ascending word order with candidates in their
-- deterministic lexicon order, one entry per line for diff-friendly output.
encodeCandidateLexicon :: AtomTable -> CategoryStore -> CandidateLexicon -> Either Text Lazy.ByteString
encodeCandidateLexicon atoms store lexicon = do
  entries <- traverse entryValue (candidateLexiconEntries lexicon)
  pure $ "{\"version\":1,\"entries\":[\n"
    <> Lazy8.intercalate ",\n" (map encode entries)
    <> "\n]}\n"
  where
    entryValue (word, candidates) = do
      values <- traverse candidateValue candidates
      pure (object ["word" .= word, "candidates" .= values])
    candidateValue :: CandidateCategory -> Either Text Value
    candidateValue candidate = do
      category <- prettyCategory atoms store (candidateCategoryId candidate)
      pure $ object
        [ "category" .= category
        , "prior_cost" .= candidatePriorCost candidate
        , "source" .= candidateSource candidate
        , "locked" .= candidateLocked candidate
        ]

saveCandidateLexicon :: FilePath -> AtomTable -> CategoryStore -> CandidateLexicon -> IO (Either Text ())
saveCandidateLexicon path atoms store lexicon =
  traverse (Lazy.writeFile path) (encodeCandidateLexicon atoms store lexicon)
