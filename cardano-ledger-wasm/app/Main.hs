module Main (main) where

import CardanoLedgerWasm (banner, roundTripConstant)

main :: IO ()
main =
    case roundTripConstant of
        Right 42 -> putStrLn banner
        Right n -> putStrLn ("unexpected round-trip value: " ++ show n)
        Left err -> putStrLn ("cborg round-trip failed: " ++ err)
