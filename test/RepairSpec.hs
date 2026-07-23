{-# LANGUAGE OverloadedStrings #-}

module RepairSpec (tests) where

import CCG.Category (CategoryId (..))
import Lexicon.Repair (RepairScore (..))
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "repair"
  [ testCase "fewer categories dominates parse-space estimate" $
      assertBool "expected fewer added categories to sort first" $
        score 1 100 (CategoryId 2) "x" <= score 2 0 (CategoryId 1) "a"
  , testCase "candidate prior dominates parse-space estimate" $
      assertBool "expected lower prior cost to sort first" $
        score 1 0 (CategoryId 2) "x" <= (score 1 3 (CategoryId 1) "a") { repairParseSpaceDelta = 0 }
  , testCase "stable tie break uses category then word" $
      assertBool "expected category id to break ties before word" $
        score 1 3 (CategoryId 1) "z" <= score 1 3 (CategoryId 2) "a"
  ]

score :: Int -> Int -> CategoryId -> Text -> RepairScore
score added prior categoryId word = RepairScore added prior 3 1 1 0 categoryId word
