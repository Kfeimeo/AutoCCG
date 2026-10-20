module Grammar.Induction
  ( TrainingMetric (..)
  , TrainingResult (..)
  , trainCorpus
  , trainCorpusWithJobs
  , trainCorpusWithProgress
  , trainCorpusWithCandidateLexicon
  , trainCorpusWithCandidateProgress
  ) where

import Control.Parallel.Strategies (parListChunk, rseq, using)
import Control.Monad (foldM)
import Corpus.Types (Sentence (..))
import Data.Functor.Identity (runIdentity)
import qualified Data.Set as Set
import qualified Data.Text
import Grammar.Beam (normalizeBeam)
import Grammar.Cost
import Grammar.Types
import Lexicon.Compression (compressGrammar)
import Lexicon.CandidateLexicon
import Lexicon.Initialization (emptyGrammar, initializeLearnedLexicon, initializeSentenceWords)
import Lexicon.Repair
import Lexicon.Types (categoriesForWord, lexiconSize)
import Parser.Config
import Parser.FailureFrontier (farthestPosition)
import Parser.Incremental
import Parser.State (ParseCost (..), ParseLevel (..))

data TrainingMetric = TrainingMetric
  { metricSentenceId :: !Data.Text.Text
  , metricSentenceLength :: !Int
  , metricCovered :: !Bool
  , metricLevel :: !(Maybe ParseLevel)
  , metricRepairs :: !Int
  , metricParseCount :: !Int
  , metricApplicationUses :: !Int
  , metricCompositionUses :: !Int
  , metricTypeRaisingUses :: !Int
  , metricRepairCandidatesFromCandidateLexicon :: !Int
  , metricRepairCandidatesFromUnknownFallback :: !Int
  , metricRepairCandidatesFilteredByPos :: !Int
  , metricRepairCandidatesFilteredByWordNet :: !Int
  , metricRepairCandidatesValidated :: !Int
  , metricRepairCandidatesAccepted :: !Int
  , metricCategorizedTokenCount :: !Int
  , metricCategorizedTokenRate :: !Double
  , metricWordTypeCount :: !Int
  , metricCategorizedWordTypeCount :: !Int
  , metricCategorizedWordTypeRate :: !Double
  , metricCategoryAssignmentCount :: !Int
  , metricUncategorizedWords :: ![Data.Text.Text]
  , metricFarthestPosition :: !(Maybe Int)
  } deriving (Eq, Show)

data TrainingResult = TrainingResult
  { trainedGrammar :: !Grammar
  , trainingMetrics :: ![TrainingMetric]
  , unresolvedSentences :: ![Sentence]
  , trainingCandidateStats :: !CandidateLexiconStats
  } deriving (Eq, Show)

trainCorpus :: Config -> [Sentence] -> TrainingResult
trainCorpus = trainCorpusWithJobs 1

trainCorpusWithJobs :: Int -> Config -> [Sentence] -> TrainingResult
trainCorpusWithJobs requestedJobs config corpus = case configuredCandidates config corpus emptyGrammar of
  Left _ -> runIdentity (trainCorpusWithObserver requestedJobs (\_ _ _ -> pure ()) config emptyCandidateLexicon emptyGrammar corpus)
  Right (grammar, candidates) ->
    runIdentity (trainCorpusWithObserver requestedJobs (\_ _ _ -> pure ()) config candidates grammar corpus)

trainCorpusWithProgress
  :: Int
  -> (Int -> Int -> TrainingMetric -> IO ())
  -> Config
  -> [Sentence]
  -> IO TrainingResult
trainCorpusWithProgress requestedJobs observe config corpus = case configuredCandidates config corpus emptyGrammar of
  Left _ -> trainCorpusWithObserver requestedJobs observe config emptyCandidateLexicon emptyGrammar corpus
  Right (grammar, candidates) -> trainCorpusWithObserver requestedJobs observe config candidates grammar corpus

