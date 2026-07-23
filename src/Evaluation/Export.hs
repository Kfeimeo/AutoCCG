{-# LANGUAGE OverloadedStrings #-}

module Evaluation.Export (writeCoverageResult) where

import Data.Aeson (encode, object, (.=))
import qualified Data.ByteString.Lazy as Lazy
import Evaluation.Coverage (CoverageResult (..))

writeCoverageResult :: FilePath -> CoverageResult -> IO ()
writeCoverageResult path result = Lazy.writeFile path . encode $ object
  [ "version" .= (1 :: Int), "sentence_count" .= sentenceCount result
  , "covered_sentence_count" .= coveredSentenceCount result
  , "root_s_success_rate" .= rootSSuccessRate result
  ]
