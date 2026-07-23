module CCG.TypeRaising
  ( TypeRaisingTemplate (..)
  , raiseCategory
  ) where

import CCG.Category (CategoryId, Slash (..))
import CCG.CategoryStore (CategoryStore, internFunctional)

data TypeRaisingTemplate = TypeRaisingTemplate
  { sourceCategory :: !CategoryId
  , targetCategory :: !CategoryId
  , outerSlash :: !Slash
  , innerSlash :: !Slash
  }
  deriving (Eq, Ord, Show)

-- T/(T\X) or T\(T/X), determined entirely by a bounded configured template.
raiseCategory :: TypeRaisingTemplate -> CategoryStore -> CategoryId -> Maybe (CategoryId, CategoryStore)
raiseCategory template store categoryId
  | categoryId /= sourceCategory template = Nothing
  | otherwise =
      let (inner, store') = internFunctional (innerSlash template) (targetCategory template) categoryId store
       in Just (internFunctional (outerSlash template) (targetCategory template) inner store')
