{-# LANGUAGE OverloadedStrings #-}

module CategorySpec (tests) where

import CCG.Atom (defaultAtomTable)
import CCG.CategoryStore
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "category"
  [ testCase "parse/pretty nested category" $ do
      let parsed = parseCategory "(S\\NP)/NP" defaultAtomTable emptyCategoryStore
      case parsed of
        Left message -> assertFailure (show message)
        Right (categoryId, atoms, store) -> prettyCategory atoms store categoryId @?= Right "(S\\NP)/NP"
  , testCase "interning is idempotent" $ do
      let Right (firstId, atoms, store) = parseCategory "NP" defaultAtomTable emptyCategoryStore
          Right (secondId, _, store') = parseCategory "NP" atoms store
      firstId @?= secondId
      categoryCount store' @?= categoryCount store
  , testCase "rejects malformed category" $
      case parseCategory "S/(NP" defaultAtomTable emptyCategoryStore of Left _ -> pure (); Right _ -> assertFailure "accepted malformed input"
  ]
