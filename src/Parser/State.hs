module Parser.State
  ( ParseLevel (..)
  , ParseCost (..)
  , GrammarRules (..)
  , StackItem (..)
  , ParseState (..)
  , initialState
  , semanticKey
  ) where

import CCG.Category (CategoryId)
import CCG.Derivation (DerivationRef)
import CCG.SpecialRules (SpecialCategories)
import CCG.TypeRaising (TypeRaisingTemplate)

-- | Parser rule levels, tried in this order.  Each level adds its rule to all
-- rules of the levels before it; a level is tried only when every lower level
-- fails to derive the root.
data ParseLevel
  = ApplicationOnly
  -- ^ Application, plus coordination and punctuation absorption.
  | WithComposition
  -- ^ + Composition (harmonic, crossed, and generalized as configured).
  | WithArgumentSwap
  -- ^ + ASP, only when @rules.allow_argument_swap@ is on.
  | WithTypeRaising
  -- ^ + Type-raising fused with Composition.
  deriving (Eq, Ord, Show, Enum, Bounded)

data ParseCost = ParseCost
  { typeRaisingUses :: !Int
  , compositionUses :: !Int
  , argumentSwapUses :: !Int
  , derivationSteps :: !Int
  } deriving (Eq, Ord, Show)

-- | Grammar-specific rule inputs of the parser, beyond the configuration.
data GrammarRules = GrammarRules
  { ruleRaisingTemplates :: ![TypeRaisingTemplate]
  , ruleSpecialCategories :: !SpecialCategories
  } deriving (Eq, Show)

data StackItem = StackItem
  { itemCategory :: !CategoryId
  , itemDerivation :: !DerivationRef
  -- Whether the constituent may still be type-raised.  Lexical items and
  -- Application/Composition results may be raised; a fused
  -- Type-raising+Composition result may not, so no constituent is raised twice.
  , itemRaisable :: !Bool
  -- Whether the constituent is the direct result of coordination.  As in
  -- lightblue, such a constituent cannot be the left conjunct of another
  -- coordination, so @a and b and c@ is bracketed only as @a and (b and c)@.
  , itemCoordinated :: !Bool
  -- Whether ASP has already swapped this constituent's arguments.  Each
  -- constituent is swapped at most once; a second swap would only restore it.
  , itemSwapped :: !Bool
  } deriving (Eq, Ord, Show)

data ParseState = ParseState
  { inputPosition :: !Int
  , categoryStack :: ![StackItem]
  , activeParserLevel :: !ParseLevel
  , parseCost :: !ParseCost
  , boundedParseCount :: !Int
  } deriving (Eq, Show)

initialState :: ParseLevel -> ParseState
initialState level = ParseState 0 [] level (ParseCost 0 0 0 0) 1

semanticKey :: ParseState -> (Int, [(CategoryId, Bool, Bool, Bool)], ParseLevel)
semanticKey state =
  ( inputPosition state
  , map (\item -> (itemCategory item, itemRaisable item, itemCoordinated item, itemSwapped item)) (categoryStack state)
  , activeParserLevel state
  )
