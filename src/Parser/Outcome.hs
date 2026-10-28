-- | Results shared by the parsers in "Parser.Incremental" and "Parser.Eisner".
module Parser.Outcome
  ( ParseSuccess (..)
  , ParseOutcome (..)
  ) where

import CCG.CategoryStore (CategoryStore)
import CCG.Derivation (DerivationArena, DerivationRef)
import Parser.FailureFrontier (ParseFailure)
import Parser.State (ParseCost, ParseLevel)

data ParseSuccess = ParseSuccess
  { successfulLevel :: !ParseLevel
  , rootDerivation :: !DerivationRef
  -- ^ The lowest-cost derivation of the root.
  , successfulCost :: !ParseCost
  , parseCount :: !Int
  -- ^ Number of distinct derivations found, capped at @parse_count_cap@.
  , finalArena :: !DerivationArena
  , finalStore :: !CategoryStore
  , allDerivations :: ![DerivationRef]
  -- ^ Root derivations kept in 'finalArena', best first.  The Eisner parser
  -- keeps one with @derivations: first@ and every normal-form derivation (up
  -- to the cap) with @derivations: all@.  The shift-reduce parser records
  -- only lexical nodes in its arena, so it leaves this empty.
  } deriving (Eq, Show)

data ParseOutcome = Parsed !ParseSuccess | Failed !ParseFailure deriving (Eq, Show)
