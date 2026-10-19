{-# LANGUAGE OverloadedStrings #-}

module PosMappingSpec (tests) where

import CCG.Atom (AtomTable)
import CCG.CategoryStore (CategoryStore, prettyCategory)
import Corpus.Types (Sentence (..))
import Data.ByteString (ByteString)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Yaml (decodeEither')
import Grammar.Types (Grammar (..))
import Lexicon.CandidateLexicon
import Lexicon.Initialization (emptyGrammar, initializeSentenceWords)
import Lexicon.PosMapping
import Lexicon.Types (categoriesForWord)
import Parser.Config
import Serialization.CandidateLexicon (encodeCandidateLexicon)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "POS mapping"
  [ testCase "first matching rule wins" $ do
      let proper = PosRule (ExactTags ["NNP"]) [] [CandidateTemplateConfig "NP" 0]
          common = PosRule (TagPrefix "NN") [] [CandidateTemplateConfig "N" 0]
          categoriesOf rules = fmap (map templateCategory) . resolvePosTemplates (PosMapping Map.empty rules)
      categoriesOf [proper, common] "NNP" @?= Just ["NP"]
      categoriesOf [common, proper] "NNP" @?= Just ["N"]
      categoriesOf [proper, common] "NNS" @?= Just ["N"]
      categoriesOf [proper, common] "VBZ" @?= Nothing
      categoriesOf [proper, common] "" @?= Nothing
  , testCase "rules expand named templates in order, then inline categories" $ do
      let mapping = PosMapping
            (Map.fromList
              [ ("verb", [CandidateTemplateConfig "S\\NP" 0])
              , ("modifier", [CandidateTemplateConfig "N/N" 2])
              ])
            [PosRule (ExactTags ["VBG"]) ["verb", "modifier"] [CandidateTemplateConfig "NP" 3]]
      map templateCategory <$> resolvePosTemplates mapping "VBG" @?= Just ["S\\NP", "N/N", "NP"]
  , testCase "YAML rejects undefined template references" $
      assertDecodeFailure "undefined template"
        "pos_mapping:\n  templates: {}\n  rules:\n    - {tag: NN, templates: [missing]}\n"
  , testCase "YAML rejects rules with ambiguous matchers" $
      assertDecodeFailure "exactly one of tag, tags, or prefix"
        "pos_mapping:\n  rules:\n    - {tag: NN, prefix: \"N\", categories: [{category: \"N\"}]}\n"
  , testCase "flat pos_to_categories shorthand is tried after the cascade" $
      case decodeConfig "pos_mapping:\n  rules:\n    - {tag: NN, categories: [{category: \"N\"}]}\npos_to_categories:\n  NN: [{category: \"NP\"}]\n  VB: [{category: \"S\\\\NP\"}]\n" of
        Left message -> assertFailure message
        Right config -> do
          let resolve = fmap (map templateCategory) . resolvePosTemplates (posMapping config)
          resolve "NN" @?= Just ["N"]
          resolve "VB" @?= Just ["S\\NP"]
  , testCase "default YAML maps NLTK Penn Treebank tags" $ do
      config <- requireDefaultConfig
      withCandidates config emptyWordNetInventory
        [ sentenceWith ["John", "likes", "the", "running", "dog", "."] [] ["NNP", "VBZ", "DT", "VBG", "NN", "."]
        , sentenceWith ["bigger"] [] ["JJR"]
        ] $ \atoms store candidates -> do
          let categoriesOf word = render atoms store (candidateCategoriesForWord word candidates)
          take 1 (categoriesOf "John") @?= ["NP"]
          assertElem "(S\\NP)/NP" (categoriesOf "likes")
          take 1 (categoriesOf "the") @?= ["NP/N"]
          assertElem "N/N" (categoriesOf "running")
          assertElem "S\\NP" (categoriesOf "running")
          take 1 (categoriesOf "dog") @?= ["N"]
          categoriesOf "." @?= ["S\\S"]
          assertElem "AP/PP" (categoriesOf "bigger")
  , testCase "WordNet POS is used only for tokens without corpus POS" $ do
      let config = enabledConfig
            { posMapping = posMappingFromTable (Map.singleton "NOUN" [CandidateTemplateConfig "N" 0])
            }
          inventory = Map.fromList [("dog", ["NOUN"]), ("cat", ["NOUN"])]
          corpus = [sentenceWith ["Dogs", "cat"] ["dog", "cat"] ["", "VERB"]]
      withCandidates config inventory corpus $ \atoms store candidates -> do
        render atoms store (candidateCategoriesForWord "Dogs" candidates) @?= ["N"]
        map candidateSource (candidateCategoriesForWord "Dogs" candidates) @?= [FromWordNetPos]
        candidateCategoriesForWord "cat" candidates @?= []
      let disabled = config { candidateConstraints = (candidateConstraints config) { useWordNetInventory = False } }
      withCandidates disabled inventory corpus $ \_ _ candidates ->
        candidateCategoriesForWord "Dogs" candidates @?= []
  , testCase "built candidate lexicons round-trip through JSON" $ do
      config <- requireDefaultConfig
      withCandidates config emptyWordNetInventory
        [sentenceWith ["John", "likes", "the", "dog", "."] [] ["NNP", "VBZ", "DT", "NN", "."]] $ \atoms store candidates ->
          case encodeCandidateLexicon atoms store candidates of
            Left message -> assertFailure (Text.unpack message)
            Right bytes -> do
              configuredAtoms <- either (assertFailure . Text.unpack) pure
                (configuredAtomTable config (grammarAtoms emptyGrammar))
              case decodeCandidateLexicon (categories config) True (maxCandidatesPerWord (candidateConstraints config))
                "<encoded>" configuredAtoms (grammarCategories emptyGrammar) bytes of
                Left message -> assertFailure (Text.unpack message)
                Right (atoms', store', decoded) ->
                  renderLexicon atoms' store' decoded @?= renderLexicon atoms store candidates
  , testCase "legacy initialization takes the lowest-prior configured category" $ do
      let mapping = posMappingFromTable (Map.singleton "VBZ"
            [CandidateTemplateConfig "(S\\NP)/NP" 1, CandidateTemplateConfig "S\\NP" 0])
          grammar = initializeSentenceWords mapping (sentenceWith ["John", "runs"] [] ["NNP", "VBZ"]) emptyGrammar
          rendered word = map (either id id . prettyCategory (grammarAtoms grammar) (grammarCategories grammar))
            (categoriesForWord word (grammarLexicon grammar))
      rendered "runs" @?= ["S\\NP"]
      rendered "John" @?= ["NP"]
  ]

enabledConfig :: Config
enabledConfig = defaultConfig
  { candidateConstraints = (candidateConstraints defaultConfig) { candidateConstraintsEnabled = True }
  }

decodeConfig :: ByteString -> Either String Config
decodeConfig = either (Left . show) Right . decodeEither'

assertDecodeFailure :: Text -> ByteString -> Assertion
assertDecodeFailure expected yaml = case decodeConfig yaml of
  Left message -> assertBool ("unexpected diagnostic: " <> message) (expected `Text.isInfixOf` Text.pack message)
  Right _ -> assertFailure "invalid pos_mapping was accepted"

requireDefaultConfig :: IO Config
requireDefaultConfig = loadConfig "configs/default.yaml" >>= either (\message -> assertFailure message >> pure defaultConfig) pure

withCandidates
  :: Config -> WordNetInventory -> [Sentence]
  -> (AtomTable -> CategoryStore -> CandidateLexicon -> Assertion) -> Assertion
withCandidates config inventory corpus check =
  case buildCandidateLexiconFromConfig config inventory corpus (grammarAtoms emptyGrammar) (grammarCategories emptyGrammar) of
    Left message -> assertFailure (Text.unpack message)
    Right (atoms, store, candidates) -> check atoms store candidates

sentenceWith :: [Text] -> [Text] -> [Text] -> Sentence
sentenceWith words' lemmas' pos =
  Sentence "s" words' (if null lemmas' then words' else lemmas') pos [] Map.empty

render :: AtomTable -> CategoryStore -> [CandidateCategory] -> [Text]
render atoms store = map (either (const "<?>") id . prettyCategory atoms store . candidateCategoryId)

renderLexicon :: AtomTable -> CategoryStore -> CandidateLexicon -> [(Text, [(Text, Int, CandidateSource, Bool)])]
renderLexicon atoms store lexicon =
  [ (word, zip4 (render atoms store candidates) (map candidatePriorCost candidates)
      (map candidateSource candidates) (map candidateLocked candidates))
  | (word, candidates) <- candidateLexiconEntries lexicon
  ]
  where
    zip4 (a : as) (b : bs) (c : cs) (d : ds) = (a, b, c, d) : zip4 as bs cs ds
    zip4 _ _ _ _ = []

assertElem :: Text -> [Text] -> Assertion
assertElem expected actual =
  assertBool (Text.unpack expected <> " not in " <> show actual) (expected `elem` actual)
