{-# LANGUAGE OverloadedStrings #-}

module CLI (mainCLI) where

import qualified CCG.Category
import qualified CCG.CategoryStore
import Corpus.Jsonl (readJsonl)
import Corpus.Types (Sentence (..))
import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy as Lazy
import Data.Foldable (traverse_)
import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.List (find)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Evaluation.Coverage
  ( CoverageResult (..)
  , SentenceCoverage (..)
  , sentenceCoverageDetailsWithJobs
  )
import Evaluation.Export (writeCoverageResult)
import GHC.Conc (setNumCapabilities)
import Grammar.Induction
import Grammar.Types (CategoryProvenance (..), Grammar (..), grammarRules)
import Lexicon.CandidateLexicon
import Lexicon.Initialization (emptyGrammar)
import Lexicon.Types (categoriesForWord, lexiconEntries)
import Options.Applicative
import Parser.Config
import Parser.Incremental
import Parser.FailureFrontier (farthestPosition)
import Serialization.CandidateLexicon (saveCandidateLexicon)
import Serialization.Derivation (derivationSummary)
import Serialization.Grammar (loadGrammar, saveGrammar)
import Serialization.Lexicon (saveLexicon)
import System.Directory (copyFile, createDirectoryIfMissing, doesFileExist)
import System.Exit (die)
import System.FilePath (takeDirectory, (</>))
import System.IO (hFlush, hPutStr, hPutStrLn, stderr)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)

data Command
  = Train FilePath FilePath (Maybe FilePath) FilePath Int Bool
  | Evaluate FilePath FilePath (Maybe FilePath) FilePath Int
  | Parse FilePath (Maybe FilePath) Text
  | InspectLexicon FilePath Text
  | InspectCandidates FilePath (Maybe FilePath) Text
  | BuildCandidates FilePath FilePath (Maybe FilePath) FilePath

mainCLI :: IO ()
mainCLI = execParser options >>= runCommand
  where options = info (commandParser <**> helper) (fullDesc <> progDesc "Bounded CCG lexical category induction")

commandParser :: Parser Command
commandParser = hsubparser
  ( command "train" (info trainParser (progDesc "Induce a grammar"))
 <> command "evaluate" (info evaluateParser (progDesc "Evaluate a frozen grammar"))
 <> command "parse" (info parseParser (progDesc "Parse a tokenized sentence"))
 <> command "inspect-lexicon" (info inspectParser (progDesc "Inspect categories for a word"))
 <> command "inspect-candidates" (info inspectCandidatesParser (progDesc "Inspect prior candidates for a word"))
 <> command "build-candidates" (info buildCandidatesParser (progDesc "Build a candidate lexicon JSON from corpus POS, the configured POS mapping, WordNet, and seeds"))
  )
  where
    file name helpText = strOption (long name <> metavar "FILE" <> help helpText)
    jobsParser = option auto (long "jobs" <> short 'j' <> metavar "N" <> value 1 <> showDefault <> help "Parallel worker capabilities")
    trainParser = Train <$> file "corpus" "Input JSONL" <*> file "config" "YAML configuration"
      <*> optional (file "candidate-lexicon" "Candidate lexicon JSON")
      <*> strOption (long "output" <> metavar "DIR") <*> jobsParser
      <*> switch (long "no-progress" <> help "Disable the training progress display")
    ruleConfigParser = optional (file "config"
      "YAML configuration for parser rules and bounds (default: config.snapshot.yaml next to the grammar, else built-in defaults)")
    evaluateParser = Evaluate <$> file "corpus" "Input JSONL" <*> file "grammar" "Grammar JSON" <*> ruleConfigParser
      <*> strOption (long "output" <> metavar "DIR") <*> jobsParser
    parseParser = Parse <$> file "grammar" "Grammar JSON" <*> ruleConfigParser
      <*> option (Text.pack <$> str) (long "sentence" <> metavar "TEXT")
    inspectParser = InspectLexicon <$> file "grammar" "Grammar JSON" <*> option (Text.pack <$> str) (long "word" <> metavar "WORD")
    inspectCandidatesParser = InspectCandidates <$> file "candidate-lexicon" "Candidate lexicon JSON"
      <*> optional (file "config" "YAML configuration for atoms and category bounds (default: built-in defaults)")
      <*> option (Text.pack <$> str) (long "word" <> metavar "WORD")
    buildCandidatesParser = BuildCandidates <$> file "corpus" "Input JSONL" <*> file "config" "YAML configuration"
      <*> optional (file "wordnet" "WordNet lemma/POS inventory JSON (overrides candidate_constraints.wordnet_inventory_path)")
      <*> strOption (long "output" <> metavar "FILE")

