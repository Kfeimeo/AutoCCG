{-# LANGUAGE OverloadedStrings #-}

module CandidateLexiconSpec (tests) where

import CCG.CategoryStore (prettyCategory)
import CCG.Atom (AtomTable, lookupAtom)
import CCG.CategoryStore (CategoryStore)
import Corpus.Types (Sentence (..))
import qualified Data.Map.Strict as Map
import Grammar.Types (CategoryProvenance (..), Grammar (..))
import Lexicon.CandidateLexicon
import Lexicon.Initialization (emptyGrammar, initializeLearnedLexicon, internNamedCategory)
import Lexicon.Repair (RepairBatch (..), RepairOperation (..), RepairProposal (..), RepairStats (..), repairSentenceWithCandidates, successfulRepairProposals)
import Lexicon.Types (categoriesForWord, insertEntry)
import Parser.Config
import Parser.Incremental (ParseOutcome (..), parseSentence)
import Data.Text (Text)
import qualified Data.Text as Text
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "candidate lexicon"
  [ testCase "POS templates produce bounded candidates" $ do
      let config = enabledConfig
            { posToCategories = Map.fromList
                [ ("PROPN", [CandidateTemplateConfig "NP" 0])
                , ("VERB", [CandidateTemplateConfig "S\\NP" 1, CandidateTemplateConfig "(S\\NP)/NP" 0])
                ]
            }
          corpus = [sentence ["John", "likes"] ["PROPN", "VERB"]]
      case buildCandidateLexiconFromConfig config corpus (grammarAtoms emptyGrammar) (grammarCategories emptyGrammar) of
        Left message -> assertFailure (show message)
        Right (atoms, store, candidates) -> do
          render atoms store (candidateCategoriesForWord "John" candidates) @?= ["NP"]
          render atoms store (candidateCategoriesForWord "likes" candidates) @?= ["(S\\NP)/NP", "S\\NP"]
  , testCase "locked seeds activate while unlocked seeds remain candidates" $ do
      let config = enabledConfig
            { seedLexicon = Map.fromList
                [ ("the", [SeedEntryConfig "NP/N" 0 True])
                , ("of", [SeedEntryConfig "PP/NP" 0 False])
                ]
            }
      case buildCandidateLexiconFromConfig config [] (grammarAtoms emptyGrammar) (grammarCategories emptyGrammar) of
        Left message -> assertFailure (show message)
        Right (atoms, store, candidates) -> do
          let grammar = initializeLearnedLexicon (initialization config) candidates
                emptyGrammar { grammarAtoms = atoms, grammarCategories = store }
          assertBool "locked seed missing" (not (null (categoriesForWord "the" (grammarLexicon grammar))))
          categoriesForWord "of" (grammarLexicon grammar) @?= []
  , testCase "parser cannot see inactive candidates until repair" $ do
      let config = enabledConfig
            { posToCategories = Map.singleton "VERB" [CandidateTemplateConfig "S\\NP" 0]
            , initialization = InitializationConfig True False False 0
            }
          corpusSentence = sentence ["John", "runs"] ["PROPN", "VERB"]
      case buildCandidateLexiconFromConfig config [corpusSentence] (grammarAtoms emptyGrammar) (grammarCategories emptyGrammar) of
        Left message -> assertFailure (show message)
        Right (atoms, store, candidates) -> case internNamedCategory "NP" (emptyGrammar { grammarAtoms = atoms, grammarCategories = store }) of
          Left message -> assertFailure (show message)
          Right (np, grammar0) -> do
            let grammar = grammar0 { grammarLexicon = insertEntry "John" np (grammarLexicon grammar0) }
                parse current = parseSentence config (grammarCategories current) (grammarLexicon current)
                  (raisingTemplates current) (rootCategory current) ["John", "runs"]
            case parse grammar of
              Failed _ -> pure ()
              Parsed _ -> assertFailure "parser used an inactive candidate"
            case successfulRepairProposals (repairSentenceWithCandidates 1 config candidates corpusSentence grammar) of
              proposal : _ -> do
                case parse (proposalGrammar proposal) of
                  Parsed _ -> pure ()
                  Failed failure -> assertFailure (show failure)
                case proposalOperation proposal of
                  AddCategory word categoryId -> case Map.lookup (word, categoryId) (grammarProvenance (proposalGrammar proposal)) of
                    Just provenance -> provenanceAcceptedAtSentence provenance @?= Just "s"
                    Nothing -> assertFailure "accepted repair provenance missing"
                  _ -> assertFailure "unexpected non-add repair"
              [] -> assertFailure "candidate-backed repair did not succeed"
  , testCase "candidate loader rejects categories outside configured bounds" $ do
      loaded <- loadCandidateLexicon (CategoryBounds 5 4 2) True 8
        "test/fixtures/out-of-bounds-candidates.json"
        (grammarAtoms emptyGrammar) (grammarCategories emptyGrammar)
      case loaded of
        Left message -> assertBool "missing bounds diagnostic" ("exceeds configured bounds" `Text.isInfixOf` message)
        Right _ -> assertFailure "out-of-bounds candidate was accepted"
  , testCase "repair prefers lower candidate prior when both categories parse" $ do
      let config = enabledConfig
            { posToCategories = Map.singleton "X"
                [CandidateTemplateConfig "N" 0, CandidateTemplateConfig "NP" 5]
            , initialization = InitializationConfig True False False 0
            }
          corpusSentence = sentence ["f", "w"] ["", "X"]
      case buildCandidateLexiconFromConfig config [corpusSentence] (grammarAtoms emptyGrammar) (grammarCategories emptyGrammar) of
        Left message -> assertFailure (show message)
        Right (atoms, store, candidates) -> do
          grammar <- addLearned [(("f", "S/NP")), (("f", "S/N"))]
            (emptyGrammar { grammarAtoms = atoms, grammarCategories = store })
          let batch = repairSentenceWithCandidates 1 config candidates corpusSentence grammar
          case successfulRepairProposals batch of
            proposal : _ -> case proposalOperation proposal of
              AddCategory "w" categoryId -> do
                let lowPriorIds = [candidateCategoryId candidate | candidate <- candidateCategoriesForWord "w" candidates, candidatePriorCost candidate == 0]
                assertBool "higher-prior repair sorted first" (categoryId `elem` lowPriorIds)
              operation -> assertFailure ("unexpected repair: " <> show operation)
            [] -> assertFailure "no candidate repair succeeded"
  , testCase "unknown fallback stays within configured small set" $ do
      let config = enabledConfig
            { initialization = InitializationConfig True False False 0
            , repair = RepairConfig True 100 10 True 5
            }
          batch = repairSentenceWithCandidates 1 config emptyCandidateLexicon
            (sentence ["mystery"] [""]) emptyGrammar
      repairCandidatesFromUnknownFallback (repairBatchStats batch) @?= 5
  , testCase "configured atoms are available to POS templates" $ do
      let config = enabledConfig
            { atoms = AtomConfig ["S", "NP", "N", "PP", "AP"] 5
            , posToCategories = Map.singleton "ADJ" [CandidateTemplateConfig "AP" 0]
            }
      case buildCandidateLexiconFromConfig config [sentence ["happy"] ["ADJ"]]
        (grammarAtoms emptyGrammar) (grammarCategories emptyGrammar) of
        Left message -> assertFailure (show message)
        Right (atomTable, _, _) ->
          assertBool "configured AP atom missing" (lookupAtom "AP" atomTable /= Nothing)
  , testCase "POS templates reject undeclared atoms" $ do
      let config = enabledConfig
            { atoms = AtomConfig ["S", "NP", "N", "PP"] 8
            , posToCategories = Map.singleton "ADJ" [CandidateTemplateConfig "AP" 0]
            }
      case buildCandidateLexiconFromConfig config [sentence ["happy"] ["ADJ"]]
        (grammarAtoms emptyGrammar) (grammarCategories emptyGrammar) of
        Left message ->
          assertBool "missing undeclared-atom diagnostic"
            ("introduces an unconfigured atom" `Text.isInfixOf` message)
        Right _ -> assertFailure "accepted an undeclared AP atom"
  , testCase "configured atom inventory respects max_count" $ do
      let config = enabledConfig
            { atoms = AtomConfig ["S", "NP", "N", "PP", "AP"] 4 }
      case configuredAtomTable config (grammarAtoms emptyGrammar) of
        Left message ->
          assertBool "missing max_count diagnostic" ("exceeds atoms.max_count" `Text.isInfixOf` message)
        Right _ -> assertFailure "accepted too many configured atoms"
  , testCase "default YAML declares every atom used by POS templates" $ do
      loaded <- loadConfig "configs/default.yaml"
      case loaded of
        Left message -> assertFailure message
        Right config -> do
          let tags = Map.keys (posToCategories config)
              corpus = [sentence [tag] [tag] | tag <- tags]
          case buildCandidateLexiconFromConfig config corpus
            (grammarAtoms emptyGrammar) (grammarCategories emptyGrammar) of
            Left message -> assertFailure (show message)
            Right (atomTable, _, _) ->
              assertBool "default YAML did not configure AP" (lookupAtom "AP" atomTable /= Nothing)
  , testCase "default YAML supplies bounded punctuation and numeric candidates" $ do
      loaded <- loadConfig "configs/default.yaml"
      case loaded of
        Left message -> assertFailure message
        Right config ->
          case buildCandidateLexiconFromConfig config
            [sentence ["42", ",", "!", "?"] ["", "PUNCT", "PUNCT", "PUNCT"]]
            (grammarAtoms emptyGrammar) (grammarCategories emptyGrammar) of
            Left message -> assertFailure (show message)
            Right (atomTable, store, candidates) -> do
              render atomTable store (candidateCategoriesForWord "42" candidates) @?= ["N/N", "NP"]
              render atomTable store (candidateCategoriesForWord "," candidates) @?=
                ["S\\S", "(S\\S)/S", "NP\\NP", "N\\N"]
              render atomTable store (candidateCategoriesForWord "!" candidates) @?= ["S\\S"]
              render atomTable store (candidateCategoriesForWord "?" candidates) @?= ["S\\S"]
  , testCase "untruncated YAML raises every operational search capacity" $ do
      loaded <- loadConfig "configs/untruncated.yaml"
      case loaded of
        Left message -> assertFailure message
        Right config -> do
          beamWidth (parser config) @?= 2147483647
          maxStatesPerPosition (parser config) @?= 2147483647
          grammarBeamWidth (grammar config) @?= 2147483647
          maxRepairsPerFailure (grammar config) @?= 2147483647
          maxCandidatesPerWord (candidateConstraints config) @?= 2147483647
          maxCandidatesGenerated (repair config) @?= 2147483647
          maxCandidatesValidated (repair config) @?= 2147483647
  ]

enabledConfig :: Config
enabledConfig = defaultConfig
  { candidateConstraints = (candidateConstraints defaultConfig) { candidateConstraintsEnabled = True }
  , initialization = InitializationConfig True True False 0
  , repair = RepairConfig True 100 10 True 5
  }

sentence :: [Text] -> [Text] -> Sentence
sentence words' pos = Sentence "s" words' words' pos [] Map.empty

render :: AtomTable -> CategoryStore -> [CandidateCategory] -> [Text]
render atoms store = map (either (const "<?>" ) id . prettyCategory atoms store . candidateCategoryId)

addLearned :: [(Text, Text)] -> Grammar -> IO Grammar
addLearned [] grammar = pure grammar
addLearned ((word, categoryText) : rest) grammar = case internNamedCategory categoryText grammar of
  Left message -> assertFailure (show message) >> pure grammar
  Right (categoryId, grammar') -> addLearned rest
    grammar' { grammarLexicon = insertEntry word categoryId (grammarLexicon grammar') }
