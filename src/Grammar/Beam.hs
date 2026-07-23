{-# LANGUAGE OverloadedStrings #-}

module Grammar.Beam (normalizeBeam, grammarSignature) where

import CCG.CategoryStore (prettyCategory)
import Data.List (sortOn)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Grammar.Types
import Lexicon.Types (lexiconEntries)

grammarSignature :: Grammar -> [(Text, [Text])]
grammarSignature grammar =
  [ (word, sortOn id [either (const "<?>" ) id (prettyCategory (grammarAtoms grammar) (grammarCategories grammar) categoryId) | categoryId <- categories])
  | (word, categories) <- lexiconEntries (grammarLexicon grammar)
  ]

normalizeBeam :: Int -> [GrammarCandidate] -> GrammarBeam
normalizeBeam width candidates = GrammarBeam . take width . sortOn ordering . Map.elems $
  foldr insert Map.empty candidates
  where
    insert candidate = Map.insertWith cheaper (grammarSignature (candidateGrammar candidate)) candidate
    cheaper left right
      | ordering left <= ordering right = left
      | otherwise = right
    ordering candidate = (grammarCost candidate, grammarSignature (candidateGrammar candidate), grammarHistoryRef candidate)
