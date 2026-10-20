module CCG.Combinator
  ( Combinator (..)
  , applyCombinator
  , applicationResults
  , compositionResults
  , argumentSwap
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

-- | The 'Int' is the maximum generalized Composition degree n of B^n.
-- Generalized combinators produce degrees 2..n only; first-order Composition
-- is always degree one and is unaffected.
applyCombinator :: Int -> Combinator -> CategoryStore -> CategoryId -> CategoryId -> Maybe (CategoryId, CategoryStore)
applyCombinator maxDegree combinator store left right = case combinator of
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
    Just (Functional ForwardSlash x y) -> replaceResultSpine ForwardSlash maxDegree y x right store
    _ -> Nothing
  BackwardGeneralizedComposition -> case lookupCategory right store of
    Just (Functional BackwardSlash x y) -> replaceResultSpine BackwardSlash maxDegree y x left store
    _ -> Nothing
  ForwardGeneralizedCrossedComposition -> case lookupCategory left store of
    Just (Functional ForwardSlash x y) -> replaceResultSpine BackwardSlash maxDegree y x right store
    _ -> Nothing
  BackwardGeneralizedCrossedComposition -> case lookupCategory right store of
    Just (Functional BackwardSlash x y) -> replaceResultSpine ForwardSlash maxDegree y x left store
    _ -> Nothing

applicationResults :: CategoryStore -> CategoryId -> CategoryId -> [(Combinator, CategoryId, CategoryStore)]
applicationResults store left right = results [ForwardApplication, BackwardApplication]
  where
    results = foldr collect []
    collect combinator acc = case applyCombinator 1 combinator store left right of
      Nothing -> acc
      Just (categoryId, store') -> (combinator, categoryId, store') : acc

-- | All Composition results in combinator order, with generalized rules
-- bounded by the maximum degree (see 'applyCombinator').  The store is
-- threaded through every combinator, so each new result category is interned
-- in the returned store and distinct results never share an identifier.
compositionResults :: Int -> CategoryStore -> CategoryId -> CategoryId -> ([(Combinator, CategoryId)], CategoryStore)
compositionResults maxDegree initialStore left right = results
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
    results combinators =
      let (found, finalStore) = foldl' collect ([], initialStore) combinators
       in (reverse found, finalStore)
    collect (acc, store) combinator = case applyCombinator maxDegree combinator store left right of
      Nothing -> (acc, store)
      Just (categoryId, store') -> ((combinator, categoryId) : acc, store')

-- | ASP, argument swap: @(X\A)/B <=> (X/B)\A@.  The two outermost arguments
-- of opposite directions are consumed in the other order; @A@ stays on the
-- left and @B@ on the right, so word order and meaning are unchanged.  Applying
-- it twice gives back the original category.  The slash count and arity are
-- preserved, but the depth may change, so callers must re-check depth bounds.
argumentSwap :: CategoryStore -> CategoryId -> Maybe (CategoryId, CategoryStore)
argumentSwap store categoryId = case lookupCategory categoryId store of
  Just (Functional outerSlash inner outerArgument)
    | Just (Functional innerSlash result innerArgument) <- lookupCategory inner store
    , innerSlash /= outerSlash ->
        let (swappedInner, store') = internFunctional outerSlash result outerArgument store
         in Just (internFunctional innerSlash swappedInner innerArgument store')
  _ -> Nothing

-- | Replace the result at the base of a uniform slash spine.  Requiring at
-- least two spine layers keeps first-order Composition represented by its
-- dedicated combinators and makes generalized rule use explicit in costs and
-- diagnostics.  The spine is never descended below @maxDegree@ layers, so
-- B^n for n > maxDegree cannot be produced (e.g. degree 2 admits only
-- X/Y (Y/Z)/W => (X/Z)/W and its mirror images).
replaceResultSpine
  :: Slash
  -> Int
  -> CategoryId
  -> CategoryId
  -> CategoryId
  -> CategoryStore
  -> Maybe (CategoryId, CategoryStore)
replaceResultSpine slash maxDegree target replacement = go 0
  where
    minimumLayers = 2 :: Int
    go layers categoryId store
      | layers > maxDegree = Nothing
      | layers >= minimumLayers && categoryId == target = Just (replacement, store)
      | otherwise = case lookupCategory categoryId store of
          Just (Functional nodeSlash result argument) | nodeSlash == slash -> do
            (newResult, store') <- go (layers + 1) result store
            Just (internFunctional slash newResult argument store')
          _ -> Nothing
