module Parser.Beam (deduplicateStates) where

import qualified Data.Map.Strict as Map
import Data.List (foldl')
import Parser.State (ParseState (..), semanticKey)

deduplicateStates :: Int -> [ParseState] -> [ParseState]
deduplicateStates cap = Map.elems . foldl' insert Map.empty
  where
    insert states state = Map.insertWith keep (semanticKey state) state states
    keep new old
      | parseCost new < parseCost old = new
      | otherwise = old { boundedParseCount = min cap (boundedParseCount old + boundedParseCount new) }
