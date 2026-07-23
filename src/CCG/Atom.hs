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
  ) where

import Data.Aeson (FromJSON, ToJSON)
import Data.Hashable (Hashable)
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Text (Text)

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
