{-# LANGUAGE OverloadedStrings #-}

module Serialization.Derivation (derivationSummary) where

import Data.Aeson (Value, object, (.=))
import Parser.Incremental (ParseSuccess (..))

derivationSummary :: ParseSuccess -> Value
derivationSummary success = object
  [ "version" .= (1 :: Int)
  , "level" .= show (successfulLevel success)
  , "parse_count" .= parseCount success
  , "cost" .= show (successfulCost success)
  ]
