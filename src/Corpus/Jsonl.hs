{-# LANGUAGE OverloadedStrings #-}

module Corpus.Jsonl (readJsonl, writeJsonl) where

import Corpus.Types (Sentence)
import Data.Aeson (eitherDecodeStrict', encode)
import qualified Data.ByteString.Char8 as ByteString
import qualified Data.ByteString.Lazy as Lazy
import Data.Text (Text)
import qualified Data.Text as Text

readJsonl :: FilePath -> IO (Either Text [Sentence])
readJsonl path = do
  contents <- ByteString.readFile path
  pure (traverse decodeLine (zip [1 :: Int ..] (filter (not . ByteString.null) (ByteString.lines contents))))
  where
    decodeLine (lineNumber, line) = case eitherDecodeStrict' line of
      Left message -> Left ("line " <> Text.pack (show lineNumber) <> ": " <> Text.pack message)
      Right sentence -> Right sentence

writeJsonl :: FilePath -> [Sentence] -> IO ()
writeJsonl path sentences = Lazy.writeFile path (mconcat [encode sentence <> "\n" | sentence <- sentences])
