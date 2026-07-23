module Serialization.Lexicon (saveLexicon) where

import Data.Aeson (encode)
import qualified Data.ByteString.Lazy as Lazy
import Grammar.Types (Grammar)
import Serialization.Grammar (grammarValue)

saveLexicon :: FilePath -> Grammar -> IO ()
saveLexicon path grammar = Lazy.writeFile path (encode (grammarValue grammar))
