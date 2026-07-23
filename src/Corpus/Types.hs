{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

module Corpus.Types (Sentence (..)) where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.!=), (.=))
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
  } deriving (Eq, Show, Generic)

instance FromJSON Sentence where
  parseJSON = withObject "Sentence" $ \o -> do
    sentenceId' <- o .: "sentence_id"
    tokens' <- o .: "tokens"
    Sentence sentenceId' tokens'
      <$> o .:? "lemmas" .!= tokens'
      <*> o .:? "pos" .!= []
      <*> o .:? "morph" .!= []
      <*> o .:? "metadata" .!= mempty

instance ToJSON Sentence where
  toJSON sentence = object
    [ "sentence_id" .= sentenceId sentence, "tokens" .= tokens sentence
    , "lemmas" .= lemmas sentence, "pos" .= posTags sentence
    , "morph" .= morphology sentence, "metadata" .= metadata sentence
    ]
