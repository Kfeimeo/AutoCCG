module Lexicon.Candidate
  ( boundedCategoryUniverse
  , inverseApplicationCandidates
  ) where

import CCG.Category (CategoryId, Slash (..), categoryArity, categoryDepth, categorySlashCount)
import CCG.CategoryStore
import Parser.Config (CategoryBounds (..))

boundedCategoryUniverse :: CategoryBounds -> CategoryStore -> ([CategoryId], CategoryStore)
boundedCategoryUniverse bounds initial =
  let seeds = map fst (allCategories initial)
      pairs = [(result, argument, slash) | result <- seeds, argument <- seeds, slash <- [ForwardSlash, BackwardSlash]]
      (created, finalStore) = foldl' add (seeds, initial) pairs
   in (filter (within finalStore) created, finalStore)
  where
    add (ids, store) (result, argument, slash) =
      let (categoryId, store') = internFunctional slash result argument store
       in if within store' categoryId then (categoryId : ids, store') else (ids, store')
    within store categoryId =
      categoryDepth (`lookupCategory` store) categoryId <= maxDepth bounds
        && categorySlashCount (`lookupCategory` store) categoryId <= maxSlashes bounds
        && categoryArity (`lookupCategory` store) categoryId <= maxArity bounds

inverseApplicationCandidates :: CategoryStore -> CategoryId -> CategoryId -> ([CategoryId], CategoryStore)
inverseApplicationCandidates store target neighbor =
  let (forward, store') = internFunctional ForwardSlash target neighbor store
      (backward, store'') = internFunctional BackwardSlash target neighbor store'
   in ([forward, backward], store'')
