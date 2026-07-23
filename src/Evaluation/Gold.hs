module Evaluation.Gold (Accuracy (..), accuracy) where

data Accuracy = Accuracy { correct :: !Int, total :: !Int, ratio :: !Double } deriving (Eq, Show)

accuracy :: Eq a => [a] -> [a] -> Accuracy
accuracy predicted gold = Accuracy correctCount totalCount value
  where
    totalCount = min (length predicted) (length gold)
    correctCount = length [() | (left, right) <- zip predicted gold, left == right]
    value = if totalCount == 0 then 0 else fromIntegral correctCount / fromIntegral totalCount
