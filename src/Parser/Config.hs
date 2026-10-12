{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Parser.Config
  ( AtomConfig (..)
  , CategoryBounds (..)
  , ParserConfig (..)
  , GrammarConfig (..)
  , RuleConfig (..)
  , TrainingConfig (..)
  , CandidateConstraintsConfig (..)
  , CandidateTemplateConfig (..)
  , SeedEntryConfig (..)
  , InitializationConfig (..)
  , RepairConfig (..)
  , Config (..)
  , defaultConfig
  , loadConfig
  ) where

import Data.Aeson (FromJSON (..), withObject, (.:?), (.!=))
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import Data.Yaml (decodeFileEither, prettyPrintParseException)
import GHC.Generics (Generic)

data AtomConfig = AtomConfig
  { predefinedAtoms :: ![Text], maxAtomCount :: !Int
  } deriving (Eq, Show, Generic)

data CategoryBounds = CategoryBounds
  { maxDepth :: !Int, maxSlashes :: !Int, maxArity :: !Int
  } deriving (Eq, Show, Generic)

data ParserConfig = ParserConfig
  { beamWidth :: !Int, maxStackDepth :: !Int, maxStatesPerPosition :: !Int
  , maxReductionsPerShift :: !Int, parseCountCap :: !Int
  } deriving (Eq, Show, Generic)

data GrammarConfig = GrammarConfig
  { grammarBeamWidth :: !Int, maxRepairsPerFailure :: !Int, maxJointRepairWidth :: !Int
  } deriving (Eq, Show, Generic)

data RuleConfig = RuleConfig
  { allowForwardApplication :: !Bool, allowBackwardApplication :: !Bool
  , allowForwardComposition :: !Bool, allowBackwardComposition :: !Bool
  , allowCrossedComposition :: !Bool, allowGeneralizedComposition :: !Bool
  } deriving (Eq, Show, Generic)

data TrainingConfig = TrainingConfig
  { seed :: !Int, compressionInterval :: !Int, unresolvedPolicy :: !String
  } deriving (Eq, Show, Generic)

data CandidateConstraintsConfig = CandidateConstraintsConfig
  { candidateConstraintsEnabled :: !Bool
  , candidateLexiconPath :: !(Maybe FilePath)
  , useWordNetInventory :: !Bool
  , usePosTemplates :: !Bool
  , useSeedLexicon :: !Bool
  , unknownPolicy :: !Text
  , maxCandidatesPerWord :: !Int
  , rejectCandidatesOutsideCategoryBounds :: !Bool
  } deriving (Eq, Show, Generic)

data CandidateTemplateConfig = CandidateTemplateConfig
  { templateCategory :: !Text
  , templatePriorCost :: !Int
  } deriving (Eq, Show, Generic)

data SeedEntryConfig = SeedEntryConfig
  { seedCategory :: !Text
  , seedPriorCost :: !Int
  , seedLocked :: !Bool
  } deriving (Eq, Show, Generic)

data InitializationConfig = InitializationConfig
  { useLockedSeedEntries :: !Bool
  , activateSingleCandidateWords :: !Bool
  , activateBestCandidatePerWord :: !Bool
  , maxInitialPriorCost :: !Int
  } deriving (Eq, Show, Generic)

data RepairConfig = RepairConfig
  { useCandidateLexiconFirst :: !Bool
  , maxCandidatesGenerated :: !Int
  , maxCandidatesValidated :: !Int
  , allowUnknownFallback :: !Bool
  , unknownFallbackMaxCandidates :: !Int
  } deriving (Eq, Show, Generic)

data Config = Config
  { atoms :: !AtomConfig
  , categories :: !CategoryBounds, parser :: !ParserConfig, grammar :: !GrammarConfig
  , rules :: !RuleConfig, training :: !TrainingConfig
  , candidateConstraints :: !CandidateConstraintsConfig
  , posToCategories :: !(Map Text [CandidateTemplateConfig])
  , seedLexicon :: !(Map Text [SeedEntryConfig])
  , initialization :: !InitializationConfig
  , repair :: !RepairConfig
  } deriving (Eq, Show, Generic)

defaultConfig :: Config
defaultConfig = Config
  (AtomConfig ["S", "NP", "N", "PP"] 8)
  (CategoryBounds 5 4 3)
  (ParserConfig 128 12 2048 8 10000)
  (GrammarConfig 16 32 2)
  (RuleConfig True True True True False False)
  (TrainingConfig 42 100 "queue")
  (CandidateConstraintsConfig False Nothing True True True "small_default" 8 True)
  Map.empty
  Map.empty
  (InitializationConfig True True False 0)
  (RepairConfig True 100 10 True 5)

instance FromJSON AtomConfig where
  parseJSON = withObject "atoms" $ \o -> AtomConfig
    <$> o .:? "predefined" .!= ["S", "NP", "N", "PP"]
    <*> o .:? "max_count" .!= 8
instance FromJSON CategoryBounds where
  parseJSON = withObject "categories" $ \o -> CategoryBounds
    <$> o .:? "max_depth" .!= 5 <*> o .:? "max_slashes" .!= 4 <*> o .:? "max_arity" .!= 3
instance FromJSON ParserConfig where
  parseJSON = withObject "parser" $ \o -> ParserConfig
    <$> o .:? "beam_width" .!= 128 <*> o .:? "max_stack_depth" .!= 12
    <*> o .:? "max_states_per_position" .!= 2048 <*> o .:? "max_reductions_per_shift" .!= 8
    <*> o .:? "parse_count_cap" .!= 10000
instance FromJSON GrammarConfig where
  parseJSON = withObject "grammar" $ \o -> GrammarConfig
    <$> o .:? "beam_width" .!= 16 <*> o .:? "max_repairs_per_failure" .!= 32 <*> o .:? "max_joint_repair_width" .!= 2
instance FromJSON RuleConfig where
  parseJSON = withObject "rules" $ \o -> RuleConfig
    <$> o .:? "allow_forward_application" .!= True <*> o .:? "allow_backward_application" .!= True
    <*> o .:? "allow_forward_composition" .!= True <*> o .:? "allow_backward_composition" .!= True
    <*> o .:? "allow_crossed_composition" .!= False <*> o .:? "allow_generalized_composition" .!= False
instance FromJSON TrainingConfig where
  parseJSON = withObject "training" $ \o -> TrainingConfig
    <$> o .:? "seed" .!= 42 <*> o .:? "compression_interval" .!= 100 <*> o .:? "unresolved_policy" .!= "queue"
instance FromJSON CandidateConstraintsConfig where
  parseJSON = withObject "candidate_constraints" $ \o -> CandidateConstraintsConfig
    <$> o .:? "enabled" .!= False <*> o .:? "candidate_lexicon_path"
    <*> o .:? "use_wordnet_inventory" .!= True <*> o .:? "use_pos_templates" .!= True
    <*> o .:? "use_seed_lexicon" .!= True <*> o .:? "unknown_policy" .!= "small_default"
    <*> o .:? "max_candidates_per_word" .!= 8
    <*> o .:? "reject_candidates_outside_category_bounds" .!= True
instance FromJSON CandidateTemplateConfig where
  parseJSON = withObject "POS category template" $ \o -> CandidateTemplateConfig
    <$> o .:? "category" .!= "" <*> o .:? "prior_cost" .!= 0
instance FromJSON SeedEntryConfig where
  parseJSON = withObject "seed lexicon entry" $ \o -> SeedEntryConfig
    <$> o .:? "category" .!= "" <*> o .:? "prior_cost" .!= 0 <*> o .:? "lock" .!= False
instance FromJSON InitializationConfig where
  parseJSON = withObject "initialization" $ \o -> InitializationConfig
    <$> o .:? "use_locked_seed_entries" .!= True
    <*> o .:? "activate_single_candidate_words" .!= True
    <*> o .:? "activate_best_candidate_per_word" .!= False
    <*> o .:? "max_initial_prior_cost" .!= 0
instance FromJSON RepairConfig where
  parseJSON = withObject "repair" $ \o -> RepairConfig
    <$> o .:? "use_candidate_lexicon_first" .!= True
    <*> o .:? "max_candidates_generated" .!= 100
    <*> o .:? "max_candidates_validated" .!= 10
    <*> o .:? "allow_unknown_fallback" .!= True
    <*> o .:? "unknown_fallback_max_candidates" .!= 5
instance FromJSON Config where
  parseJSON = withObject "config" $ \o -> Config
    <$> o .:? "atoms" .!= atoms defaultConfig
    <*> o .:? "categories" .!= categories defaultConfig <*> o .:? "parser" .!= parser defaultConfig
    <*> o .:? "grammar" .!= grammar defaultConfig <*> o .:? "rules" .!= rules defaultConfig
    <*> o .:? "training" .!= training defaultConfig
    <*> o .:? "candidate_constraints" .!= candidateConstraints defaultConfig
    <*> o .:? "pos_to_categories" .!= posToCategories defaultConfig
    <*> o .:? "seed_lexicon" .!= seedLexicon defaultConfig
    <*> o .:? "initialization" .!= initialization defaultConfig
    <*> o .:? "repair" .!= repair defaultConfig

loadConfig :: FilePath -> IO (Either String Config)
loadConfig path = either (Left . prettyPrintParseException) Right <$> decodeFileEither path
