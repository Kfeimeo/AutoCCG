{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module Lexicon.Types
  ( WordId (..)
  , Lexicon
  , emptyLexicon
  , categoriesFor
  , categoriesForWord
  , insertEntry
  , replaceEntry
  , deleteEntry
  , lexiconEntries
  , lexiconSize
  , lexicalTypeCount
  ) where

import CCG.Category (CategoryId (..))
import Data.Aeson (FromJSON, ToJSON)
import Data.Hashable (Hashable)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.IntSet (IntSet)
import qualified Data.IntSet as IntSet
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

newtype WordId = WordId { unWordId :: Int }
  deriving newtype (Eq, Ord, Show, Hashable, ToJSON, FromJSON)

data Lexicon = Lexicon
  { wordIds :: !(Map Text WordId)
  , wordNames :: !(IntMap Text)
  , assignments :: !(IntMap IntSet)
  , lexiconVersion :: !Int
  }
  deriving (Eq, Show)

emptyLexicon :: Lexicon
emptyLexicon = Lexicon Map.empty IntMap.empty IntMap.empty 0

categoriesFor :: WordId -> Lexicon -> [CategoryId]
categoriesFor (WordId wordId) lexicon =
  map CategoryId . IntSet.toAscList $ IntMap.findWithDefault IntSet.empty wordId (assignments lexicon)

categoriesForWord :: Text -> Lexicon -> [CategoryId]
categoriesForWord word lexicon = maybe [] (`categoriesFor` lexicon) (Map.lookup word (wordIds lexicon))

insertEntry :: Text -> CategoryId -> Lexicon -> Lexicon
insertEntry word (CategoryId categoryId) lexicon =
  let (wordId@(WordId rawId), ids', names') = case Map.lookup word (wordIds lexicon) of
        Just existing -> (existing, wordIds lexicon, wordNames lexicon)
        Nothing ->
          let fresh = WordId (Map.size (wordIds lexicon))
           in (fresh, Map.insert word fresh (wordIds lexicon), IntMap.insert (unWordId fresh) word (wordNames lexicon))
      current = IntMap.findWithDefault IntSet.empty rawId (assignments lexicon)
      updated = IntSet.insert categoryId current
   in wordId `seq` Lexicon ids' names' (IntMap.insert rawId updated (assignments lexicon)) (lexiconVersion lexicon + 1)

replaceEntry :: Text -> CategoryId -> CategoryId -> Lexicon -> Lexicon
replaceEntry word old new = insertEntry word new . deleteEntry word old

deleteEntry :: Text -> CategoryId -> Lexicon -> Lexicon
deleteEntry word (CategoryId categoryId) lexicon = case Map.lookup word (wordIds lexicon) of
  Nothing -> lexicon
  Just (WordId wordId) -> lexicon
    { assignments = IntMap.adjust (IntSet.delete categoryId) wordId (assignments lexicon)
    , lexiconVersion = lexiconVersion lexicon + 1
    }

lexiconEntries :: Lexicon -> [(Text, [CategoryId])]
lexiconEntries lexicon =
  [ (name, categoriesFor (WordId wordId) lexicon)
  | (wordId, name) <- IntMap.toAscList (wordNames lexicon)
  ]

lexiconSize :: Lexicon -> Int
lexiconSize = sum . map (length . snd) . lexiconEntries

lexicalTypeCount :: Lexicon -> Int
lexicalTypeCount = Map.size . wordIds
