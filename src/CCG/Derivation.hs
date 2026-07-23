module CCG.Derivation
  ( DerivationRef (..)
  , DerivationNode (..)
  , DerivationArena
  , emptyArena
  , addDerivation
  , lookupDerivation
  ) where

import CCG.Category (CategoryId)
import CCG.Combinator (Combinator)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Text (Text)

newtype DerivationRef = DerivationRef { unDerivationRef :: Int } deriving (Eq, Ord, Show)

data DerivationNode
  = LexicalNode !Int !Text !CategoryId
  | BinaryNode !Combinator !CategoryId !DerivationRef !DerivationRef
  | RaisedNode !CategoryId !DerivationRef
  deriving (Eq, Show)

newtype DerivationArena = DerivationArena (IntMap DerivationNode) deriving (Eq, Show)

emptyArena :: DerivationArena
emptyArena = DerivationArena IntMap.empty

addDerivation :: DerivationNode -> DerivationArena -> (DerivationRef, DerivationArena)
addDerivation node (DerivationArena nodes) =
  let ref = DerivationRef (IntMap.size nodes)
   in (ref, DerivationArena (IntMap.insert (unDerivationRef ref) node nodes))

lookupDerivation :: DerivationRef -> DerivationArena -> Maybe DerivationNode
lookupDerivation (DerivationRef ref) (DerivationArena nodes) = IntMap.lookup ref nodes
