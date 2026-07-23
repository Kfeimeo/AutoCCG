{-# LANGUAGE OverloadedStrings #-}

module Serialization.Grammar
  ( grammarFormatVersion
  , saveGrammar
  , loadGrammar
  , grammarValue
  ) where

import CCG.CategoryStore (prettyCategory)
import Control.Monad (foldM)
import Data.Aeson
import qualified Data.Aeson.Key as Key
import qualified Data.Aeson.KeyMap as KeyMap
import qualified Data.ByteString.Lazy as Lazy
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Map.Strict as Map
import Grammar.Types (CategoryProvenance (..), Grammar (..))
import Lexicon.CandidateLexicon (CandidateSource)
import Lexicon.Initialization (emptyGrammar, internNamedCategory)
import Lexicon.Types (insertEntry, lexiconEntries)

grammarFormatVersion :: Int
grammarFormatVersion = 2

data GrammarDocument = GrammarDocument !Int ![(Text, [Text])] ![ProvenanceDocument]
data ProvenanceDocument = ProvenanceDocument !Text !Text !CandidateSource !Int !(Maybe Text) !Text

instance FromJSON GrammarDocument where
  parseJSON = withObject "Grammar" $ \o -> GrammarDocument
    <$> o .: "version" <*> (o .: "lexicon" >>= parseEntries) <*> o .:? "provenance" .!= []
    where
      parseEntries = withObject "lexicon" $ \entries -> traverse parseEntry (KeyMap.toList entries)
      parseEntry (word, value) = (,) (Key.toText word) <$> parseJSON value

instance FromJSON ProvenanceDocument where
  parseJSON = withObject "category provenance" $ \o -> ProvenanceDocument
    <$> o .: "word" <*> o .: "category" <*> o .: "source" <*> o .: "prior_cost"
    <*> o .:? "accepted_at_sentence" <*> o .: "repair_reason"

grammarValue :: Grammar -> Value
grammarValue grammar = object
  [ "version" .= grammarFormatVersion
  , "root" .= ("S" :: Text)
  , "lexicon" .= object
      [ Key.fromText word .=
          [ either (const "<?>" ) id (prettyCategory (grammarAtoms grammar) (grammarCategories grammar) categoryId)
          | categoryId <- categories
          ]
      | (word, categories) <- lexiconEntries (grammarLexicon grammar)
      ]
  , "provenance" .=
      [ object
          [ "word" .= word
          , "category" .= either (const "<?>" ) id
              (prettyCategory (grammarAtoms grammar) (grammarCategories grammar) categoryId)
          , "source" .= provenanceSource provenance
          , "prior_cost" .= provenancePriorCost provenance
          , "accepted_at_sentence" .= provenanceAcceptedAtSentence provenance
          , "repair_reason" .= provenanceRepairReason provenance
          ]
      | ((word, categoryId), provenance) <- Map.toAscList (grammarProvenance grammar)
      ]
  ]

saveGrammar :: FilePath -> Grammar -> IO ()
saveGrammar path = Lazy.writeFile path . encode . grammarValue

loadGrammar :: FilePath -> IO (Either Text Grammar)
loadGrammar path = do
  decoded <- eitherDecode <$> Lazy.readFile path
  pure $ do
    GrammarDocument version entries provenance <- firstText decoded
    if version `notElem` [1, grammarFormatVersion]
      then Left ("unsupported grammar version: " <> Text.pack (show version))
      else do
        grammar <- foldM addWord emptyGrammar entries
        foldM addProvenance grammar provenance
  where
    firstText = either (Left . Text.pack) Right
    addWord grammar (word, categories) = foldM (addCategory word) grammar categories
    addCategory word grammar text = do
      (categoryId, grammar') <- internNamedCategory text grammar
      pure grammar' { grammarLexicon = insertEntry word categoryId (grammarLexicon grammar') }
    addProvenance grammar (ProvenanceDocument word categoryText source prior accepted reason) = do
      (categoryId, grammar') <- internNamedCategory categoryText grammar
      pure grammar'
        { grammarProvenance = Map.insert (word, categoryId)
            (CategoryProvenance source prior accepted reason) (grammarProvenance grammar') }
