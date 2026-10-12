{-# LANGUAGE OverloadedStrings #-}

module ParserSpec (tests) where

import Corpus.Types (Sentence (..))
import qualified Data.Map.Strict as Map
import Evaluation.Coverage
  ( SentenceCoverage (..)
  , sentenceCoverageDetailsWithJobs
  , sentenceCoverageWithJobs
  )
import Grammar.Types (Grammar (..))
import Lexicon.Initialization (emptyGrammar, internNamedCategory)
import Lexicon.Types (insertEntry)
import Parser.Config (CategoryBounds (..), Config (..), RuleConfig (..), defaultConfig)
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
  , testCase "lexicalized final punctuation and comma coordination use Application" $ do
      finalGrammar <- grammarWithRoot "S"
        [("John", "NP"), ("runs", "S\\NP"), ("!", "S\\S")]
      case parseSentence defaultConfig (grammarCategories finalGrammar) (grammarLexicon finalGrammar)
          [] (rootCategory finalGrammar) ["John", "runs", "!"] of
        Parsed success -> successfulLevel success @?= ApplicationOnly
        Failed failure -> assertFailure (show failure)
      commaGrammar <- grammarWithRoot "S"
        [("John", "NP"), ("Mary", "NP"), ("runs", "S\\NP"), (",", "(S\\S)/S")]
      case parseSentence defaultConfig (grammarCategories commaGrammar) (grammarLexicon commaGrammar)
          [] (rootCategory commaGrammar) ["John", "runs", ",", "Mary", "runs"] of
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
  , testCase "crossed composition is configuration-gated" $ do
      grammar <- grammarWithRoot "T"
        [("left", "X/Y"), ("middle", "Y\\Z"), ("consumer", "T\\(X\\Z)")]
      case runParser defaultConfig WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) [] (rootCategory grammar) ["left", "middle", "consumer"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "crossed Composition ignored its disabled flag"
      let enabled = defaultConfig
            { rules = (rules defaultConfig) { allowCrossedComposition = True } }
      case runParser enabled WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) [] (rootCategory grammar) ["left", "middle", "consumer"] of
        Parsed success -> compositionUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "generalized composition is configuration-gated" $ do
      grammar <- grammarWithRoot "T"
        [("left", "X/Y"), ("middle", "(Y/Z)/W"), ("consumer", "T\\((X/Z)/W)")]
      case runParser defaultConfig WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) [] (rootCategory grammar) ["left", "middle", "consumer"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "generalized Composition ignored its disabled flag"
      let enabled = defaultConfig
            { rules = (rules defaultConfig) { allowGeneralizedComposition = True } }
      case runParser enabled WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) [] (rootCategory grammar) ["left", "middle", "consumer"] of
        Parsed success -> compositionUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "generalized composition cannot escape category bounds" $ do
      grammar <- grammarWithRoot "T"
        [("left", "(X/A)/Y"), ("middle", "(Y/Z)/W"), ("consumer", "T\\(((X/A)/Z)/W)")]
      let enabled = defaultConfig
            { categories = (categories defaultConfig) { maxSlashes = 2 }
            , rules = (rules defaultConfig) { allowGeneralizedComposition = True }
            }
      case runParser enabled WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) [] (rootCategory grammar) ["left", "middle", "consumer"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "generalized Composition escaped max_slashes"
  , testCase "shift-reduce parsing preserves token order" $ do
      grammar <- grammarWithRoot "S" [("fun", "S/NP"), ("arg", "NP")]
      case runParser defaultConfig ApplicationOnly (grammarCategories grammar)
          (grammarLexicon grammar) [] (rootCategory grammar) ["fun", "arg"] of
        Parsed _ -> pure ()
        Failed failure -> assertFailure (show failure)
      case runParser defaultConfig ApplicationOnly (grammarCategories grammar)
          (grammarLexicon grammar) [] (rootCategory grammar) ["arg", "fun"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "parser reordered tokens instead of shifting left-to-right"
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
      sentenceCoverageDetailsWithJobs 1 defaultConfig grammar corpus @?=
        sentenceCoverageDetailsWithJobs 2 defaultConfig grammar corpus
  , testCase "sentence coverage reports token and word-type lexical coverage" $ do
      grammar <- toyGrammar
      let corpus =
            [ Sentence "partly-known" ["John", "Nobody", "Nobody"] [] [] [] Map.empty ]
      case sentenceCoverageDetailsWithJobs 1 defaultConfig grammar corpus of
        [result] -> do
          coverageCovered result @?= False
          coverageTokenCount result @?= 3
          coverageCategorizedTokenCount result @?= 1
          coverageCategorizedTokenRate result @?= (1 / 3)
          coverageWordTypeCount result @?= 2
          coverageCategorizedWordTypeCount result @?= 1
          coverageCategorizedWordTypeRate result @?= 0.5
          coverageCategoryAssignmentCount result @?= 1
          coverageUncategorizedWords result @?= ["Nobody"]
          coverageFarthestPosition result @?= Just 1
        results -> assertFailure ("unexpected coverage results: " <> show results)
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
