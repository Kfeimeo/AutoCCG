{-# LANGUAGE OverloadedStrings #-}

module EisnerSpec (tests) where

import CCG.Combinator (Combinator (..))
import CCG.Derivation (DerivationNode (..), lookupDerivation)
import Data.ByteString (ByteString)
import Data.Text (Text)
import Data.Yaml (decodeEither')
import Grammar.Types (Grammar (..), grammarRules)
import Lexicon.Initialization (emptyGrammar, internNamedCategory)
import Lexicon.Types (insertEntry)
import Parser.Config
import Parser.FailureFrontier (ParseFailure (..))
import Parser.Incremental
import Parser.State (ParseCost (..), ParseLevel (..))
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "Eisner normal-form parser"
  [ testCase "normal form keeps one derivation per reading (no spurious ambiguity)" $ do
      -- f g h = X/Y Y/Z Z: both f (g h) and (f >B g) h derive X, but the second
      -- uses a forward-Composition result as the primary functor of >.
      grammar <- grammarWithRoot "X" [("f", "X/Y"), ("g", "Y/Z"), ("h", "Z")]
      success <- expectParsed (eisnerConfig AllDerivations) grammar ["f", "g", "h"]
      parseCount success @?= 1
      length (allDerivations success) @?= 1
      rootRule success @?= Just ForwardApplication
      compositionUses (successfulCost success) @?= 0
  , testCase "all derivations: PP attachment has two readings" $ do
      grammar <- grammarWithRoot "S" ppLexicon
      success <- expectParsed (eisnerConfig AllDerivations) grammar ppSentence
      parseCount success @?= 2
      length (allDerivations success) @?= 2
  , testCase "first derivation keeps one tree but still counts the readings" $ do
      grammar <- grammarWithRoot "S" ppLexicon
      success <- expectParsed (eisnerConfig FirstDerivation) grammar ppSentence
      parseCount success @?= 2
      allDerivations success @?= [rootDerivation success]
  , testCase "Composition is used when Application alone fails" $ do
      grammar <- grammarWithRoot "T" [("left", "X/Y"), ("middle", "Y/Z"), ("consumer", "T\\(X/Z)")]
      success <- expectParsed (eisnerConfig AllDerivations) grammar ["left", "middle", "consumer"]
      successfulLevel success @?= WithComposition
      compositionUses (successfulCost success) @?= 1
      parseCount success @?= 1
  , testCase "second-order Composition is available" $ do
      grammar <- grammarWithRoot "T" [("left", "X/Y"), ("middle", "(Y/Z)/W"), ("consumer", "T\\((X/Z)/W)")]
      success <- expectParsed (eisnerConfig FirstDerivation) grammar ["left", "middle", "consumer"]
      rootRule success @?= Just BackwardApplication
      compositionUses (successfulCost success) @?= 1
  , testCase "a failed parse reports the longest constituent prefix" $ do
      grammar <- grammarWithRoot "S" ppLexicon
      case parse (eisnerConfig FirstDerivation) grammar ["John", "saw", "Nobody"] of
        Failed failure -> farthestPosition failure @?= 2
        Parsed _ -> assertFailure "unknown word parsed"
  , testCase "eisner configuration rejects rules the parser does not implement" $ do
      case decodeConfig "parser: {algorithm: eisner}\nrules: {allow_argument_swap: true}\n" of
        Left message -> assertBool message True
        Right _ -> assertFailure "eisner accepted ASP"
      case decodeConfig "parser: {algorithm: eisner, derivations: all}\nrules: {allow_coordination: false, allow_period_absorption: false, allow_punctuation_absorption: false}\n" of
        Left message -> assertFailure message
        Right config -> do
          parserAlgorithm (parser config) @?= EisnerNormalForm
          derivationOutput (parser config) @?= AllDerivations
  , testCase "configs/eisner.yaml selects the Eisner parser and first derivation" $ do
      loaded <- loadConfig "configs/eisner.yaml"
      case loaded of
        Left message -> assertFailure message
        Right config -> do
          parserAlgorithm (parser config) @?= EisnerNormalForm
          derivationOutput (parser config) @?= FirstDerivation
          allowCrossedComposition (rules config) @?= False
          maxCompositionDegree (rules config) @?= 2
  ]

ppLexicon :: [(Text, Text)]
ppLexicon =
  [ ("John", "NP"), ("Mary", "NP"), ("telescopes", "NP"), ("saw", "(S\\NP)/NP")
  , ("with", "((S\\NP)\\(S\\NP))/NP"), ("with", "(NP\\NP)/NP")
  ]

ppSentence :: [Text]
ppSentence = ["John", "saw", "Mary", "with", "telescopes"]

eisnerConfig :: DerivationOutput -> Config
eisnerConfig output = defaultConfig
  { parser = (parser defaultConfig) { parserAlgorithm = EisnerNormalForm, derivationOutput = output }
  , rules = (rules defaultConfig)
      { allowGeneralizedComposition = True
      , allowCoordination = False, allowPeriodAbsorption = False, allowPunctuationAbsorption = False
      }
  }

parse :: Config -> Grammar -> [Text] -> ParseOutcome
parse config grammar = parseSentence config (grammarCategories grammar) (grammarLexicon grammar)
  (grammarRules grammar) (rootCategory grammar)

expectParsed :: Config -> Grammar -> [Text] -> IO ParseSuccess
expectParsed config grammar sentenceTokens = case parse config grammar sentenceTokens of
  Parsed success -> pure success
  Failed failure -> assertFailure (show failure) >> fail "unreachable"

rootRule :: ParseSuccess -> Maybe Combinator
rootRule success = case lookupDerivation (rootDerivation success) (finalArena success) of
  Just (BinaryNode combinator _ _ _) -> Just combinator
  _ -> Nothing

decodeConfig :: ByteString -> Either String Config
decodeConfig = either (Left . show) Right . decodeEither'

grammarWithRoot :: Text -> [(Text, Text)] -> IO Grammar
grammarWithRoot rootText entries = case internNamedCategory rootText emptyGrammar >>= \(root, grammar) -> addMany grammar entries >>= \grammar' -> pure grammar' { rootCategory = root } of
  Left message -> assertFailure (show message) >> pure emptyGrammar
  Right grammar -> pure grammar
  where
    addMany grammar [] = Right grammar
    addMany grammar ((word, categoryText) : rest) = do
      (categoryId, grammar') <- internNamedCategory categoryText grammar
      addMany grammar' { grammarLexicon = insertEntry word categoryId (grammarLexicon grammar') } rest
