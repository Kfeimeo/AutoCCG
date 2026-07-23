{-# LANGUAGE OverloadedStrings #-}

module CombinatorSpec (tests) where

import CCG.Atom (defaultAtomTable)
import CCG.Category (CategoryId)
import CCG.CategoryStore
import CCG.Combinator
import Control.Monad (foldM)
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "combinators"
  [ testCase "forward application" $ fixture ["S/NP", "NP", "S"] $ \[fun, arg, target] store ->
      fmap (\(_, result, _) -> result) (single (applicationResults store fun arg)) @?= Just target
  , testCase "backward application" $ fixture ["NP", "S\\NP", "S"] $ \[arg, fun, target] store ->
      fmap (\(_, result, _) -> result) (single (applicationResults store arg fun)) @?= Just target
  , testCase "forward composition" $ fixture ["X/Y", "Y/Z", "X/Z"] $ \[left, right, target] store ->
      fmap (\(_, result, _) -> result) (single (compositionResults store left right)) @?= Just target
  , testCase "invalid combination" $ fixture ["NP", "NP"] $ \[left, right] store ->
      applicationResults store left right @?= []
  ]
  where single [value] = Just value; single _ = Nothing

fixture :: [Text] -> ([CategoryId] -> CategoryStore -> Assertion) -> Assertion
fixture texts assertion = case foldM add ([], defaultAtomTable, emptyCategoryStore) texts of
  Left message -> assertFailure (show message)
  Right (ids, _, store) -> assertion ids store
  where
    add (ids, atoms, store) text = do
      (categoryId, atoms', store') <- parseCategory text atoms store
      pure (ids ++ [categoryId], atoms', store')
