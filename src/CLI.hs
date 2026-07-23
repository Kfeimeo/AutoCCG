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
import Evaluation.Coverage (CoverageResult (..), sentenceCoverageWithJobs)
import Evaluation.Export (writeCoverageResult)
import GHC.Conc (setNumCapabilities)
import Grammar.Induction
import Grammar.Types (CategoryProvenance (..), Grammar (..))
import Lexicon.CandidateLexicon
import Lexicon.Initialization (emptyGrammar)
import Lexicon.Types (categoriesForWord, lexiconEntries)
import Options.Applicative
import Parser.Config
import Parser.Incremental
import Parser.FailureFrontier (farthestPosition)
import Serialization.Derivation (derivationSummary)
import Serialization.Grammar (loadGrammar, saveGrammar)
import Serialization.Lexicon (saveLexicon)
import System.Directory (copyFile, createDirectoryIfMissing)
import System.Exit (die)
import System.FilePath ((</>))
import System.IO (hFlush, hPutStr, hPutStrLn, stderr)
import Data.Time.Clock (UTCTime, diffUTCTime, getCurrentTime)

data Command
  = Train FilePath FilePath (Maybe FilePath) FilePath Int Bool
  | Evaluate FilePath FilePath FilePath Int
  | Parse FilePath Text
  | InspectLexicon FilePath Text
  | InspectCandidates FilePath Text

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
  )
  where
    file name helpText = strOption (long name <> metavar "FILE" <> help helpText)
    jobsParser = option auto (long "jobs" <> short 'j' <> metavar "N" <> value 1 <> showDefault <> help "Parallel worker capabilities")
    trainParser = Train <$> file "corpus" "Input JSONL" <*> file "config" "YAML configuration"
      <*> optional (file "candidate-lexicon" "Candidate lexicon JSON")
      <*> strOption (long "output" <> metavar "DIR") <*> jobsParser
      <*> switch (long "no-progress" <> help "Disable the training progress display")
    evaluateParser = Evaluate <$> file "corpus" "Input JSONL" <*> file "grammar" "Grammar JSON" <*> strOption (long "output" <> metavar "DIR") <*> jobsParser
    parseParser = Parse <$> file "grammar" "Grammar JSON" <*> option (Text.pack <$> str) (long "sentence" <> metavar "TEXT")
    inspectParser = InspectLexicon <$> file "grammar" "Grammar JSON" <*> option (Text.pack <$> str) (long "word" <> metavar "WORD")
    inspectCandidatesParser = InspectCandidates <$> file "candidate-lexicon" "Candidate lexicon JSON"
      <*> option (Text.pack <$> str) (long "word" <> metavar "WORD")

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
  Evaluate corpusPath grammarPath output requestedJobs -> do
    jobs <- configureJobs requestedJobs
    corpus <- requireCorpus corpusPath
    grammar <- requireGrammar grammarPath
    let coverage = sentenceCoverageWithJobs jobs defaultConfig grammar corpus
        covered = length (filter id coverage)
        total = length coverage
        rate = if total == 0 then 0 else fromIntegral covered / fromIntegral total
    createDirectoryIfMissing True output
    writeCoverageResult (output </> "evaluation.json") (CoverageResult total covered rate)
    writeSentenceResults (output </> "sentence_results.jsonl") corpus coverage
    writeFile (output </> "category_inventory.csv") "word,category\n"
    writeFile (output </> "ambiguity.csv") "sentence_id,parse_count\n"
  Parse grammarPath sentence -> do
    grammar <- requireGrammar grammarPath
    case parseSentence defaultConfig (grammarCategories grammar) (grammarLexicon grammar) (raisingTemplates grammar) (rootCategory grammar) (Text.words sentence) of
      Parsed success -> Lazy.putStr (encode (derivationSummary success) <> "\n")
      Failed failure -> die ("parse failed at token position " <> show (farthestPosition failure))
  InspectLexicon grammarPath word -> do
    grammar <- requireGrammar grammarPath
    let categoryIds = categoriesForWord word (grammarLexicon grammar)
    traverse_ (printCategory grammar) categoryIds
  InspectCandidates candidatePath word -> do
    (grammar, candidates) <- loadCandidates defaultConfig candidatePath
    Text.putStrLn word
    traverse_ (printCandidate grammar) (candidateCategoriesForWord word candidates)

requireConfig :: FilePath -> IO Config
requireConfig path = loadConfig path >>= either die pure

requireCorpus :: FilePath -> IO [Sentence]
requireCorpus path = readJsonl path >>= either (die . Text.unpack) pure

requireGrammar :: FilePath -> IO Grammar
requireGrammar path = loadGrammar path >>= either (die . Text.unpack) pure

prepareCandidateLayer :: Config -> [Sentence] -> Maybe FilePath -> IO (Grammar, CandidateLexicon)
prepareCandidateLayer config corpus selectedPath
  | not (candidateConstraintsEnabled (candidateConstraints config)) = pure (emptyGrammar, emptyCandidateLexicon)
  | otherwise = case selectedPath of
      Just path -> loadCandidates config path
      Nothing -> case buildCandidateLexiconFromConfig config corpus (grammarAtoms emptyGrammar) (grammarCategories emptyGrammar) of
        Left message -> die (Text.unpack message)
        Right (atoms, store, candidates) -> pure
          (emptyGrammar { grammarAtoms = atoms, grammarCategories = store }, candidates)

loadCandidates :: Config -> FilePath -> IO (Grammar, CandidateLexicon)
loadCandidates config path = do
  loaded <- loadCandidateLexicon
    (categories config)
    (rejectCandidatesOutsideCategoryBounds (candidateConstraints config))
    (maxCandidatesPerWord (candidateConstraints config))
    path
    (grammarAtoms emptyGrammar)
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
    else pure ()
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

writeSentenceResults :: FilePath -> [Sentence] -> [Bool] -> IO ()
writeSentenceResults path sentences coverage = Lazy.writeFile path (mconcat (zipWith resultLine sentences coverage))
  where
    resultLine sentence covered =
      encode (object ["sentence_id" .= sentenceId sentence, "covered" .= covered]) <> "\n"
