{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}

module CCG.Atom
  ( AtomId (..)
  , AtomTable
  , emptyAtomTable
  , defaultAtomTable
  , internAtom
  , lookupAtom
  , atomName
  , atomCount
  , addConfiguredAtoms
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Hashable (Hashable)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text

newtype AtomId = AtomId { unAtomId :: Int }
  deriving newtype (Eq, Ord, Show, Hashable, ToJSON, FromJSON)

data AtomTable = AtomTable
  { atomToId :: !(Map Text AtomId)
  , idToAtom :: !(IntMap Text)
  }
  deriving stock (Eq, Show)

emptyAtomTable :: AtomTable
emptyAtomTable = AtomTable Map.empty IntMap.empty

defaultAtomTable :: AtomTable
defaultAtomTable = snd (foldl add ([], emptyAtomTable) ["S", "NP", "N", "PP"])
  where
    add (ids, table) name = let (atomId, table') = internAtom name table in (atomId : ids, table')

internAtom :: Text -> AtomTable -> (AtomId, AtomTable)
internAtom name table = case Map.lookup name (atomToId table) of
  Just atomId -> (atomId, table)
  Nothing ->
    let atomId = AtomId (IntMap.size (idToAtom table))
     in ( atomId
        , AtomTable
            (Map.insert name atomId (atomToId table))
            (IntMap.insert (unAtomId atomId) name (idToAtom table))
        )

lookupAtom :: Text -> AtomTable -> Maybe AtomId
lookupAtom name = Map.lookup name . atomToId

atomName :: AtomId -> AtomTable -> Maybe Text
atomName (AtomId atomId) = IntMap.lookup atomId . idToAtom

atomCount :: AtomTable -> Int
atomCount = IntMap.size . idToAtom

-- | Add a deterministic, bounded atom inventory before parsing categories.
-- The root atom S must be declared explicitly even though it is present in the
-- default table.
addConfiguredAtoms :: [Text] -> Int -> AtomTable -> Either Text AtomTable
addConfiguredAtoms names maxCount table
  | maxCount < 1 = Left "atoms.max_count must be at least 1"
  | "S" `notElem` names = Left "atoms.predefined must contain the root atom S"
  | any (Text.null . Text.strip) names = Left "atoms.predefined must not contain empty names"
  | otherwise =
      let configured = foldl (\current name -> snd (internAtom name current)) table names
       in if atomCount configured > maxCount
            then Left "configured atom inventory exceeds atoms.max_count"
            else Right configured
