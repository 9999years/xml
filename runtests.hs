{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE OverloadedStrings #-}
import Test.Hspec
import Test.Hspec.HUnit
import Test.HUnit hiding (Test)

import Data.XML.Types
import qualified Text.XML.Enumerator.Document as D
import Text.XML.Enumerator.Parse (decodeEntities)
import qualified Text.XML.Enumerator.Parse as P
import qualified Data.Map as Map
import qualified Data.ByteString.Lazy.Char8 as L
import Control.Monad.IO.Class (liftIO)
import qualified Control.Exception as C

main :: IO ()
main = hspec $ describe "XML parsing and rendering"
    [ it "is idempotent to parse and render a document" documentParseRender
    , it "has valid parser combinators" combinators
    , it "has working ignoreSiblings function" testIgnoreSiblings
    , it "has working choose function" testChoose
    , it "has working many function" testMany
    , it "has working orE" testOrE
    , it "has working chooseSplit" testChooseSplit
    , it "has working permute" testPermute
    , it "has working permuteFallback" testPermuteFallback
    ]

documentParseRender =
    mapM_ go docs
  where
    go x = x @=? D.parseLBS_ (D.renderLBS x) decodeEntities
    docs =
        [ Document (Prologue [] Nothing [])
                   (Element "foo" Map.empty [])
                   []
        , D.parseLBS_
            "<?xml version=\"1.0\"?>\n<!DOCTYPE foo>\n<foo/>"
            decodeEntities
        , D.parseLBS_
            "<?xml version=\"1.0\"?>\n<!DOCTYPE foo>\n<foo><nested>&ignore;</nested></foo>"
            decodeEntities
        , D.parseLBS_
            "<foo><![CDATA[this is some<CDATA content>]]></foo>"
            decodeEntities
        , D.parseLBS_
            "<foo bar='baz&amp;bin'/>"
            decodeEntities
        , D.parseLBS_
            "<foo><?instr this is a processing instruction?></foo>"
            decodeEntities
        , D.parseLBS_
            "<foo><!-- this is a comment --></foo>"
            decodeEntities
        ]

combinators = P.parseLBS_ input decodeEntities $ do
    P.force "need hello" $ P.tagName "hello" (P.requireAttr "world") $ \world -> do
        liftIO $ world @?= "true"
        P.force "need child1" $ P.tagNoAttr "{mynamespace}child1" $ return ()
        P.force "need child2" $ P.tagNoAttr "child2" $ return ()
        P.force "need child3" $ P.tagNoAttr "child3" $ do
            x <- P.contentMaybe
            liftIO $ x @?= Just "combine <all> &content"
  where
    input = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello world='true'>"
        , "<?this should be ignored?>"
        , "<child1 xmlns='mynamespace'/>"
        , "<!-- this should be ignored -->"
        , "<child2>   </child2>"
        , "<child3>combine &lt;all&gt; <![CDATA[&content]]></child3>\n"
        , "</hello>"
        ]

testIgnoreSiblings = P.parseLBS_ input decodeEntities $ do
    P.force "need hello" $ P.tagNoAttr "hello" $ do
        P.ignoreSiblings
        return ()
  where
    input = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<success/>"
        , "<ignore>"
        , "<nested>"
        , "<fail/>"
        , "</nested>"
        , "</ignore>\n"
        , "</hello>"
        ]

testChoose = P.parseLBS_ input decodeEntities $ do
    P.force "need hello" $ P.tagNoAttr "hello" $ do
        x <- P.choose
            [ P.tagNoAttr "failure" $ return 1
            , P.tagNoAttr "success" $ return 2
            ]
        liftIO $ x @?= Just 2
  where
    input = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<success/>"
        , "</hello>"
        ]

testMany = P.parseLBS_ input decodeEntities $ do
    P.force "need hello" $ P.tagNoAttr "hello" $ do
        x <- P.many $ P.tagNoAttr "success" $ return ()
        liftIO $ length x @?= 5
  where
    input = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<success/>"
        , "<success/>"
        , "<success/>"
        , "<success/>"
        , "<success/>"
        , "</hello>"
        ]

