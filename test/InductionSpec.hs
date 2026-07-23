{-# LANGUAGE OverloadedStrings #-}

module InductionSpec (tests) where

import Corpus.Types (Sentence (..))
import Data.IORef (modifyIORef', newIORef, readIORef)
import qualified Data.Map.Strict as Map
import Grammar.Induction (metricSentenceId, trainCorpusWithJobs, trainCorpusWithProgress)
import Parser.Config (defaultConfig)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit ((@?=), testCase)

tests :: TestTree
tests = testGroup "induction"
  [ testCase "parallel training preserves deterministic result" $ do
      let corpus =
            [ Sentence "s1" ["Hello"] [] [] [] Map.empty
            , Sentence "s2" ["Goodbye"] [] [] [] Map.empty
            ]
      trainCorpusWithJobs 2 defaultConfig corpus @?=
        trainCorpusWithJobs 1 defaultConfig corpus
  , testCase "progress callback observes each sentence in corpus order" $ do
      observed <- newIORef []
      let corpus =
            [ Sentence "s1" ["Hello"] [] [] [] Map.empty
            , Sentence "s2" ["Goodbye"] [] [] [] Map.empty
            ]
      result <- trainCorpusWithProgress 2
        (\completed total metric ->
          modifyIORef' observed (<> [(completed, total, metricSentenceId metric)]))
        defaultConfig corpus
      events <- readIORef observed
      events @?= [(1, 2, "s1"), (2, 2, "s2")]
      result @?= trainCorpusWithJobs 1 defaultConfig corpus
  ]
