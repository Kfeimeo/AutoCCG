module ParserBench (parserBenchmarks) where

import Criterion.Main (Benchmark, bgroup)

parserBenchmarks :: Benchmark
parserBenchmarks = bgroup "parser" []
