module Parser.FailureFrontier
  ( ParseStateSummary (..)
  , BlockingPair (..)
  , RightContextSummary (..)
  , ParseFailure (..)
  , makeFailure
  ) where

import CCG.Category (CategoryId)
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import Parser.State (ParseState (..), itemCategory)

data ParseStateSummary = ParseStateSummary
  { summaryPosition :: !Int
  , summaryStack :: ![CategoryId]
  } deriving (Eq, Ord, Show)

data BlockingPair = BlockingPair !CategoryId !CategoryId deriving (Eq, Ord, Show)

newtype RightContextSummary = RightContextSummary [Text] deriving (Eq, Ord, Show)

data ParseFailure = ParseFailure
  { farthestPosition :: !Int
  , survivingStates :: ![ParseStateSummary]
  , blockingPairs :: ![BlockingPair]
  , expectedCategories :: !(Set CategoryId)
  , rightContextSummary :: !RightContextSummary
  } deriving (Eq, Show)

makeFailure :: [Text] -> [ParseState] -> ParseFailure
makeFailure tokens states = ParseFailure far summaries pairs Set.empty (RightContextSummary (drop far tokens))
  where
    far = maximum (0 : map inputPosition states)
    frontier = take 32 [state | state <- states, inputPosition state == far]
    summaries = map (\state -> ParseStateSummary far (map itemCategory (categoryStack state))) frontier
    pairs = Set.toAscList . Set.fromList $
      [ BlockingPair (itemCategory left) (itemCategory right)
      | state <- frontier
      , right : left : _ <- [categoryStack state]
      ]