trainCorpusWithCandidateLexicon :: Int -> Config -> CandidateLexicon -> Grammar -> [Sentence] -> TrainingResult
trainCorpusWithCandidateLexicon requestedJobs config candidates grammar corpus =
  runIdentity (trainCorpusWithObserver requestedJobs (\_ _ _ -> pure ()) config candidates grammar corpus)

trainCorpusWithCandidateProgress
  :: Int
  -> (Int -> Int -> TrainingMetric -> IO ())
  -> Config
  -> CandidateLexicon
  -> Grammar
  -> [Sentence]
  -> IO TrainingResult
trainCorpusWithCandidateProgress requestedJobs observe config candidates grammar corpus =
  trainCorpusWithObserver requestedJobs observe config candidates grammar corpus

trainCorpusWithObserver
  :: Monad m
  => Int
  -> (Int -> Int -> TrainingMetric -> m ())
  -> Config
  -> CandidateLexicon
  -> Grammar
  -> [Sentence]
  -> m TrainingResult
trainCorpusWithObserver requestedJobs observe config candidates baseGrammar corpus = do
  (GrammarBeam finalBeam, metrics, unresolved, _) <-
    foldM stepAndObserve initialState (zip [1 :: Int ..] corpus)
  let
      winner = case finalBeam of
        [] -> initialCandidate
        candidate : _ -> candidate
      compressed = compressGrammar config (filter (\s -> s `notElem` unresolved) corpus) (candidateGrammar winner)
  pure (TrainingResult compressed (reverse metrics) (reverse unresolved) (candidateLexiconStats candidates))
  where
    initialGrammar
      | candidateConstraintsEnabled (candidateConstraints config) =
          initializeLearnedLexicon (initialization config) candidates baseGrammar
      | otherwise = baseGrammar
    initialCandidate = GrammarCandidate initialGrammar zeroCost 0 (GrammarHistoryRef 0)
    initialState = (GrammarBeam [initialCandidate], [], [], zeroCost)
    total = length corpus

    stepAndObserve state item@(index, _) = do
      let next@(_, metrics, _, _) = step state item
      case metrics of
        metric : _ -> observe index total metric
        [] -> pure ()
      pure next

    step (GrammarBeam beam, metrics, unresolved, previousCost) (index, sentence) =
      let alternativesWithStats = map (advance index sentence) beam
            `using` parListChunk (chunkSize jobs (length beam)) rseq
          expanded = concatMap fst alternativesWithStats
          repairStats = foldl' addRepairStats zeroRepairStats (map snd alternativesWithStats)
          normalized@(GrammarBeam kept) = normalizeBeam (grammarBeamWidth (grammar config)) expanded
          bestCost = case kept of
            candidate : _ -> grammarCost candidate
            [] -> previousCost
          repairDelta = max 0 (lexicalRepairCount bestCost - lexicalRepairCount previousCost)
          bestMetric = metricFor repairDelta repairStats sentence kept
          unresolved' = if anyCandidateCovers sentence kept then unresolved else sentence : unresolved
       in (normalized, bestMetric : metrics, unresolved', bestCost)

    advance index sentence candidate =
      let initialized
            | candidateConstraintsEnabled (candidateConstraints config) = candidateGrammar candidate
            | otherwise = initializeSentenceWords (posMapping config) sentence (candidateGrammar candidate)
       in case parseWith initialized sentence of
            Parsed success -> ([accepted index candidate initialized success 0], zeroRepairStats)
            Failed failure ->
              let batch = repairSentenceAtFailure jobs config candidates failure sentence initialized
                  repairedCandidates =
                    [ accepted index candidate repaired success 1
                    | proposal <- successfulRepairProposals batch
                    , let repaired = proposalGrammar proposal
                    , Parsed success <- [parseWith repaired sentence]
                    ]
               in (repairedCandidates ++ [unresolvedCandidate index candidate initialized], repairBatchStats batch)

    parseWith grammar' sentence = parseSentence config (grammarCategories grammar') (grammarLexicon grammar')
      (grammarRules grammar') (rootCategory grammar') (tokens sentence)

    accepted index old grammar' success repairCount = old
      { candidateGrammar = grammar'
      , grammarCost = addSuccess (grammarCost old) grammar' success repairCount
      , processedSentenceCount = index
      , grammarHistoryRef = GrammarHistoryRef index
      }
    unresolvedCandidate index old grammar' = old
      { candidateGrammar = grammar'
      , grammarCost = (grammarCost old) { unresolvedSentenceCount = unresolvedSentenceCount (grammarCost old) + 1 }
      , processedSentenceCount = index
      , grammarHistoryRef = GrammarHistoryRef index
      }
    addSuccess cost grammar' success repairs = cost
      { lexicalRepairCount = lexicalRepairCount cost + repairs
      , extraCategoryCount = extraCategoryCount cost + repairs
      , typeRaisingCount = typeRaisingCount cost + typeRaisingUses (successfulCost success)
      , compositionCount = compositionCount cost + compositionUses (successfulCost success)
      , ambiguityPenalty = ambiguityPenalty cost + max 0 (parseCount success - 1)
      , lexiconSizeCost = lexiconSize (grammarLexicon grammar')
      , derivationStepCount = derivationStepCount cost + derivationSteps (successfulCost success)
      }
    anyCandidateCovers sentence = any (\candidate -> case parseWith (candidateGrammar candidate) sentence of Parsed _ -> True; Failed _ -> False)
    metricFor repairs stats sentence [] =
      emptyMetric stats repairs sentence Nothing Nothing
    metricFor repairs stats sentence (candidate : _) = case parseWith (candidateGrammar candidate) sentence of
      Parsed success ->
        let cost = successfulCost success
            composition = compositionUses cost
            raising = typeRaisingUses cost
            application = max 0 (derivationSteps cost - length (tokens sentence) - composition)
            (categorizedTokens, tokenRate, wordCount, categorizedWords, wordRate, assignmentCount, missing) =
              lexicalCoverage sentence (candidateGrammar candidate)
         in TrainingMetric
              { metricSentenceId = sentenceId sentence
              , metricSentenceLength = length (tokens sentence)
              , metricCovered = True
              , metricLevel = Just (successfulLevel success)
              , metricRepairs = repairs
              , metricParseCount = parseCount success
              , metricApplicationUses = application
              , metricCompositionUses = composition
              , metricTypeRaisingUses = raising
              , metricRepairCandidatesFromCandidateLexicon = repairCandidatesFromCandidateLexicon stats
              , metricRepairCandidatesFromUnknownFallback = repairCandidatesFromUnknownFallback stats
              , metricRepairCandidatesFilteredByPos = repairCandidatesFilteredByPos stats
              , metricRepairCandidatesFilteredByWordNet = repairCandidatesFilteredByWordNet stats
              , metricRepairCandidatesValidated = repairCandidatesValidated stats
              , metricRepairCandidatesAccepted = repairCandidatesAccepted stats
              , metricCategorizedTokenCount = categorizedTokens
              , metricCategorizedTokenRate = tokenRate
              , metricWordTypeCount = wordCount
              , metricCategorizedWordTypeCount = categorizedWords
              , metricCategorizedWordTypeRate = wordRate
              , metricCategoryAssignmentCount = assignmentCount
              , metricUncategorizedWords = missing
              , metricFarthestPosition = Nothing
              }
      Failed failure ->
        emptyMetric stats repairs sentence (Just (candidateGrammar candidate))
          (Just (farthestPosition failure))
    jobs = max 1 requestedJobs

configuredCandidates :: Config -> [Sentence] -> Grammar -> Either Data.Text.Text (Grammar, CandidateLexicon)
configuredCandidates config corpus grammar = do
  atoms <- configuredAtomTable config (grammarAtoms grammar)
  let configuredGrammar = grammar { grammarAtoms = atoms }
  if not (candidateConstraintsEnabled (candidateConstraints config))
    then Right (configuredGrammar, emptyCandidateLexicon)
    else do
      (atoms', store, candidates) <- buildCandidateLexiconFromConfig
        config emptyWordNetInventory corpus atoms (grammarCategories configuredGrammar)
      Right (configuredGrammar { grammarAtoms = atoms', grammarCategories = store }, candidates)

emptyMetric :: RepairStats -> Int -> Sentence -> Maybe Grammar -> Maybe Int -> TrainingMetric
emptyMetric stats repairs sentence maybeGrammar failurePosition =
  TrainingMetric
    { metricSentenceId = sentenceId sentence
    , metricSentenceLength = length (tokens sentence)
    , metricCovered = False
    , metricLevel = Nothing
    , metricRepairs = repairs
    , metricParseCount = 0
    , metricApplicationUses = 0
    , metricCompositionUses = 0
    , metricTypeRaisingUses = 0
    , metricRepairCandidatesFromCandidateLexicon = repairCandidatesFromCandidateLexicon stats
    , metricRepairCandidatesFromUnknownFallback = repairCandidatesFromUnknownFallback stats
    , metricRepairCandidatesFilteredByPos = repairCandidatesFilteredByPos stats
    , metricRepairCandidatesFilteredByWordNet = repairCandidatesFilteredByWordNet stats
    , metricRepairCandidatesValidated = repairCandidatesValidated stats
    , metricRepairCandidatesAccepted = repairCandidatesAccepted stats
    , metricCategorizedTokenCount = categorizedTokens
    , metricCategorizedTokenRate = tokenRate
    , metricWordTypeCount = wordCount
    , metricCategorizedWordTypeCount = categorizedWords
    , metricCategorizedWordTypeRate = wordRate
    , metricCategoryAssignmentCount = assignmentCount
    , metricUncategorizedWords = missing
    , metricFarthestPosition = failurePosition
    }
  where
    (categorizedTokens, tokenRate, wordCount, categorizedWords, wordRate, assignmentCount, missing) =
      case maybeGrammar of
        Just grammar -> lexicalCoverage sentence grammar
        Nothing ->
          let distinctWords = Set.toAscList (Set.fromList (tokens sentence))
           in (0, 0, length distinctWords, 0, 0, 0, distinctWords)

lexicalCoverage :: Sentence -> Grammar -> (Int, Double, Int, Int, Double, Int, [Data.Text.Text])
lexicalCoverage sentence grammar =
  (categorizedTokens, ratio categorizedTokens tokenCount, wordCount, categorizedWords,
    ratio categorizedWords wordCount, assignmentCount, missing)
  where
    lexicon = grammarLexicon grammar
    sentenceTokens = tokens sentence
    distinctWords = Set.toAscList (Set.fromList sentenceTokens)
    hasCategory word = not (null (categoriesForWord word lexicon))
    tokenCount = length sentenceTokens
    wordCount = length distinctWords
    categorizedTokens = length (filter hasCategory sentenceTokens)
    categorizedWords = length (filter hasCategory distinctWords)
    assignmentCount = sum (map (length . (`categoriesForWord` lexicon)) distinctWords)
    missing = filter (not . hasCategory) distinctWords

ratio :: Int -> Int -> Double
ratio _ 0 = 0
ratio numerator denominator = fromIntegral numerator / fromIntegral denominator

zeroRepairStats :: RepairStats
zeroRepairStats = RepairStats 0 0 0 0 0 0

addRepairStats :: RepairStats -> RepairStats -> RepairStats
addRepairStats left right = RepairStats
  (repairCandidatesFromCandidateLexicon left + repairCandidatesFromCandidateLexicon right)
  (repairCandidatesFromUnknownFallback left + repairCandidatesFromUnknownFallback right)
  (repairCandidatesFilteredByPos left + repairCandidatesFilteredByPos right)
  (repairCandidatesFilteredByWordNet left + repairCandidatesFilteredByWordNet right)
  (repairCandidatesValidated left + repairCandidatesValidated right)
  (repairCandidatesAccepted left + repairCandidatesAccepted right)

chunkSize :: Int -> Int -> Int
chunkSize jobs itemCount = max 1 ((itemCount + workerCount - 1) `div` workerCount)
  where workerCount = max 1 jobs
