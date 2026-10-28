{-# LANGUAGE OverloadedStrings #-}

module Corpus.PlainText (fromPlainText) where

import Corpus.Types (Sentence (..))
import qualified Data.Map.Strict as Map
import Data.Text (Text)
import qualified Data.Text as Text

fromPlainText :: Text -> [Sentence]
fromPlainText contents =
  [ Sentence ("line_" <> Text.pack (show lineNumber)) words' words' [] [] Map.empty []
  | (lineNumber, line) <- zip [1 :: Int ..] (Text.lines contents)
  , let words' = Text.words line
  , not (null words')
  ]
