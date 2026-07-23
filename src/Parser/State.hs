module Parser.State
  ( ParseLevel (..)
  , ParseCost (..)
  , StackItem (..)
  , ParseState (..)
  , initialState
  , semanticKey
  ) where

import CCG.Category (CategoryId)
import CCG.Derivation (DerivationRef)

data ParseLevel = ApplicationOnly | WithComposition | WithTypeRaising
  deriving (Eq, Ord, Show, Enum, Bounded)

data ParseCost = ParseCost
  { typeRaisingUses :: !Int
  , compositionUses :: !Int
  , derivationSteps :: !Int
  } deriving (Eq, Ord, Show)

data StackItem = StackItem
  { itemCategory :: !CategoryId
  , itemDerivation :: !DerivationRef
  -- Only an unreduced lexical item may be type-raised.  A fused
  -- Type-raising+Composition reduction clears this marker immediately.
  , itemTypeRaisingPosition :: !(Maybe Int)
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

semanticKey :: ParseState -> (Int, [(CategoryId, Maybe Int)], ParseLevel)
semanticKey state =
  ( inputPosition state
  , map (\item -> (itemCategory item, itemTypeRaisingPosition item)) (categoryStack state)
  , activeParserLevel state
  )
