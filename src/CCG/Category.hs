{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module CCG.Category
  ( CategoryId (..)
  , Slash (..)
  , CategoryNode (..)
  , categoryDepth
  , categorySlashCount
  , categoryArity
  ) where

import CCG.Atom (AtomId)
import Data.Aeson (FromJSON, ToJSON)
import Data.Hashable (Hashable)
import GHC.Generics (Generic)

newtype CategoryId = CategoryId { unCategoryId :: Int }
  deriving newtype (Eq, Ord, Show, Hashable, ToJSON, FromJSON)

data Slash = ForwardSlash | BackwardSlash
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Hashable)

data CategoryNode
  = Atomic !AtomId
  | Functional !Slash !CategoryId !CategoryId
  deriving stock (Eq, Ord, Show, Generic)
  deriving anyclass (Hashable)

categoryDepth :: (CategoryId -> Maybe CategoryNode) -> CategoryId -> Int
categoryDepth resolve categoryId = case resolve categoryId of
  Nothing -> 0
  Just (Atomic _) -> 1
  Just (Functional _ result argument) -> 1 + max (categoryDepth resolve result) (categoryDepth resolve argument)

categorySlashCount :: (CategoryId -> Maybe CategoryNode) -> CategoryId -> Int
categorySlashCount resolve categoryId = case resolve categoryId of
  Nothing -> 0
  Just (Atomic _) -> 0
  Just (Functional _ result argument) -> 1 + categorySlashCount resolve result + categorySlashCount resolve argument

categoryArity :: (CategoryId -> Maybe CategoryNode) -> CategoryId -> Int
categoryArity resolve categoryId = case resolve categoryId of
  Just (Functional _ result _) -> 1 + categoryArity resolve result
  _ -> 0