testOrE = P.parseLBS_ input decodeEntities $ do
    P.force "need hello" $ P.tagNoAttr "hello" $ do
        x <- P.tagNoAttr "failure" (return 1) `P.orE`
             P.tagNoAttr "success" (return 2)
        liftIO $ x @?= Just 2
  where
    input = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<success/>"
        , "</hello>"
        ]

testChooseSplit = P.parseLBS_ input decodeEntities $ do
    P.force "need hello" $ P.tagNoAttr "hello" $ do
        x <- P.chooseSplit (\t-> P.tagNoAttr t (return t)) ["a", "b", "c"]
        liftIO $ x @?= Just ("b",["a","c"])
  where
    input = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<b/>"
        , "</hello>"
        ]

testPermute 
    = do
        let frame input = P.parseLBS_ input decodeEntities $ do
                            P.force "need hello" $ P.tagNoAttr "hello" $ 
                             P.permute (\t -> P.tagNoAttr t (return t)) ["a", "b"]
        frame input1 >>= \result1 -> result1 @?= Just ["a", "b"]
        frame input2 >>= \result2 -> result2 @?= Just ["b", "a"]
        frame input3 >>= \result3 -> result3 @?= Nothing
        C.try (frame input4) >>= \result4 -> case result4 of
                                               Left (P.XmlException { 
                                                            P.xmlBadInput = Just (EventBeginElement 
                                                                                    Name { 
                                                                                      nameLocalName = "c"
                                                                                    , nameNamespace = Nothing
                                                                                    , namePrefix = Nothing 
                                                                                    }
                                                                                    _) 
                                                            }) -> return () -- right type of error
                                               Left  _ -> assertFailure "wrong error"
                                               Right _ -> assertFailure "erroneous document requires an error"
  where
    input1 = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<a/>"
        , "<b/>"
        , "</hello>"
        ]
    input2 = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<b/>"
        , "<a/>"
        , "</hello>"
        ]
    input3 = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<a/>"
        , "</hello>"
        ]
    input4 = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<a/>"
        , "<c/>"
        , "</hello>"
        ]

testPermuteFallback
    = do
        let frame input = P.parseLBS_ input decodeEntities $ do
                            P.force "need hello" $ P.tagNoAttr "hello" $ 
                             P.permuteFallback (fmap return `fmap` P.contentMaybe) 
                                               (\t -> P.tagNoAttr t (return $ nameLocalName t)) 
                                               ["a", "b"]
        frame input1 >>= \result1 -> result1 @?= Just ["a", "t", "b"]
        frame input2 >>= \result2 -> result2 @?= Just ["t", "b", "a"]
        frame input3 >>= \result3 -> result3 @?= Nothing
        C.try (frame input4) >>= \result4 -> case result4 of
                                               Left (P.XmlException { 
                                                            P.xmlBadInput = Just (EventBeginElement 
                                                                                    Name { 
                                                                                      nameLocalName = "c"
                                                                                    , nameNamespace = Nothing
                                                                                    , namePrefix = Nothing 
                                                                                    }
                                                                                    _) 
                                                            }) -> return () -- right type of error
                                               Left  _ -> assertFailure "wrong error"
                                               Right _ -> assertFailure "erroneous document requires an error"
  where
    input1 = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<a/>"
        , "t"
        , "<b/>"
        , "</hello>"
        ]
    input2 = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "t"
        , "<b/>"
        , "<a/>"
        , "</hello>"
        ]
    input3 = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<a/>"
        , "</hello>"
        ]
    input4 = L.concat
        [ "<?xml version='1.0'?>\n"
        , "<!DOCTYPE foo []>\n"
        , "<hello>"
        , "<a/>"
        , "<c/>"
        , "</hello>"
        ]
