module Lexicon.Compression (compressGrammar) where

import Corpus.Types (Sentence (tokens))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Grammar.Types (Grammar (..), grammarRules)
import Lexicon.Types (deleteEntry, lexiconEntries)
import Parser.Config (Config)
import Parser.Incremental (ParseOutcome (..), parseSentence)

-- Greedy deterministic removal with rollback: an entry is committed only if all
-- previously accepted sentences remain covered.
compressGrammar :: Config -> [Sentence] -> Grammar -> Grammar
compressGrammar config corpus grammar = foldl' tryRemove grammar entries
  where
    usedWords = Set.fromList (concatMap tokens corpus)
    entries = [(word, categoryId) | (word, categories) <- lexiconEntries (grammarLexicon grammar), categoryId <- categories]
    tryRemove current (word, categoryId)
      | word `Set.notMember` usedWords = remove current word categoryId
      | otherwise =
          let candidate = remove current word categoryId
           in if all (covered candidate) corpus then candidate else current
    remove current word categoryId = current
      { grammarLexicon = deleteEntry word categoryId (grammarLexicon current)
      , grammarProvenance = Map.delete (word, categoryId) (grammarProvenance current)
      }
    covered candidate sentence = case parseSentence config (grammarCategories candidate) (grammarLexicon candidate) (grammarRules candidate) (rootCategory candidate) (tokens sentence) of
      Parsed _ -> True
      Failed _ -> False
