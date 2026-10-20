{-# LANGUAGE OverloadedStrings #-}

-- | Non-combinatory CCG rules for coordination and punctuation, following the
-- English lexicon of lightblue (<https://github.com/DaisukeBekki/lightblue>,
-- @Parser/CCG.hs@: @coordinationRule@, @periodRule@, @punctRule@).
--
-- The rules are keyed to three reserved atoms, which must be declared in
-- @atoms.predefined@ to be usable:
--
-- @
-- Coordination           X  CONJ  X   => X
-- Period absorption      S  PERIOD    => S
-- Punctuation absorption X  PUNCT     => X   (result of X is not N)
-- @
module CCG.SpecialRules
  ( SpecialCategories (..)
  , noSpecialCategories
  , specialCategories
  , coordinationAtomName
  , periodAtomName
  , punctuationAtomName
  , punctuationAbsorption
  , periodAbsorption
  , coordination
  ) where

import CCG.Atom (AtomTable, lookupAtom)
import CCG.Category (CategoryId, CategoryNode (..))
import CCG.CategoryStore (CategoryStore, lookupCategory, lookupNode)
import Data.Text (Text)

-- | Identifiers of the reserved categories in one category store.  'Nothing'
-- means the atom is not declared or no category uses it, so the corresponding
-- rule cannot fire.
data SpecialCategories = SpecialCategories
  { conjunctionCategory :: !(Maybe CategoryId)
  , periodCategory :: !(Maybe CategoryId)
  , punctuationCategory :: !(Maybe CategoryId)
  , nounCategory :: !(Maybe CategoryId)
  , sentenceCategory :: !(Maybe CategoryId)
  } deriving (Eq, Show)

noSpecialCategories :: SpecialCategories
noSpecialCategories = SpecialCategories Nothing Nothing Nothing Nothing Nothing

coordinationAtomName, periodAtomName, punctuationAtomName :: Text
coordinationAtomName = "CONJ"
periodAtomName = "PERIOD"
punctuationAtomName = "PUNCT"

specialCategories :: AtomTable -> CategoryStore -> SpecialCategories
specialCategories atoms store = SpecialCategories
  (atomic coordinationAtomName) (atomic periodAtomName) (atomic punctuationAtomName) (atomic "N") (atomic "S")
  where
    atomic name = lookupAtom name atoms >>= \atomId -> lookupNode (Atomic atomId) store

-- | @X PUNCT => X@.  As in lightblue's @isBunsetsu@ for English categories,
-- nominal categories (whose final result is @N@) do not absorb punctuation.
punctuationAbsorption :: SpecialCategories -> CategoryStore -> CategoryId -> CategoryId -> Maybe CategoryId
punctuationAbsorption special store left right
  | Just right == punctuationCategory special && not (finalResultIs (nounCategory special) left) = Just left
  | otherwise = Nothing
  where
    finalResultIs target categoryId = case lookupCategory categoryId store of
      Just (Functional _ result _) -> finalResultIs target result
      _ -> Just categoryId == target

-- | @S PERIOD => S@ for the atomic sentence category.
periodAbsorption :: SpecialCategories -> CategoryId -> CategoryId -> Maybe CategoryId
periodAbsorption special left right
  | Just right == periodCategory special && Just left == sentenceCategory special = Just left
  | otherwise = Nothing

-- | @X CONJ X => X@ for identical conjunct categories.
coordination :: SpecialCategories -> CategoryId -> CategoryId -> CategoryId -> Maybe CategoryId
coordination special left conjunction right
  | Just conjunction == conjunctionCategory special && left == right = Just left
  | otherwise = Nothing
