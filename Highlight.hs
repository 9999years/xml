import Data.Maybe
import System.IO
import System.Environment
import Text.HTML.TagStream
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as S
import System.Console.ANSI
import qualified Data.Enumerator as E
import qualified Data.Enumerator.Binary as E
import qualified Data.Enumerator.List as EL
import Blaze.ByteString.Builder (Builder)
import Blaze.ByteString.Builder.Enumerator (unsafeBuilderToByteString, allocBuffer)

color :: Color -> ByteString -> ByteString
color c s = S.concat [ S.pack $ setSGRCode [SetColor Foreground Dull c]
                     , s
                     , S.pack $ setSGRCode [SetColor Foreground Dull White]
                     ]

hightlightStream :: Monad m => E.Enumeratee Token Builder m b
hightlightStream = EL.map (showToken (color Red))

main :: IO ()
main = do
    args <- getArgs
    filename <- maybe (fail "pass file path") return (listToMaybe args)
    let iter = E.enumFile filename
               E.$= tokenStream
               E.$= hightlightStream
               E.$= unsafeBuilderToByteString (allocBuffer 4096)
               E.$$ E.iterHandle stdout
    E.run_ iter
