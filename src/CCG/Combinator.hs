module CCG.Combinator
  ( Combinator (..)
  , applyCombinator
  , applicationResults
  , compositionResults
  ) where

import CCG.Category (CategoryId, CategoryNode (..), Slash (..))
import CCG.CategoryStore (CategoryStore, internFunctional, lookupCategory)

data Combinator
  = ForwardApplication
  | BackwardApplication
  | ForwardComposition
  | BackwardComposition
  deriving (Eq, Ord, Show, Enum, Bounded)

applyCombinator :: Combinator -> CategoryStore -> CategoryId -> CategoryId -> Maybe (CategoryId, CategoryStore)
applyCombinator combinator store left right = case combinator of
  ForwardApplication -> case lookupCategory left store of
    Just (Functional ForwardSlash result argument) | argument == right -> Just (result, store)
    _ -> Nothing
  BackwardApplication -> case lookupCategory right store of
    Just (Functional BackwardSlash result argument) | argument == left -> Just (result, store)
    _ -> Nothing
  ForwardComposition -> case (lookupCategory left store, lookupCategory right store) of
    (Just (Functional ForwardSlash x y), Just (Functional ForwardSlash y' z))
      | y == y' -> Just (internFunctional ForwardSlash x z store)
    _ -> Nothing
  BackwardComposition -> case (lookupCategory left store, lookupCategory right store) of
    (Just (Functional BackwardSlash y z), Just (Functional BackwardSlash x y'))
      | y == y' -> Just (internFunctional BackwardSlash x z store)
    _ -> Nothing

applicationResults :: CategoryStore -> CategoryId -> CategoryId -> [(Combinator, CategoryId, CategoryStore)]
applicationResults store left right = results [ForwardApplication, BackwardApplication]
  where
    results = foldr collect []
    collect combinator acc = case applyCombinator combinator store left right of
      Nothing -> acc
      Just (categoryId, store') -> (combinator, categoryId, store') : acc

compositionResults :: CategoryStore -> CategoryId -> CategoryId -> [(Combinator, CategoryId, CategoryStore)]
compositionResults store left right = results [ForwardComposition, BackwardComposition]
  where
    results = foldr collect []
    collect combinator acc = case applyCombinator combinator store left right of
      Nothing -> acc
      Just (categoryId, store') -> (combinator, categoryId, store') : acc
