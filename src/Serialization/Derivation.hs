{-# LANGUAGE OverloadedStrings #-}

module Serialization.Derivation
  ( derivationSummary
  , derivationTree
  , combinatorLabel
  ) where

import CCG.Atom (AtomTable)
import CCG.Combinator (Combinator (..))
import CCG.CategoryStore (CategoryStore, prettyCategory)
import CCG.Category (CategoryId)
import CCG.Derivation (DerivationArena, DerivationNode (..), DerivationRef, lookupDerivation)
import Data.Aeson (Value (..), object, (.=))
import Data.Text (Text)
import Parser.Incremental (ParseSuccess (..))

-- | Version 2 adds @derivations@: the derivation trees recorded by the parser
-- (one, or every normal-form reading with the Eisner parser and
-- @derivations: all@).  The field is omitted when the parser records no trees.
derivationSummary :: AtomTable -> ParseSuccess -> Value
derivationSummary atoms success = object $
  [ "version" .= (2 :: Int)
  , "level" .= show (successfulLevel success)
  , "parse_count" .= parseCount success
  , "cost" .= show (successfulCost success)
  ]
    ++ [ "derivations" .= map (derivationTree atoms (finalStore success) (finalArena success)) refs
       | let refs = allDerivations success
       , not (null refs)
       ]

-- | A derivation as nested JSON: leaves carry the word and its position,
-- internal nodes the rule label and their children.
derivationTree :: AtomTable -> CategoryStore -> DerivationArena -> DerivationRef -> Value
derivationTree atoms store arena = go
  where
    go ref = case lookupDerivation ref arena of
      Just (LexicalNode position word category) -> object
        ["word" .= word, "position" .= position, "category" .= render category]
      Just (BinaryNode combinator category left right) -> object
        ["rule" .= combinatorLabel combinator, "category" .= render category, "children" .= [go left, go right]]
      Just (RaisedNode category child) -> object
        ["rule" .= ("T" :: Text), "category" .= render category, "children" .= [go child]]
      Nothing -> Null
    render :: CategoryId -> Text
    render = either id id . prettyCategory atoms store

-- | Conventional CCG rule labels.
combinatorLabel :: Combinator -> Text
combinatorLabel combinator = case combinator of
  ForwardApplication -> ">"
  BackwardApplication -> "<"
  ForwardComposition -> ">B"
  BackwardComposition -> "<B"
  ForwardCrossedComposition -> ">Bx"
  BackwardCrossedComposition -> "<Bx"
  ForwardGeneralizedComposition -> ">Bn"
  BackwardGeneralizedComposition -> "<Bn"
  ForwardGeneralizedCrossedComposition -> ">Bxn"
  BackwardGeneralizedCrossedComposition -> "<Bxn"
