{-# LANGUAGE OverloadedStrings #-}

module ParserSpec (tests) where

import Corpus.Types (Sentence (..))
import qualified Data.Map.Strict as Map
import Evaluation.Coverage (sentenceCoverageWithJobs)
import Grammar.Types (Grammar (..))
import Lexicon.Initialization (emptyGrammar, internNamedCategory)
import Lexicon.Types (insertEntry)
import Parser.Config (defaultConfig)
import Parser.Incremental
import Parser.State (ParseCost (..), ParseLevel (..))
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Set as Set
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "parser"
  [ testCase "application-only solution uses lowest level" $ do
      grammar <- toyGrammar
      case parseSentence defaultConfig (grammarCategories grammar) (grammarLexicon grammar) (raisingTemplates grammar) (rootCategory grammar) ["John", "likes", "Mary"] of
        Parsed success -> successfulLevel success @?= ApplicationOnly
        Failed failure -> assertFailure (show failure)
  , testCase "unknown lexical type returns structured failure" $ do
      grammar <- toyGrammar
      case runParser defaultConfig ApplicationOnly (grammarCategories grammar) (grammarLexicon grammar) [] (rootCategory grammar) ["Nobody"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "unexpected parse"
  , testCase "composition is retained when its result has a right consumer" $ do
      grammar <- grammarWithRoot "T"
        [("left", "X/Y"), ("middle", "Y/Z"), ("consumer", "T\\(X/Z)")]
      case runParser defaultConfig WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) [] (rootCategory grammar) ["left", "middle", "consumer"] of
        Parsed success -> compositionUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "composition is pruned without a right consumer" $ do
      grammar <- grammarWithRoot "X/Z" [("left", "X/Y"), ("middle", "Y/Z")]
      case runParser defaultConfig WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) [] (rootCategory grammar) ["left", "middle"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "unconsumed Composition result entered the beam"
  , testCase "type-raising is fused with immediate composition" $ do
      grammar <- grammarWithRoot "T"
        [("subject", "NP"), ("verb", "(S\\NP)/NP"), ("consumer", "T\\(S/NP)")]
      case runParser defaultConfig WithTypeRaising (grammarCategories grammar)
          (grammarLexicon grammar) (raisingTemplates grammar) (rootCategory grammar)
          ["subject", "verb", "consumer"] of
        Parsed success -> do
          typeRaisingUses (successfulCost success) @?= 1
          compositionUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "type-raised category cannot survive awaiting later input" $ do
      grammar <- grammarWithRoot "S/(S\\NP)" [("subject", "NP")]
      case runParser defaultConfig WithTypeRaising (grammarCategories grammar)
          (grammarLexicon grammar) (raisingTemplates grammar) (rootCategory grammar)
          ["subject"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "standalone raised lexical state entered the beam"
  , testCase "right reachability includes Application-derived prefixes" $ do
      grammar <- grammarWithRoot "S" [("zw", "Z/W"), ("w", "W")]
      let reachable = rightReachableCategories (grammarCategories grammar) (grammarLexicon grammar) ["zw", "w"]
      z <- case internNamedCategory "Z" grammar of
        Left message -> assertFailure (show message) >> pure (rootCategory grammar)
        Right (categoryId, _) -> pure categoryId
      assertBool "Z should be reachable from Z/W followed by W"
        (Set.member z (IntMap.findWithDefault Set.empty 0 reachable))
  , testCase "parallel coverage preserves input order and results" $ do
      grammar <- toyGrammar
      let corpus =
            [ Sentence "covered" ["John", "likes", "Mary"] [] [] [] Map.empty
            , Sentence "uncovered" ["Nobody"] [] [] [] Map.empty
            ]
      sentenceCoverageWithJobs 1 defaultConfig grammar corpus @?=
        sentenceCoverageWithJobs 2 defaultConfig grammar corpus
  ]

toyGrammar :: IO Grammar
toyGrammar = grammarWithRoot "S" [("John", "NP"), ("likes", "(S\\NP)/NP"), ("Mary", "NP")]

grammarWithRoot :: Text -> [(Text, Text)] -> IO Grammar
grammarWithRoot rootText entries = case internNamedCategory rootText emptyGrammar >>= \(root, grammar) -> addMany grammar entries >>= \grammar' -> pure grammar' { rootCategory = root } of
  Left message -> assertFailure (show message) >> pure emptyGrammar
  Right grammar -> pure grammar
  where
    addMany grammar [] = Right grammar
    addMany grammar ((word, categoryText) : rest) = do
      (categoryId, grammar') <- internNamedCategory categoryText grammar
      addMany grammar' { grammarLexicon = insertEntry word categoryId (grammarLexicon grammar') } rest
