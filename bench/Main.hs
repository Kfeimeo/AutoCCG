{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import CCG.Atom (defaultAtomTable)
import CCG.CategoryStore (emptyCategoryStore, parseCategory)
import Criterion.Main

main :: IO ()
main = defaultMain
  [ bench "category interning" $ nf (parseCategory "(S\\NP)/NP" defaultAtomTable) emptyCategoryStore
  ]
