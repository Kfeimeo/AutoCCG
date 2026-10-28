{-# LANGUAGE OverloadedStrings #-}

module Lexicon.Repair
  ( RepairOperation (..)
  , RepairScore (..)
  , RepairProposal (..)
  , RepairStats (..)
  , RepairBatch (..)
  , repairSentence
  , repairSentenceWithJobs
  , repairSentenceWithCandidates
  , repairSentenceAtFailure
  ) where

import CCG.Category (CategoryId (..), categorySlashCount)
import CCG.CategoryStore (lookupCategory)
import CCG.Combinator (applicationResults, compositionResults)
import Control.Parallel.Strategies (parListChunk, rdeepseq, using)
import Corpus.Types (Sentence (..))
import Data.List (sortOn)
import qualified Data.Set as Set
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Grammar.Types (CategoryProvenance (..), Grammar (..), grammarRules)
import Lexicon.Candidate (boundedCategoryUniverse)
import Lexicon.CandidateLexicon
import Lexicon.Initialization (internNamedCategory)
import Lexicon.Types (categoriesForWord, insertEntry)
import Parser.Config
import qualified Parser.Config as Config
import Parser.Incremental (ParseOutcome (..), parseSentence)
import Parser.FailureFrontier (ParseFailure (..))

data RepairOperation
  = AddCategory !Text !CategoryId
  | ReplaceCategory !Text !CategoryId !CategoryId
  | AddTwoCategories !Text !CategoryId !Text !CategoryId
  deriving (Eq, Ord, Show)

data RepairScore = RepairScore
  { repairAddedCategoryCount :: !Int
  , repairPriorCost :: !Int
  , repairParseSpaceDelta :: !Int
  , repairCategorySize :: !Int
  , repairAffectedSentences :: !Int
  , repairLocalParseCount :: !Int
  , repairCategoryTieBreak :: !CategoryId
  , repairWordTieBreak :: !Text
  } deriving (Eq, Ord, Show)

data RepairProposal = RepairProposal
  { proposalOperation :: !RepairOperation
  , proposalGrammar :: !Grammar
  , proposalSource :: !CandidateSource
  , proposalPriorCost :: !Int
  } deriving (Eq, Show)

data RepairStats = RepairStats
  { repairCandidatesFromCandidateLexicon :: !Int
  , repairCandidatesFromUnknownFallback :: !Int
  , repairCandidatesFilteredByPos :: !Int
  , repairCandidatesFilteredByWordNet :: !Int
  , repairCandidatesValidated :: !Int
  , repairCandidatesAccepted :: !Int
  } deriving (Eq, Show)

data RepairBatch = RepairBatch
  { successfulRepairProposals :: ![RepairProposal]
  , repairBatchStats :: !RepairStats
  } deriving (Eq, Show)

repairSentence :: Config -> Sentence -> Grammar -> [(RepairOperation, Grammar)]
repairSentence = repairSentenceWithJobs 1

repairSentenceWithJobs :: Int -> Config -> Sentence -> Grammar -> [(RepairOperation, Grammar)]
repairSentenceWithJobs jobs config sentence grammar =
  [ (proposalOperation proposal, proposalGrammar proposal)
  | proposal <- successfulRepairProposals (legacyRepair jobs config sentence grammar)
  ]

repairSentenceWithCandidates :: Int -> Config -> CandidateLexicon -> Sentence -> Grammar -> RepairBatch
repairSentenceWithCandidates jobs config candidates sentence grammar =
  repairSentenceConstrained jobs config candidates Nothing sentence grammar

repairSentenceAtFailure :: Int -> Config -> CandidateLexicon -> ParseFailure -> Sentence -> Grammar -> RepairBatch
repairSentenceAtFailure jobs config candidates failure sentence grammar =
  repairSentenceConstrained jobs config candidates (Just failure) sentence grammar

repairSentenceConstrained :: Int -> Config -> CandidateLexicon -> Maybe ParseFailure -> Sentence -> Grammar -> RepairBatch
repairSentenceConstrained jobs config candidates failure sentence grammar
  | not (candidateConstraintsEnabled (candidateConstraints config)) = legacyRepair jobs config sentence grammar
  | otherwise =
      let candidatePool
            | useCandidateLexiconFirst repairConfig =
                take (maxCandidatesGenerated repairConfig) (candidateProposalsAtFailure config candidates failure sentence grammar)
            | otherwise = []
          candidateValidated = map snd (take (maxCandidatesValidated repairConfig) candidatePool)
          candidateSuccesses = validate jobs config sentence candidateValidated
          candidateStats = zeroStats
            { repairCandidatesFromCandidateLexicon = length candidatePool
            , repairCandidatesValidated = length candidateValidated
            , repairCandidatesAccepted = length candidateSuccesses
            }
       in if not (null candidateSuccesses)
            || not (allowUnknownFallback repairConfig)
            || unknownPolicy (candidateConstraints config) /= "small_default"
            then RepairBatch (limitSuccess candidateSuccesses) candidateStats
            else
              let fallbackPool = take (unknownFallbackMaxCandidates repairConfig * distinctWordCount sentence)
                    (unknownFallbackProposals config sentence grammar)
                  fallbackValidated = map snd (take (maxCandidatesValidated repairConfig) fallbackPool)
                  fallbackSuccesses = validate jobs config sentence fallbackValidated
                  stats = candidateStats
                    { repairCandidatesFromUnknownFallback = length fallbackPool
                    , repairCandidatesValidated = length candidateValidated + length fallbackValidated
                    , repairCandidatesAccepted = length fallbackSuccesses
                    }
               in RepairBatch (limitSuccess fallbackSuccesses) stats
  where
    repairConfig = Config.repair config
    limitSuccess = take (maxRepairsPerFailure (Config.grammar config))

legacyRepair :: Int -> Config -> Sentence -> Grammar -> RepairBatch
legacyRepair jobs config sentence grammar =
  let (universe, store') = boundedCategoryUniverse (categories config) (grammarCategories grammar)
      base = grammar { grammarCategories = store' }
      proposals =
        [ scoredProposal config sentence word
            (CandidateCategory categoryId 0 FromUnknownFallback False) base
        | word <- distinctWords sentence
        , categoryId <- universe
        , categoryId `notElem` categoriesForWord word (grammarLexicon base)
        ]
      ordered = sortOn fst proposals
      successes = validate jobs config sentence (map snd ordered)
      limited = take (maxRepairsPerFailure (Config.grammar config)) successes
   in RepairBatch limited (zeroStats
        { repairCandidatesFromUnknownFallback = length proposals
        , repairCandidatesValidated = length proposals
        , repairCandidatesAccepted = length limited
        })

candidateProposalsAtFailure :: Config -> CandidateLexicon -> Maybe ParseFailure -> Sentence -> Grammar -> [(RepairScore, RepairProposal)]
candidateProposalsAtFailure config candidates failure sentence grammar = sortOn fst
  [ scoredProposal config sentence word candidate grammar
  | word <- distinctWords sentence
  , candidate <- candidateCategoriesForWord word candidates
  , candidateCategoryId candidate `notElem` categoriesForWord word (grammarLexicon grammar)
  , locallyFeasible config failure grammar (candidateCategoryId candidate)
  ]

locallyFeasible :: Config -> Maybe ParseFailure -> Grammar -> CategoryId -> Bool
locallyFeasible _ Nothing _ _ = True
locallyFeasible config (Just failure) grammar candidateId
  | Set.null expected = True
  | otherwise = any compatible (Set.toAscList expected)
  where
    expected = expectedCategories failure
    store = grammarCategories grammar
    compatible neighbor =
      not (null (applicationResults store candidateId neighbor))
        || not (null (applicationResults store neighbor candidateId))
        || any (compositionEnabled . fst) (fst (compositionResults (maxCompositionDegree ruleConfig) store candidateId neighbor))
        || any (compositionEnabled . fst) (fst (compositionResults (maxCompositionDegree ruleConfig) store neighbor candidateId))
    compositionEnabled = combinatorEnabled ruleConfig
    ruleConfig = rules config

unknownFallbackProposals :: Config -> Sentence -> Grammar -> [(RepairScore, RepairProposal)]
unknownFallbackProposals config sentence initialGrammar = snd (foldl' addTemplate (initialGrammar, []) templates)
  where
    templates = ["NP", "N", "S\\NP", "(S\\NP)/NP", "NP/N", "N/N", "PP/NP"]
    addTemplate (grammar, accumulated) categoryText = case internNamedCategory categoryText grammar of
      Left _ -> (grammar, accumulated)
      Right (categoryId, grammar') ->
        let candidate = CandidateCategory categoryId 100 FromUnknownFallback False
            newProposals =
              [ scoredProposal config sentence word candidate grammar'
              | word <- distinctWords sentence
              , categoryWithinBounds (categories config) (grammarCategories grammar') categoryId
              , categoryId `notElem` categoriesForWord word (grammarLexicon grammar')
              ]
         in (grammar', accumulated ++ newProposals)

scoredProposal
  :: Config
  -> Sentence
  -> Text
  -> CandidateCategory
  -> Grammar
  -> (RepairScore, RepairProposal)
scoredProposal _ sentence word candidate grammar =
  ( RepairScore
      1
      (candidatePriorCost candidate)
      parseSpaceEstimate
      complexity
      occurrences
      0
      categoryId
      word
  , RepairProposal
      (AddCategory word categoryId)
      grammar
        { grammarLexicon = insertEntry word categoryId (grammarLexicon grammar)
        , grammarProvenance = Map.insert (word, categoryId)
            (CategoryProvenance
              (candidateSource candidate)
              (candidatePriorCost candidate)
              (Just (sentenceId sentence))
              "AllParserLevelsFailed")
            (grammarProvenance grammar)
        }
      (candidateSource candidate)
      (candidatePriorCost candidate)
  )
  where
    categoryId = candidateCategoryId candidate
    occurrences = length (filter (== word) (tokens sentence))
    complexity = categorySlashCount (`lookupCategory` grammarCategories grammar) categoryId
    parseSpaceEstimate = occurrences * (1 + complexity)

validate :: Int -> Config -> Sentence -> [RepairProposal] -> [RepairProposal]
validate jobs config sentence proposals =
  [ proposal | (proposal, True) <- zip proposals outcomes ]
  where
    succeeds proposal = case parseSentence config
      (grammarCategories (proposalGrammar proposal))
      (grammarLexicon (proposalGrammar proposal))
      (grammarRules (proposalGrammar proposal))
      (rootCategory (proposalGrammar proposal))
      (tokens sentence) of
        Parsed _ -> True
        Failed _ -> False
    outcomes = map succeeds proposals `using` parListChunk (chunkSize jobs (length proposals)) rdeepseq

distinctWords :: Sentence -> [Text]
distinctWords = Set.toAscList . Set.fromList . tokens

distinctWordCount :: Sentence -> Int
distinctWordCount = length . distinctWords

zeroStats :: RepairStats
zeroStats = RepairStats 0 0 0 0 0 0

chunkSize :: Int -> Int -> Int
chunkSize jobs itemCount = max 1 ((itemCount + workerCount - 1) `div` workerCount)
  where workerCount = max 1 jobs