runCommand :: Command -> IO ()
runCommand selectedCommand = case selectedCommand of
  Train corpusPath configPath commandCandidatePath output requestedJobs noProgress -> do
    jobs <- configureJobs requestedJobs
    config <- requireConfig configPath
    corpus <- requireCorpus corpusPath
    let selectedCandidatePath = commandCandidatePath <|> candidateLexiconPath (candidateConstraints config)
        config' = case selectedCandidatePath of
          Just _ -> config { candidateConstraints = (candidateConstraints config) { candidateConstraintsEnabled = True } }
          Nothing -> config
    (candidateGrammar, candidates) <- prepareCandidateLayer config' corpus selectedCandidatePath
    result <- if noProgress
      then pure (trainCorpusWithCandidateLexicon jobs config' candidates candidateGrammar corpus)
      else runTrainingWithProgress jobs config' candidates candidateGrammar corpus
    createDirectoryIfMissing True (output </> "derivations")
    saveGrammar (output </> "grammar.json") (trainedGrammar result)
    saveLexicon (output </> "lexicon.json") (trainedGrammar result)
    writeLearnedCategorySources (output </> "learned_category_sources.jsonl") (trainedGrammar result) candidates
    writeCandidateStats (output </> "candidate_metrics.json") result
    writeMetrics (output </> "training_metrics.jsonl") (trainingMetrics result)
    writeSentences (output </> "unresolved.jsonl") (unresolvedSentences result)
    copyFile configPath (output </> "config.snapshot.yaml")
    traverse_ (\path -> copyFile path (output </> "candidate_lexicon.snapshot.json")) selectedCandidatePath
    Text.putStrLn ("trained sentences=" <> Text.pack (show (length corpus)) <> " unresolved=" <> Text.pack (show (length (unresolvedSentences result))))
  Evaluate corpusPath grammarPath commandConfigPath output requestedJobs -> do
    jobs <- configureJobs requestedJobs
    config <- requireRuleConfig grammarPath commandConfigPath
    corpus <- requireCorpus corpusPath
    grammar <- requireGrammar grammarPath
    let coverage = sentenceCoverageDetailsWithJobs jobs config grammar corpus
        covered = length (filter coverageCovered coverage)
        total = length coverage
        rate = if total == 0 then 0 else fromIntegral covered / fromIntegral total
    createDirectoryIfMissing True output
    writeCoverageResult (output </> "evaluation.json") (CoverageResult total covered rate)
    writeSentenceResults (output </> "sentence_results.jsonl") grammar coverage
    writeFile (output </> "category_inventory.csv") "word,category\n"
    writeFile (output </> "ambiguity.csv") "sentence_id,parse_count\n"
    traverse_ (Text.putStrLn . renderCoverageLine grammar) coverage
    Text.putStrLn
      ("coverage=" <> Text.pack (show covered) <> "/" <> Text.pack (show total)
        <> " (" <> Text.pack (showFFloat1 (rate * 100)) <> "%)")
  Parse grammarPath commandConfigPath sentence -> do
    config <- requireRuleConfig grammarPath commandConfigPath
    grammar <- requireGrammar grammarPath
    let sentenceTokens = Text.words sentence
    case parseSentence config (grammarCategories grammar) (grammarLexicon grammar) (grammarRules grammar) (rootCategory grammar) sentenceTokens of
      Parsed success -> Lazy.putStr (encode (derivationSummary (grammarAtoms grammar) success) <> "\n")
      Failed failure -> do
        let diagnosticSentence = Sentence "<command-line>" sentenceTokens sentenceTokens [] [] Map.empty []
            diagnostic = case sentenceCoverageDetailsWithJobs 1 config grammar [diagnosticSentence] of
              result : _ -> renderCoverageLine grammar result
              [] -> "parse failed at token position " <> Text.pack (show (farthestPosition failure))
        die (Text.unpack diagnostic)
  InspectLexicon grammarPath word -> do
    grammar <- requireGrammar grammarPath
    let categoryIds = categoriesForWord word (grammarLexicon grammar)
    traverse_ (printCategory grammar) categoryIds
  InspectCandidates candidatePath commandConfigPath word -> do
    config <- maybe (pure defaultConfig) requireConfig commandConfigPath
    (grammar, candidates) <- loadCandidates config candidatePath
    Text.putStrLn word
    traverse_ (printCandidate grammar) (candidateCategoriesForWord word candidates)

  BuildCandidates corpusPath configPath commandWordNetPath output -> do
    config <- requireConfig configPath
    corpus <- requireCorpus corpusPath
    inventory <- requireWordNetInventory config commandWordNetPath
    configuredAtoms <- either (die . Text.unpack) pure
      (configuredAtomTable config (grammarAtoms emptyGrammar))
    (atoms, store, candidates) <- either (die . Text.unpack) pure
      (buildCandidateLexiconFromConfig config inventory corpus configuredAtoms (grammarCategories emptyGrammar))
    saveCandidateLexicon output atoms store candidates >>= either (die . Text.unpack) pure
    Text.putStrLn ("wrote " <> Text.pack (show (candidateWordCount (candidateLexiconStats candidates)))
      <> " candidate entries to " <> Text.pack output)

-- | Rule configuration for commands that parse with a frozen grammar.  Parsing
-- must use the rules and bounds the grammar was trained with, so without an
-- explicit @--config@ the training snapshot next to the grammar is preferred.
-- The choice is reported on stderr.
requireRuleConfig :: FilePath -> Maybe FilePath -> IO Config
requireRuleConfig grammarPath commandConfigPath = case commandConfigPath of
  Just path -> announce path >> requireConfig path
  Nothing -> do
    let snapshot = takeDirectory grammarPath </> "config.snapshot.yaml"
    hasSnapshot <- doesFileExist snapshot
    if hasSnapshot
      then announce snapshot >> requireConfig snapshot
      else hPutStrLn stderr "using built-in default parser rules (no --config, no config.snapshot.yaml)" >> pure defaultConfig
  where
    announce path = hPutStrLn stderr ("using parser rules from " <> path)

requireConfig :: FilePath -> IO Config
requireConfig path = loadConfig path >>= either die pure

-- | The inventory is read only when WordNet fallback is enabled; a command-line
-- path takes precedence over the configured one.
requireWordNetInventory :: Config -> Maybe FilePath -> IO WordNetInventory
requireWordNetInventory config commandPath
  | not (useWordNetInventory (candidateConstraints config)) = pure emptyWordNetInventory
  | otherwise = case commandPath <|> wordNetInventoryPath (candidateConstraints config) of
      Nothing -> pure emptyWordNetInventory
      Just path -> loadWordNetInventory path >>= either (die . Text.unpack) pure

requireCorpus :: FilePath -> IO [Sentence]
requireCorpus path = readJsonl path >>= either (die . Text.unpack) pure

requireGrammar :: FilePath -> IO Grammar
requireGrammar path = loadGrammar path >>= either (die . Text.unpack) pure

prepareCandidateLayer :: Config -> [Sentence] -> Maybe FilePath -> IO (Grammar, CandidateLexicon)
prepareCandidateLayer config corpus selectedPath = do
  configuredAtoms <- either (die . Text.unpack) pure
    (configuredAtomTable config (grammarAtoms emptyGrammar))
  let configuredGrammar = emptyGrammar { grammarAtoms = configuredAtoms }
  if not (candidateConstraintsEnabled (candidateConstraints config))
    then pure (configuredGrammar, emptyCandidateLexicon)
    else case selectedPath of
      Just path -> loadCandidates config path
      Nothing -> do
        inventory <- requireWordNetInventory config Nothing
        case buildCandidateLexiconFromConfig config inventory corpus configuredAtoms (grammarCategories configuredGrammar) of
          Left message -> die (Text.unpack message)
          Right (atoms, store, candidates) -> pure
            (configuredGrammar { grammarAtoms = atoms, grammarCategories = store }, candidates)

loadCandidates :: Config -> FilePath -> IO (Grammar, CandidateLexicon)
loadCandidates config path = do
  configuredAtoms <- either (die . Text.unpack) pure
    (configuredAtomTable config (grammarAtoms emptyGrammar))
  loaded <- loadCandidateLexicon
    (categories config)
    (rejectCandidatesOutsideCategoryBounds (candidateConstraints config))
    (maxCandidatesPerWord (candidateConstraints config))
    path
    configuredAtoms
    (grammarCategories emptyGrammar)
  case loaded of
    Left message -> die (Text.unpack message)
    Right (atoms, store, candidates) -> pure
      (emptyGrammar { grammarAtoms = atoms, grammarCategories = store }, candidates)

configureJobs :: Int -> IO Int
configureJobs requested
  | requested < 1 = die "--jobs must be at least 1"
  | otherwise = setNumCapabilities requested >> pure requested

data ProgressState = ProgressState
  { progressStartedAt :: !UTCTime
  , progressCovered :: !(IORef Int)
  }

runTrainingWithProgress :: Int -> Config -> CandidateLexicon -> Grammar -> [Sentence] -> IO TrainingResult
runTrainingWithProgress jobs config candidates grammar corpus = do
  started <- getCurrentTime
  coveredRef <- newIORef 0
  let state = ProgressState started coveredRef
  if null corpus
    then hPutStrLn stderr "training 0/0 (100.0%)"
    else pure ()
  result <- trainCorpusWithCandidateProgress jobs (renderProgress state) config candidates grammar corpus
  if null corpus then pure () else hPutStrLn stderr ""
  pure result

renderProgress :: ProgressState -> Int -> Int -> TrainingMetric -> IO ()
renderProgress state completed total metric = do
  if metricCovered metric
    then modifyIORef' (progressCovered state) (+ 1)
    else hPutStrLn stderr
      ("\nunresolved sentence=" <> Text.unpack (metricSentenceId metric)
        <> " categorized_tokens=" <> renderMetricRatio
          (metricCategorizedTokenCount metric) (metricSentenceLength metric)
          (metricCategorizedTokenRate metric)
        <> " categorized_word_types=" <> renderMetricRatio
          (metricCategorizedWordTypeCount metric) (metricWordTypeCount metric)
          (metricCategorizedWordTypeRate metric)
        <> " category_assignments=" <> show (metricCategoryAssignmentCount metric)
        <> maybe "" ((" farthest_position=" <>) . show) (metricFarthestPosition metric)
        <> if null (metricUncategorizedWords metric)
          then ""
          else " uncategorized_words=["
            <> Text.unpack (Text.intercalate ", " (metricUncategorizedWords metric)) <> "]")
  covered <- readIORef (progressCovered state)
  now <- getCurrentTime
  let unresolved = completed - covered
      fraction = if total == 0 then 1 else fromIntegral completed / fromIntegral total :: Double
      barWidth = 30
      filled = min barWidth (floor (fraction * fromIntegral barWidth))
      bar = replicate filled '#' <> replicate (barWidth - filled) '-'
      elapsed = max 0.001 (realToFrac (diffUTCTime now (progressStartedAt state)) :: Double)
      rate = fromIntegral completed / elapsed
      percent = fraction * 100
      line = "\rtraining [" <> bar <> "] "
        <> show completed <> "/" <> show total
        <> " (" <> showFFloat1 percent <> "%)"
        <> " covered=" <> show covered
        <> " unresolved=" <> show unresolved
        <> " " <> showFFloat1 rate <> " sent/s"
  hPutStr stderr line
  hFlush stderr

renderMetricRatio :: Int -> Int -> Double -> String
renderMetricRatio count total rate =
  show count <> "/" <> show total <> " (" <> showFFloat1 (rate * 100) <> "%)"

showFFloat1 :: Double -> String
showFFloat1 number =
  let scaled = round (number * 10) :: Int
   in show (scaled `div` 10) <> "." <> show (abs (scaled `mod` 10))

printCategory :: Grammar -> CCG.Category.CategoryId -> IO ()
printCategory grammar categoryId = either (die . Text.unpack) Text.putStrLn
  (CCG.CategoryStore.prettyCategory (grammarAtoms grammar) (grammarCategories grammar) categoryId)

printCandidate :: Grammar -> CandidateCategory -> IO ()
printCandidate grammar candidate = case CCG.CategoryStore.prettyCategory
    (grammarAtoms grammar) (grammarCategories grammar) (candidateCategoryId candidate) of
  Left message -> die (Text.unpack message)
  Right category -> Text.putStrLn
    ("  " <> category <> "  prior=" <> Text.pack (show (candidatePriorCost candidate))
      <> " source=" <> Text.pack (show (candidateSource candidate))
      <> if candidateLocked candidate then " locked=true" else "")

writeMetrics :: FilePath -> [TrainingMetric] -> IO ()
writeMetrics path metrics = Lazy.writeFile path (mconcat (map ((<> "\n") . encode . metricValue) metrics))
  where
    metricValue metric = object
      [ "sentence_id" .= metricSentenceId metric, "covered" .= metricCovered metric
      , "sentence_length" .= metricSentenceLength metric
      , "level" .= fmap show (metricLevel metric), "repairs" .= metricRepairs metric
      , "parse_count" .= metricParseCount metric
      , "application_uses" .= metricApplicationUses metric
      , "composition_uses" .= metricCompositionUses metric
      , "type_raising_uses" .= metricTypeRaisingUses metric
      , "repair_candidates_from_candidate_lexicon" .= metricRepairCandidatesFromCandidateLexicon metric
      , "repair_candidates_from_unknown_fallback" .= metricRepairCandidatesFromUnknownFallback metric
      , "repair_candidates_filtered_by_pos" .= metricRepairCandidatesFilteredByPos metric
      , "repair_candidates_filtered_by_wordnet" .= metricRepairCandidatesFilteredByWordNet metric
      , "repair_candidates_validated" .= metricRepairCandidatesValidated metric
      , "repair_candidates_accepted" .= metricRepairCandidatesAccepted metric
      , "categorized_token_count" .= metricCategorizedTokenCount metric
      , "categorized_token_rate" .= metricCategorizedTokenRate metric
      , "word_type_count" .= metricWordTypeCount metric
      , "categorized_word_type_count" .= metricCategorizedWordTypeCount metric
      , "categorized_word_type_rate" .= metricCategorizedWordTypeRate metric
      , "category_assignment_count" .= metricCategoryAssignmentCount metric
      , "uncategorized_words" .= metricUncategorizedWords metric
      , "farthest_position" .= metricFarthestPosition metric
      ]

writeCandidateStats :: FilePath -> TrainingResult -> IO ()
writeCandidateStats path result = Lazy.writeFile path (encode (object
  [ "candidate_word_count" .= candidateWordCount stats
  , "candidate_category_count" .= candidateCategoryCount stats
  , "candidate_categories_per_word_mean" .= candidateCategoriesPerWordMean stats
  , "candidate_categories_per_word_median" .= candidateCategoriesPerWordMedian stats
  , "candidate_categories_per_word_max" .= candidateCategoriesPerWordMax stats
  , "learned_categories_by_source" .= learnedBySource
  , "unknown_fallback_acceptance_rate" .= fallbackRate
  ]))
  where
    stats = trainingCandidateStats result
    learnedBySource = Map.fromListWith (+)
      [ (Text.pack (show (provenanceSource provenance)), 1 :: Int)
      | provenance <- Map.elems (grammarProvenance (trainedGrammar result))
      ]
    fallbackGenerated = sum (map metricRepairCandidatesFromUnknownFallback (trainingMetrics result))
    fallbackAccepted = sum
      [ metricRepairCandidatesAccepted metric
      | metric <- trainingMetrics result
      , metricRepairCandidatesFromUnknownFallback metric > 0
      ]
    fallbackRate = if fallbackGenerated == 0 then 0 else
      fromIntegral fallbackAccepted / fromIntegral fallbackGenerated :: Double

writeLearnedCategorySources :: FilePath -> Grammar -> CandidateLexicon -> IO ()
writeLearnedCategorySources path grammar candidates = Lazy.writeFile path (mconcat
  [ encode (sourceValue word categoryId) <> "\n"
  | (word, categoryIds) <- lexiconEntries (grammarLexicon grammar)
  , categoryId <- categoryIds
  ])
  where
    sourceValue word categoryId =
      let matched = find ((== categoryId) . candidateCategoryId) (candidateCategoriesForWord word candidates)
          provenance = Map.lookup (word, categoryId) (grammarProvenance grammar)
          categoryText = either (const "<?>" ) id
            (CCG.CategoryStore.prettyCategory (grammarAtoms grammar) (grammarCategories grammar) categoryId)
       in object
          [ "word" .= word
          , "category" .= categoryText
          , "source" .= maybe (maybe FromUnknownFallback candidateSource matched) provenanceSource provenance
          , "prior_cost" .= maybe (maybe (100 :: Int) candidatePriorCost matched) provenancePriorCost provenance
          , "accepted_at_sentence" .= (provenance >>= provenanceAcceptedAtSentence)
          , "repair_reason" .= maybe ("LegacyInitialization" :: Text) provenanceRepairReason provenance
          ]

writeSentences :: FilePath -> [Sentence] -> IO ()
writeSentences path sentences = Lazy.writeFile path (mconcat [encode sentence <> "\n" | sentence <- sentences])

writeSentenceResults :: FilePath -> Grammar -> [SentenceCoverage] -> IO ()
writeSentenceResults path grammar coverage = Lazy.writeFile path (mconcat (map resultLine coverage))
  where
    resultLine result =
      encode (object
        [ "sentence_id" .= coverageSentenceId result
        , "covered" .= coverageCovered result
        , "token_count" .= coverageTokenCount result
        , "categorized_token_count" .= coverageCategorizedTokenCount result
        , "categorized_token_rate" .= coverageCategorizedTokenRate result
        , "word_type_count" .= coverageWordTypeCount result
        , "categorized_word_type_count" .= coverageCategorizedWordTypeCount result
        , "categorized_word_type_rate" .= coverageCategorizedWordTypeRate result
        , "category_assignment_count" .= coverageCategoryAssignmentCount result
        , "uncategorized_words" .= coverageUncategorizedWords result
        , "farthest_position" .= coverageFarthestPosition result
        , "frontier_stacks" .= map (map (prettyCategoryOrId grammar)) (coverageFrontierStacks result)
        , "successful_level" .= fmap show (coverageSuccessfulLevel result)
        ]) <> "\n"

renderCoverageLine :: Grammar -> SentenceCoverage -> Text
renderCoverageLine grammar result =
  "sentence=" <> coverageSentenceId result
    <> " covered=" <> boolText (coverageCovered result)
    <> " categorized_tokens=" <> countRatio
      (coverageCategorizedTokenCount result) (coverageTokenCount result)
      (coverageCategorizedTokenRate result)
    <> " categorized_word_types=" <> countRatio
      (coverageCategorizedWordTypeCount result) (coverageWordTypeCount result)
      (coverageCategorizedWordTypeRate result)
    <> " category_assignments=" <> Text.pack (show (coverageCategoryAssignmentCount result))
    <> maybe "" (\position -> " farthest_position=" <> Text.pack (show position))
      (coverageFarthestPosition result)
    <> if null (coverageUncategorizedWords result)
      then ""
      else " uncategorized_words=[" <> Text.intercalate ", " (coverageUncategorizedWords result) <> "]"
    <> if null (coverageFrontierStacks result)
      then ""
      else " frontier_stacks=" <> renderStacks grammar (coverageFrontierStacks result)
  where
    boolText True = "true"
    boolText False = "false"
    countRatio count total rate =
      Text.pack (show count) <> "/" <> Text.pack (show total)
        <> " (" <> Text.pack (showFFloat1 (rate * 100)) <> "%)"

renderStacks :: Grammar -> [[CCG.Category.CategoryId]] -> Text
renderStacks grammar stacks =
  "[" <> Text.intercalate ", "
    ["[" <> Text.intercalate ", " (map (prettyCategoryOrId grammar) stack) <> "]" | stack <- stacks]
    <> "]"

prettyCategoryOrId :: Grammar -> CCG.Category.CategoryId -> Text
prettyCategoryOrId grammar categoryId =
  either (const (Text.pack (show categoryId))) id
    (CCG.CategoryStore.prettyCategory
      (grammarAtoms grammar) (grammarCategories grammar) categoryId)
