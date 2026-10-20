module Grammar.Types
  ( Grammar (..)
  , CategoryProvenance (..)
  , GrammarHistoryRef (..)
  , GrammarCandidate (..)
  , GrammarBeam (..)
  , grammarRules
  ) where

import CCG.Atom (AtomTable)
import CCG.Category (CategoryId)
import CCG.CategoryStore (CategoryStore)
import CCG.SpecialRules (specialCategories)
import CCG.TypeRaising (TypeRaisingTemplate)
import Grammar.Cost (Cost)
import Data.Map.Strict (Map)
import Data.Text (Text)
import Lexicon.CandidateLexicon (CandidateSource)
import Lexicon.Types (Lexicon)
import Parser.State (GrammarRules (..))

data Grammar = Grammar
  { grammarAtoms :: !AtomTable
  , grammarCategories :: !CategoryStore
  , grammarLexicon :: !Lexicon
  , rootCategory :: !CategoryId
  , raisingTemplates :: ![TypeRaisingTemplate]
  , grammarProvenance :: !(Map (Text, CategoryId) CategoryProvenance)
  } deriving (Eq, Show)

-- | The parser's grammar-specific rule inputs: Type-raising templates and the
-- reserved coordination and punctuation categories of this grammar.
grammarRules :: Grammar -> GrammarRules
grammarRules grammar = GrammarRules
  (raisingTemplates grammar)
  (specialCategories (grammarAtoms grammar) (grammarCategories grammar))

data CategoryProvenance = CategoryProvenance
  { provenanceSource :: !CandidateSource
  , provenancePriorCost :: !Int
  , provenanceAcceptedAtSentence :: !(Maybe Text)
  , provenanceRepairReason :: !Text
  } deriving (Eq, Ord, Show)

newtype GrammarHistoryRef = GrammarHistoryRef Int deriving (Eq, Ord, Show)

data GrammarCandidate = GrammarCandidate
  { candidateGrammar :: !Grammar
  , grammarCost :: !Cost
  , processedSentenceCount :: !Int
  , grammarHistoryRef :: !GrammarHistoryRef
  } deriving (Eq, Show)

newtype GrammarBeam = GrammarBeam [GrammarCandidate] deriving (Eq, Show)
