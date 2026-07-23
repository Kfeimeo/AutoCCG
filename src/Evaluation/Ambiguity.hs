module Evaluation.Ambiguity (averageParseCount) where

averageParseCount :: [Int] -> Double
averageParseCount [] = 0
averageParseCount counts = fromIntegral (sum counts) / fromIntegral (length counts)
