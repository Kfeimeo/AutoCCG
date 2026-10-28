{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Corpus.Types (Sentence (..), PosCandidate (..)) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.!=), (.=))
import Data.Maybe (catMaybes)
import Data.Map.Strict (Map)
import Data.Text (Text)
import GHC.Generics (Generic)

data Sentence = Sentence
  { sentenceId :: !Text
  , tokens :: ![Text]
  , lemmas :: ![Text]
  , posTags :: ![Text]
  , morphology :: ![Map Text Text]
  , metadata :: !(Map Text Text)
  , posCandidates :: ![[PosCandidate]]
  -- ^ Optional ranked POS tags per token, best first (JSON @pos_candidates@).
  -- When present for a token they replace its single @pos@ tag as candidate
  -- evidence.
  } deriving (Eq, Show, Generic)

-- | One ranked POS tag for a token and whether it came from WordNet rather
-- than from the token-level tagger.
data PosCandidate = PosCandidate
  { posCandidateTag :: !Text
  , posCandidateFromWordNet :: !Bool
  } deriving (Eq, Show, Generic)

instance FromJSON PosCandidate where
  parseJSON = withObject "POS candidate" $ \o -> do
    tag <- o .: "tag"
    source <- o .:? "source" .!= ("nltk" :: Text)
    pure (PosCandidate tag (source == "wordnet"))

instance ToJSON PosCandidate where
  toJSON candidate = object
    [ "tag" .= posCandidateTag candidate
    , "source" .= (if posCandidateFromWordNet candidate then "wordnet" else "nltk" :: Text)
    ]

instance FromJSON Sentence where
  parseJSON = withObject "Sentence" $ \o -> do
    sentenceId' <- o .: "sentence_id"
    tokens' <- o .: "tokens"
    Sentence sentenceId' tokens'
      <$> o .:? "lemmas" .!= tokens'
      <*> o .:? "pos" .!= []
      <*> o .:? "morph" .!= []
      <*> o .:? "metadata" .!= mempty
      <*> o .:? "pos_candidates" .!= []

instance ToJSON Sentence where
  toJSON sentence = object $
    [ "sentence_id" .= sentenceId sentence, "tokens" .= tokens sentence
    , "lemmas" .= lemmas sentence, "pos" .= posTags sentence
    , "morph" .= morphology sentence, "metadata" .= metadata sentence
    ] ++ catMaybes [if null (posCandidates sentence) then Nothing else Just ("pos_candidates" .= posCandidates sentence)]
