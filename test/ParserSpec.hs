{-# LANGUAGE OverloadedStrings #-}

module ParserSpec (tests) where

import Corpus.Types (Sentence (..))
import qualified Data.Map.Strict as Map
import Evaluation.Coverage
  ( SentenceCoverage (..)
  , sentenceCoverageDetailsWithJobs
  , sentenceCoverageWithJobs
  )
import Grammar.Types (Grammar (..), grammarRules)
import Lexicon.Initialization (emptyGrammar, internNamedCategory)
import Lexicon.Types (insertEntry)
import Parser.Config (CategoryBounds (..), Config (..), ParserConfig (..), RuleConfig (..), defaultConfig, loadConfig)
import CCG.SpecialRules (periodAbsorption, punctuationAbsorption)
import Parser.FailureFrontier (ParseFailure (..), ParseStateSummary (..))
import Parser.Incremental
import Parser.State (GrammarRules (..), ParseCost (..), ParseLevel (..))
import qualified Data.IntMap.Strict as IntMap
import qualified Data.Set as Set
import Data.Text (Text)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "parser"
  [ testCase "application-only solution uses lowest level" $ do
      grammar <- toyGrammar
      case parseSentence defaultConfig (grammarCategories grammar) (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["John", "likes", "Mary"] of
        Parsed success -> successfulLevel success @?= ApplicationOnly
        Failed failure -> assertFailure (show failure)
  , testCase "lexicalized final punctuation and comma coordination use Application" $ do
      finalGrammar <- grammarWithRoot "S"
        [("John", "NP"), ("runs", "S\\NP"), ("!", "S\\S")]
      case parseSentence defaultConfig (grammarCategories finalGrammar) (grammarLexicon finalGrammar)
          (grammarRules finalGrammar) (rootCategory finalGrammar) ["John", "runs", "!"] of
        Parsed success -> successfulLevel success @?= ApplicationOnly
        Failed failure -> assertFailure (show failure)
      commaGrammar <- grammarWithRoot "S"
        [("John", "NP"), ("Mary", "NP"), ("runs", "S\\NP"), (",", "(S\\S)/S")]
      case parseSentence defaultConfig (grammarCategories commaGrammar) (grammarLexicon commaGrammar)
          (grammarRules commaGrammar) (rootCategory commaGrammar) ["John", "runs", ",", "Mary", "runs"] of
        Parsed success -> successfulLevel success @?= ApplicationOnly
        Failed failure -> assertFailure (show failure)
  , testCase "unknown lexical type returns structured failure" $ do
      grammar <- toyGrammar
      case runParser defaultConfig ApplicationOnly (grammarCategories grammar) (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["Nobody"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "unexpected parse"
  , testCase "composition is retained when its result has a right consumer" $ do
      grammar <- grammarWithRoot "T"
        [("left", "X/Y"), ("middle", "Y/Z"), ("consumer", "T\\(X/Z)")]
      case runParser defaultConfig WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["left", "middle", "consumer"] of
        Parsed success -> compositionUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "composition that completes the root is kept" $ do
      grammar <- grammarWithRoot "X/Z" [("left", "X/Y"), ("middle", "Y/Z")]
      case runParser defaultConfig WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["left", "middle"] of
        Parsed success -> compositionUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "composition is pruned without any consumer" $ do
      -- "unused" only interns X/Z so the test can recognise it on the stack.
      grammar <- grammarWithRoot "T" [("left", "X/Y"), ("middle", "Y/Z"), ("unused", "X/Z")]
      composed <- case internNamedCategory "X/Z" grammar of
        Left message -> assertFailure (show message) >> pure (rootCategory grammar)
        Right (categoryId, _) -> pure categoryId
      case runParser defaultConfig WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["left", "middle"] of
        Failed failure -> assertBool "unconsumed Composition result entered the beam"
          (all ((/= [composed]) . summaryStack) (survivingStates failure))
        Parsed _ -> assertFailure "unexpected parse"
  , testCase "crossed composition is configuration-gated" $ do
      grammar <- grammarWithRoot "T"
        [("left", "X/Y"), ("middle", "Y\\Z"), ("consumer", "T\\(X\\Z)")]
      case runParser defaultConfig WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["left", "middle", "consumer"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "crossed Composition ignored its disabled flag"
      let enabled = defaultConfig
            { rules = (rules defaultConfig) { allowCrossedComposition = True } }
      case runParser enabled WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["left", "middle", "consumer"] of
        Parsed success -> compositionUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "generalized composition is configuration-gated" $ do
      grammar <- grammarWithRoot "T"
        [("left", "X/Y"), ("middle", "(Y/Z)/W"), ("consumer", "T\\((X/Z)/W)")]
      case runParser defaultConfig WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["left", "middle", "consumer"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "generalized Composition ignored its disabled flag"
      let enabled = defaultConfig
            { rules = (rules defaultConfig) { allowGeneralizedComposition = True } }
      case runParser enabled WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["left", "middle", "consumer"] of
        Parsed success -> compositionUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "backward second-order composition parses when enabled" $ do
      grammar <- grammarWithRoot "T"
        [("left", "(Y\\Z)\\W"), ("middle", "X\\Y"), ("consumer", "T\\((X\\Z)\\W)")]
      let enabled = defaultConfig
            { rules = (rules defaultConfig) { allowGeneralizedComposition = True } }
      case runParser enabled WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["left", "middle", "consumer"] of
        Parsed success -> compositionUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "generalized composition respects max_composition_degree" $ do
      grammar <- grammarWithRoot "T"
        [("left", "X/Y"), ("middle", "((Y/Z)/W)/V"), ("consumer", "T\\(((X/Z)/W)/V)")]
      let withDegree degree = defaultConfig
            { rules = (rules defaultConfig) { allowGeneralizedComposition = True, maxCompositionDegree = degree } }
          parse config = runParser config WithComposition (grammarCategories grammar)
            (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["left", "middle", "consumer"]
      case parse (withDegree 2) of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "third-order Composition exceeded max_composition_degree 2"
      case parse (withDegree 3) of
        Parsed success -> compositionUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "default YAML limits generalized composition to second order" $ do
      loaded <- loadConfig "configs/default.yaml"
      case loaded of
        Left message -> assertFailure message
        Right config -> do
          allowGeneralizedComposition (rules config) @?= True
          maxCompositionDegree (rules config) @?= 2
  , testCase "generalized composition cannot escape category bounds" $ do
      grammar <- grammarWithRoot "T"
        [("left", "(X/A)/Y"), ("middle", "(Y/Z)/W"), ("consumer", "T\\(((X/A)/Z)/W)")]
      let enabled = defaultConfig
            { categories = (categories defaultConfig) { maxSlashes = 2 }
            , rules = (rules defaultConfig) { allowGeneralizedComposition = True }
            }
      case runParser enabled WithComposition (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["left", "middle", "consumer"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "generalized Composition escaped max_slashes"
  , testCase "shift-reduce parsing preserves token order" $ do
      grammar <- grammarWithRoot "S" [("fun", "S/NP"), ("arg", "NP")]
      case runParser defaultConfig ApplicationOnly (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["fun", "arg"] of
        Parsed _ -> pure ()
        Failed failure -> assertFailure (show failure)
      case runParser defaultConfig ApplicationOnly (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) ["arg", "fun"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "parser reordered tokens instead of shifting left-to-right"
  , testCase "type-raising is fused with immediate composition" $ do
      grammar <- grammarWithRoot "T"
        [("subject", "NP"), ("verb", "(S\\NP)/NP"), ("consumer", "T\\(S/NP)")]
      case runParser defaultConfig WithTypeRaising (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar)
          ["subject", "verb", "consumer"] of
        Parsed success -> do
          typeRaisingUses (successfulCost success) @?= 1
          compositionUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "type-raised category cannot survive awaiting later input" $ do
      grammar <- grammarWithRoot "S/(S\\NP)" [("subject", "NP")]
      case runParser defaultConfig WithTypeRaising (grammarCategories grammar)
          (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar)
          ["subject"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "standalone raised lexical state entered the beam"
  , testCase "composition consumed by the left neighbour at sentence end" $ do
      grammar <- grammarWithRoot "S" [("f", "S/(A/C)"), ("g", "A/B"), ("h", "B/C")]
      expectParse WithComposition grammar ["f", "g", "h"]
  , testCase "sentence-final object relative uses Type-raising and Composition" $ do
      grammar <- grammarWithRoot "S" relativeClauseLexicon
      expectParse WithTypeRaising grammar ["Mary", "saw", "the", "book", "that", "John", "read"]
  , testCase "sentence-internal object relative uses Type-raising and Composition" $ do
      grammar <- grammarWithRoot "S" relativeClauseLexicon
      expectParse WithTypeRaising grammar ["the", "book", "that", "John", "read", "is", "red"]
  , testCase "derived NP constituents may be type-raised" $ do
      grammar <- grammarWithRoot "S" relativeClauseLexicon
      expectParse WithTypeRaising grammar ["Mary", "saw", "the", "book", "that", "the", "man", "read"]
  , testCase "only raisable constituents are type-raised" $ do
      -- Fused Type-raising results are pushed as non-raisable, which is what
      -- prevents a constituent from being raised twice.
      grammar <- grammarWithRoot "S" [("John", "NP"), ("read", "(S\\NP)/NP")]
      let categoryOf text = either (const (rootCategory grammar)) fst (internNamedCategory text grammar)
          reductions raisable = fst (pairReductions defaultConfig WithTypeRaising (grammarRules grammar)
            (grammarCategories grammar) (categoryOf "NP", raisable) (categoryOf "(S\\NP)/NP", False))
      map reductionUsesTypeRaising (reductions True) @?= [True]
      reductions False @?= []
  , testCase "generalized composition results outside the pre-interned universe stay distinct" $ do
      -- s y => (S\Z)\W by generalized crossed Composition.  Neither (S\Z)\W nor
      -- S\Z occurs in the lexicon, so the result must be interned before W and
      -- then Z are applied to it from the left.
      grammar <- grammarWithRoot "S" [("z", "Z"), ("w", "W"), ("s", "S/Y"), ("y", "(Y\\Z)\\W")]
      let config = defaultConfig
            { rules = (rules defaultConfig) { allowCrossedComposition = True, allowGeneralizedComposition = True } }
      case parseSentence config (grammarCategories grammar) (grammarLexicon grammar)
          (grammarRules grammar) (rootCategory grammar) ["z", "w", "s", "y"] of
        Parsed success -> successfulLevel success @?= WithComposition
        Failed failure -> assertFailure (show failure)
  , testCase "lightblue coordination combines identical conjuncts at the Application level" $ do
      grammar <- grammarWithRoot "S" lightblueLexicon
      expectParse ApplicationOnly grammar ["John", "and", "Mary", "sleep"]
      case parseSentence defaultConfig (grammarCategories grammar) (grammarLexicon grammar)
          (grammarRules grammar) (rootCategory grammar) ["John", "and", "sleep"] of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "coordinated NP with S\\NP"
  , testCase "a coordination result is never the left conjunct" $ do
      grammar <- grammarWithRoot "S" lightblueLexicon
      case parseSentence defaultConfig (grammarCategories grammar) (grammarLexicon grammar)
          (grammarRules grammar) (rootCategory grammar) ["John", "and", "Mary", "or", "Bill", "sleep"] of
        Parsed success -> parseCount success @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "period and punctuation absorption follow lightblue" $ do
      grammar <- grammarWithRoot "S" lightblueLexicon
      expectParse ApplicationOnly grammar ["John", ",", "sleep", "."]
      expectParse ApplicationOnly grammar ["Either", "John", "sleep", "or", "Mary", "sleep", "."]
      let special = ruleSpecialCategories (grammarRules grammar)
          categoryOf text = either (const (rootCategory grammar)) fst (internNamedCategory text grammar)
          absorbs text = punctuationAbsorption special (grammarCategories grammar) (categoryOf text) (categoryOf "PUNCT")
      absorbs "S\\NP" @?= Just (categoryOf "S\\NP")
      absorbs "N" @?= Nothing
      absorbs "N/N" @?= Nothing
      periodAbsorption special (categoryOf "NP") (categoryOf "PERIOD") @?= Nothing
  , testCase "coordination and absorption rules are configuration-gated" $ do
      grammar <- grammarWithRoot "S" lightblueLexicon
      let disabled = defaultConfig
            { rules = (rules defaultConfig)
                { allowCoordination = False, allowPeriodAbsorption = False, allowPunctuationAbsorption = False } }
          parse sentenceTokens = parseSentence disabled (grammarCategories grammar) (grammarLexicon grammar)
            (grammarRules grammar) (rootCategory grammar) sentenceTokens
      mapM_ (\sentenceTokens -> case parse sentenceTokens of
                Failed _ -> pure ()
                Parsed _ -> assertFailure ("disabled rule used for " <> show sentenceTokens))
        [["John", "and", "Mary", "sleep"], ["John", "sleep", "."], ["John", ",", "sleep"]]
  , testCase "composed conjuncts are kept for coordination" $ do
      -- John likes and Mary hates Bill: each conjunct is S/NP built by
      -- Type-raising and Composition, consumed only by coordination.
      grammar <- grammarWithRoot "S" lightblueLexicon
      expectParse WithTypeRaising grammar ["John", "likes", "and", "Mary", "hates", "Bill"]
  , testCase "ASP lets a subject combine with a transitive verb at the Application level" $ do
      -- read := (S\NP)/NP  ==ASP==>  (S/NP)\NP, so "John read" is S/NP by
      -- backward Application and the object relative needs no Type-raising.
      grammar <- grammarWithRoot "S" relativeClauseLexicon
      let sentenceTokens = ["Mary", "saw", "the", "book", "that", "John", "read"]
          parse config = parseSentence config (grammarCategories grammar) (grammarLexicon grammar)
            (grammarRules grammar) (rootCategory grammar) sentenceTokens
      case parse aspConfig of
        Parsed success -> do
          successfulLevel success @?= ApplicationOnly
          argumentSwapUses (successfulCost success) @?= 1
          typeRaisingUses (successfulCost success) @?= 0
        Failed failure -> assertFailure (show failure)
      case parse defaultConfig of
        Parsed success -> successfulLevel success @?= WithTypeRaising
        Failed failure -> assertFailure (show failure)
  , testCase "ASP is not used when no swap is needed" $ do
      grammar <- grammarWithRoot "S" relativeClauseLexicon
      case parseSentence aspConfig (grammarCategories grammar) (grammarLexicon grammar)
          (grammarRules grammar) (rootCategory grammar) ["John", "saw", "Mary"] of
        Parsed success -> argumentSwapUses (successfulCost success) @?= 0
        Failed failure -> assertFailure (show failure)
  , testCase "ASP swaps each constituent at most once and terminates" $ do
      -- With an unbounded reduction budget, re-swapping would loop forever.
      grammar <- grammarWithRoot "S" [("John", "NP"), ("likes", "(S\\NP)/NP")]
      let unbounded = aspConfig { parser = (parser aspConfig) { maxReductionsPerShift = 2147483647 } }
      case runParser unbounded ApplicationOnly (grammarCategories grammar) (grammarLexicon grammar)
          (grammarRules grammar) (rootCategory grammar) ["likes"] of
        Failed failure -> length (survivingStates failure) @?= 2
        Parsed _ -> assertFailure "a transitive verb alone parsed as S"
  , testCase "ASP results must stay within the depth bound" $ do
      -- (S\NP)/(Y/Z) has depth 3; its swap (S/(Y/Z))\NP has depth 4.
      grammar <- grammarWithRoot "T" [("f", "T/(S/(Y/Z))"), ("John", "NP"), ("w", "(S\\NP)/(Y/Z)")]
      let withDepth depth = aspConfig { categories = (categories aspConfig) { maxDepth = depth } }
          parse config = runParser config ApplicationOnly (grammarCategories grammar) (grammarLexicon grammar)
            (grammarRules grammar) (rootCategory grammar) ["f", "John", "w"]
      case parse (withDepth 3) of
        Failed _ -> pure ()
        Parsed _ -> assertFailure "ASP escaped max_depth"
      case parse (withDepth 4) of
        Parsed success -> argumentSwapUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "ASP works together with Composition" $ do
      -- f John g h needs one Composition (g with h, or John+g with h) and one
      -- ASP to let the subject John combine before the object of h.
      grammar <- grammarWithRoot "T"
        [("f", "T/(S/C)"), ("John", "NP"), ("g", "(S\\NP)/B"), ("h", "B/C")]
      case parseSentence aspConfig (grammarCategories grammar) (grammarLexicon grammar)
          (grammarRules grammar) (rootCategory grammar) ["f", "John", "g", "h"] of
        Parsed success -> do
          successfulLevel success @?= WithComposition
          argumentSwapUses (successfulCost success) @?= 1
        Failed failure -> assertFailure (show failure)
  , testCase "right reachability includes Application-derived prefixes" $ do
      grammar <- grammarWithRoot "S" [("zw", "Z/W"), ("w", "W")]
      let reachable = fst (rightReachableCategories defaultConfig WithComposition (grammarRules grammar) (grammarCategories grammar) (grammarLexicon grammar) ["zw", "w"])
      z <- case internNamedCategory "Z" grammar of
        Left message -> assertFailure (show message) >> pure (rootCategory grammar)
        Right (categoryId, _) -> pure categoryId
      assertBool "Z should be reachable from Z/W followed by W"
        (Set.member z (IntMap.findWithDefault Set.empty 0 reachable))
  , testCase "parallel coverage preserves input order and results" $ do
      grammar <- toyGrammar
      let corpus =
            [ Sentence "covered" ["John", "likes", "Mary"] [] [] [] Map.empty []
            , Sentence "uncovered" ["Nobody"] [] [] [] Map.empty []
            ]
      sentenceCoverageWithJobs 1 defaultConfig grammar corpus @?=
        sentenceCoverageWithJobs 2 defaultConfig grammar corpus
      sentenceCoverageDetailsWithJobs 1 defaultConfig grammar corpus @?=
        sentenceCoverageDetailsWithJobs 2 defaultConfig grammar corpus
  , testCase "sentence coverage reports token and word-type lexical coverage" $ do
      grammar <- toyGrammar
      let corpus =
            [ Sentence "partly-known" ["John", "Nobody", "Nobody"] [] [] [] Map.empty [] ]
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

relativeClauseLexicon :: [(Text, Text)]
relativeClauseLexicon =
  [ ("Mary", "NP"), ("John", "NP"), ("saw", "(S\\NP)/NP"), ("read", "(S\\NP)/NP")
  , ("the", "NP/N"), ("book", "N"), ("man", "N"), ("that", "(N\\N)/(S/NP)")
  , ("is", "(S\\NP)/AP"), ("red", "AP")
  ]

aspConfig :: Config
aspConfig = defaultConfig { rules = (rules defaultConfig) { allowArgumentSwap = True } }

lightblueLexicon :: [(Text, Text)]
lightblueLexicon =
  [ ("John", "NP"), ("Mary", "NP"), ("Bill", "NP"), ("sleep", "S\\NP")
  , ("likes", "(S\\NP)/NP"), ("hates", "(S\\NP)/NP")
  , ("and", "CONJ"), ("or", "CONJ"), ("Either", "((S/S)/CONJ)/S")
  , (".", "PERIOD"), (",", "PUNCT"), ("adj", "N/N"), ("noun", "N")
  ]

-- | The sentence must parse, and only at the expected rule level.
expectParse :: ParseLevel -> Grammar -> [Text] -> Assertion
expectParse level grammar sentenceTokens =
  case parseSentence defaultConfig (grammarCategories grammar) (grammarLexicon grammar)
      (grammarRules grammar) (rootCategory grammar) sentenceTokens of
    Parsed success -> successfulLevel success @?= level
    Failed failure -> assertFailure (show failure)
