import Text.XML.Enumerator.Parse
import qualified Data.ByteString as S
import Data.Enumerator
import qualified Data.Enumerator as E
import Data.Enumerator.Text hiding (iterHandle)
import Control.Monad.IO.Class
import Blaze.ByteString.Builder.Enumerator
import Data.Enumerator.IO
import System.IO (withBinaryFile, IOMode (WriteMode))
import Text.XML.Enumerator.Render

main :: IO ()
main = do
    x <- S.readFile "test16.xml"
    run_ (enumList 1 [x] $$ joinI $ decode utf16_be $$ joinI $ encode utf8 $$ consume) >>= print
    putStrLn "\n\n"
    run_ $ enumList 1 [x] $$ joinI $ detectUtf $$ joinI $ parseBytes $$ iterPrint
    withBinaryFile "test8.xml" WriteMode $ \h ->
        run_ $ enumList 1 [x] $$ joinI $ detectUtf $$ joinI $ parseBytes
            $$ joinI $ renderBuilder
            $$ joinI $ builderToByteString
            $$ iterHandle h
  where
    iterPrint = do
        x <- E.head
        case x of
            Nothing -> return ()
            Just y -> liftIO (print y) >> iterPrint
