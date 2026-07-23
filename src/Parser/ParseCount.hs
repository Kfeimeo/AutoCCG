module Parser.ParseCount (saturatingAdd) where

saturatingAdd :: Int -> Int -> Int -> Int
saturatingAdd cap left right = min cap (left + right)
