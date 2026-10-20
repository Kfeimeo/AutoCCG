{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE OverloadedStrings #-}

-- | Configured mapping from token POS tags to prior CCG category templates.
--
-- The design follows the lexicon set-up of lightblue
-- (<https://github.com/DaisukeBekki/lightblue>): a library of /named
-- templates/ (lightblue's @Templates.hs@ constructors) is selected by an
-- /ordered rule cascade/ over POS tags (lightblue's @jumanPos2Cat@ guards).
--
-- Invariants:
--
-- * Rules are tried in configuration order and the first matching rule wins,
--   so more specific rules (e.g. exact @NNP@, or @DT@ restricted to the word
--   @a@) must precede broader ones (e.g. prefix @NN@, or any @DT@).
-- * A rule may be restricted to exact word forms, mirroring lightblue's
--   @(word, pos)@ patterns such as @(\"and\", \"CC\")@.
-- * Every template name referenced by a rule exists; this is checked when the
--   mapping is decoded, so resolution is total.
-- * A mapping only proposes prior candidates.  It never activates a category
--   in the parser-visible lexicon by itself.
module Lexicon.PosMapping
  ( CandidateTemplateConfig (..)
  , PosMatch (..)
  , PosRule (..)
  , PosMapping (..)
  , emptyPosMapping
  , posMappingFromTable
  , appendExactTagRules
  , posMatches
  , resolvePosTemplates
  , posMappingTemplates
  ) where

import Data.Aeson (FromJSON (..), withObject, (.:?), (.!=))
import Data.Aeson.Types (Parser)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Maybe (catMaybes)
import Data.Text (Text)
import qualified Data.Text as Text
import GHC.Generics (Generic)

data CandidateTemplateConfig = CandidateTemplateConfig
  { templateCategory :: !Text
  , templatePriorCost :: !Int
  } deriving (Eq, Show, Generic)

-- | How a rule selects POS tags.  Matching is case-sensitive because tagsets
-- distinguish case-only variants only by convention, never by meaning.
data PosMatch
  = ExactTags ![Text]
  | TagPrefix !Text
  deriving (Eq, Show, Generic)

data PosRule = PosRule
  { posRuleMatch :: !PosMatch
  , posRuleWords :: !(Maybe [Text])
  -- ^ Exact, case-sensitive word forms the rule is restricted to.
  , posRuleTemplateNames :: ![Text]
  -- ^ Named templates, expanded in the listed order.
  , posRuleCategories :: ![CandidateTemplateConfig]
  -- ^ Inline categories appended after the named templates.
  } deriving (Eq, Show, Generic)

data PosMapping = PosMapping
  { posTemplateLibrary :: !(Map Text [CandidateTemplateConfig])
  , posRules :: ![PosRule]
  } deriving (Eq, Show, Generic)

emptyPosMapping :: PosMapping
emptyPosMapping = PosMapping Map.empty []

-- | The flat @TAG -> [category]@ shorthand as one exact-tag rule per tag.
posMappingFromTable :: Map Text [CandidateTemplateConfig] -> PosMapping
posMappingFromTable table = appendExactTagRules table emptyPosMapping

-- | Append shorthand exact-tag rules after the existing cascade, so explicit
-- cascade rules keep precedence.
appendExactTagRules :: Map Text [CandidateTemplateConfig] -> PosMapping -> PosMapping
appendExactTagRules table mapping = mapping
  { posRules = posRules mapping ++ [PosRule (ExactTags [tag]) Nothing [] templates | (tag, templates) <- Map.toAscList table] }

posMatches :: PosMatch -> Text -> Bool
posMatches match tag = case match of
  ExactTags tags -> tag `elem` tags
  TagPrefix prefix -> prefix `Text.isPrefixOf` tag

-- | Templates of the first rule matching the word and tag, or 'Nothing' when
-- no rule matches.  An empty tag never matches: absent POS is handled by the
-- caller's shape and WordNet fallbacks.
resolvePosTemplates :: PosMapping -> Text -> Text -> Maybe [CandidateTemplateConfig]
resolvePosTemplates mapping word tag
  | Text.null tag = Nothing
  | otherwise = case filter matches (posRules mapping) of
      rule : _ -> Just (expandRule mapping rule)
      [] -> Nothing
  where
    matches rule = posMatches (posRuleMatch rule) tag && maybe True (word `elem`) (posRuleWords rule)

-- | Every category template the mapping can produce, for configuration checks.
posMappingTemplates :: PosMapping -> [CandidateTemplateConfig]
posMappingTemplates mapping = concatMap (expandRule mapping) (posRules mapping)

expandRule :: PosMapping -> PosRule -> [CandidateTemplateConfig]
expandRule mapping rule =
  concatMap (\name -> Map.findWithDefault [] name (posTemplateLibrary mapping)) (posRuleTemplateNames rule)
    ++ posRuleCategories rule

instance FromJSON CandidateTemplateConfig where
  parseJSON = withObject "POS category template" $ \o -> CandidateTemplateConfig
    <$> o .:? "category" .!= "" <*> o .:? "prior_cost" .!= 0

instance FromJSON PosMapping where
  parseJSON = withObject "pos_mapping" $ \o -> do
    library <- o .:? "templates" .!= Map.empty
    rules <- o .:? "rules" .!= []
    let mapping = PosMapping library rules
        missing = [name | rule <- rules, name <- posRuleTemplateNames rule, not (Map.member name library)]
    case missing of
      [] -> pure mapping
      name : _ -> fail ("pos_mapping rule references an undefined template: " <> Text.unpack name)

instance FromJSON PosRule where
  parseJSON = withObject "pos_mapping rule" $ \o -> do
    tag <- o .:? "tag"
    tags <- o .:? "tags"
    prefix <- o .:? "prefix"
    match <- selectMatch (catMaybes [ExactTags . pure <$> tag, ExactTags <$> tags, TagPrefix <$> prefix])
    restriction <- o .:? "words"
    names <- o .:? "templates" .!= []
    inline <- o .:? "categories" .!= []
    if null names && null inline
      then fail "pos_mapping rule must name templates or list categories"
      else if restriction == Just []
        then fail "pos_mapping rule has an empty words list"
        else pure (PosRule match restriction names inline)
    where
      selectMatch :: [PosMatch] -> Parser PosMatch
      selectMatch matches = case matches of
        [ExactTags []] -> fail "pos_mapping rule has an empty tags list"
        [TagPrefix prefix] | Text.null prefix -> fail "pos_mapping rule has an empty prefix"
        [match] -> pure match
        _ -> fail "pos_mapping rule needs exactly one of tag, tags, or prefix"
