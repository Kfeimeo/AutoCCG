module RepairBench (repairBenchmarks) where

import Criterion.Main (Benchmark, bgroup)

repairBenchmarks :: Benchmark
repairBenchmarks = bgroup "repair" []
