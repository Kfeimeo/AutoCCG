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

data ParseLevel = ApplicationOnly | WithComposition | WithTypeRaising
  deriving (Eq, Ord, Show, Enum, Bounded)

data ParseCost = ParseCost
  { typeRaisingUses :: !Int
  , compositionUses :: !Int
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
  } deriving (Eq, Ord, Show)

data ParseState = ParseState
  { inputPosition :: !Int
  , categoryStack :: ![StackItem]
  , activeParserLevel :: !ParseLevel
  , parseCost :: !ParseCost
  , boundedParseCount :: !Int
  } deriving (Eq, Show)

initialState :: ParseLevel -> ParseState
initialState level = ParseState 0 [] level (ParseCost 0 0 0) 1

semanticKey :: ParseState -> (Int, [(CategoryId, Bool, Bool)], ParseLevel)
semanticKey state =
  ( inputPosition state
  , map (\item -> (itemCategory item, itemRaisable item, itemCoordinated item)) (categoryStack state)
  , activeParserLevel state
  )
