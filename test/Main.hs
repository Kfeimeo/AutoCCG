module Main (main) where

import qualified CategorySpec
import qualified CandidateLexiconSpec
import qualified CombinatorSpec
import qualified CompressionSpec
import qualified EisnerSpec
import qualified InductionSpec
import qualified ParserSpec
import qualified PosMappingSpec
import qualified PropertySpec
import qualified RepairSpec
import Test.Tasty (defaultMain, testGroup)

main :: IO ()
main = defaultMain $ testGroup "ccg-induction"
  [ CategorySpec.tests, CandidateLexiconSpec.tests, CombinatorSpec.tests, ParserSpec.tests
  , RepairSpec.tests, CompressionSpec.tests, InductionSpec.tests, PropertySpec.tests
  , PosMappingSpec.tests, EisnerSpec.tests
  ]
