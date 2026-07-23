{-# LANGUAGE OverloadedStrings #-}

module PropertySpec (tests) where

import CCG.Atom (defaultAtomTable)
import CCG.CategoryStore
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.QuickCheck

tests :: TestTree
tests = testGroup "properties"
  [ testProperty "category pretty/parse roundtrip" $ forAll (elements categorySamples) roundtrip
  , testProperty "interning idempotence" $ forAll (elements categorySamples) idempotent
  ]
  where
    categorySamples = ["S", "NP", "S/NP", "S\\NP", "(S\\NP)/NP", "S/(S\\NP)"] :: [Text]
    roundtrip text = case parseCategory text defaultAtomTable emptyCategoryStore of
      Left _ -> False
      Right (categoryId, atoms, store) -> prettyCategory atoms store categoryId == Right text
    idempotent text = case parseCategory text defaultAtomTable emptyCategoryStore of
      Left _ -> False
      Right (firstId, atoms, store) -> case parseCategory text atoms store of
        Left _ -> False
        Right (secondId, _, store') -> firstId == secondId && categoryCount store == categoryCount store'
