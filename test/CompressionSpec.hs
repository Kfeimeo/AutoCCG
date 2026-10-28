{-# LANGUAGE OverloadedStrings #-}

module CompressionSpec (tests) where

import Corpus.Types (Sentence (..))
import qualified Data.Map.Strict as Map
import Grammar.Types (Grammar (..))
import Lexicon.Compression (compressGrammar)
import Lexicon.Initialization (emptyGrammar, internNamedCategory)
import Lexicon.Types (categoriesForWord, insertEntry)
import Parser.Config (defaultConfig)
import Test.Tasty (TestTree, testGroup)
import Test.Tasty.HUnit

tests :: TestTree
tests = testGroup "compression"
  [ testCase "removes entry for word absent from accepted corpus" $ do
      case internNamedCategory "NP" emptyGrammar of
        Left message -> assertFailure (show message)
        Right (np, grammar) -> do
          let grammar' = grammar { grammarLexicon = insertEntry "unused" np (grammarLexicon grammar) }
              corpus = [Sentence "s" ["known"] ["known"] [] [] Map.empty []]
          categoriesForWord "unused" (grammarLexicon (compressGrammar defaultConfig corpus grammar')) @?= []
  ]
