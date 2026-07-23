{-# LANGUAGE DeriveGeneric #-}

module Grammar.Cost (Cost (..), zeroCost) where

import GHC.Generics (Generic)

data Cost = Cost
  { unresolvedSentenceCount :: !Int
  , lexicalRepairCount :: !Int
  , extraCategoryCount :: !Int
  , typeRaisingCount :: !Int
  , compositionCount :: !Int
  , categoryComplexity :: !Int
  , ambiguityPenalty :: !Int
  , lexiconSizeCost :: !Int
  , specialCategoryPenalty :: !Int
  , derivationStepCount :: !Int
  } deriving (Eq, Ord, Show, Generic)

zeroCost :: Cost
zeroCost = Cost 0 0 0 0 0 0 0 0 0 0
