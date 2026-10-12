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
  | ForwardCrossedComposition
  | BackwardCrossedComposition
  | ForwardGeneralizedComposition
  | BackwardGeneralizedComposition
  | ForwardGeneralizedCrossedComposition
  | BackwardGeneralizedCrossedComposition
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
  ForwardCrossedComposition -> case (lookupCategory left store, lookupCategory right store) of
    (Just (Functional ForwardSlash x y), Just (Functional BackwardSlash y' z))
      | y == y' -> Just (internFunctional BackwardSlash x z store)
    _ -> Nothing
  BackwardCrossedComposition -> case (lookupCategory left store, lookupCategory right store) of
    (Just (Functional ForwardSlash y z), Just (Functional BackwardSlash x y'))
      | y == y' -> Just (internFunctional ForwardSlash x z store)
    _ -> Nothing
  ForwardGeneralizedComposition -> case lookupCategory left store of
    Just (Functional ForwardSlash x y) -> replaceResultSpine ForwardSlash 2 y x right store
    _ -> Nothing
  BackwardGeneralizedComposition -> case lookupCategory right store of
    Just (Functional BackwardSlash x y) -> replaceResultSpine BackwardSlash 2 y x left store
    _ -> Nothing
  ForwardGeneralizedCrossedComposition -> case lookupCategory left store of
    Just (Functional ForwardSlash x y) -> replaceResultSpine BackwardSlash 2 y x right store
    _ -> Nothing
  BackwardGeneralizedCrossedComposition -> case lookupCategory right store of
    Just (Functional BackwardSlash x y) -> replaceResultSpine ForwardSlash 2 y x left store
    _ -> Nothing

applicationResults :: CategoryStore -> CategoryId -> CategoryId -> [(Combinator, CategoryId, CategoryStore)]
applicationResults store left right = results [ForwardApplication, BackwardApplication]
  where
    results = foldr collect []
    collect combinator acc = case applyCombinator combinator store left right of
      Nothing -> acc
      Just (categoryId, store') -> (combinator, categoryId, store') : acc

compositionResults :: CategoryStore -> CategoryId -> CategoryId -> [(Combinator, CategoryId, CategoryStore)]
compositionResults store left right = results
  [ ForwardComposition
  , BackwardComposition
  , ForwardCrossedComposition
  , BackwardCrossedComposition
  , ForwardGeneralizedComposition
  , BackwardGeneralizedComposition
  , ForwardGeneralizedCrossedComposition
  , BackwardGeneralizedCrossedComposition
  ]
  where
    results = foldr collect []
    collect combinator acc = case applyCombinator combinator store left right of
      Nothing -> acc
      Just (categoryId, store') -> (combinator, categoryId, store') : acc

-- | Replace the result at the base of a uniform slash spine.  Requiring at
-- least two spine layers keeps first-order Composition represented by its
-- dedicated combinators and makes generalized rule use explicit in costs and
-- diagnostics.
replaceResultSpine
  :: Slash
  -> Int
  -> CategoryId
  -> CategoryId
  -> CategoryId
  -> CategoryStore
  -> Maybe (CategoryId, CategoryStore)
replaceResultSpine slash minimumLayers target replacement = go 0
  where
    go layers categoryId store
      | layers >= minimumLayers && categoryId == target = Just (replacement, store)
      | otherwise = case lookupCategory categoryId store of
          Just (Functional nodeSlash result argument) | nodeSlash == slash -> do
            (newResult, store') <- go (layers + 1) result store
            Just (internFunctional slash newResult argument store')
          _ -> Nothing
