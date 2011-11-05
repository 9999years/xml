{-# LANGUAGE FlexibleInstances, OverloadedStrings #-}
module Main where

import Data.List (isPrefixOf)
import Control.Applicative
import Test.Framework (defaultMain, testGroup, Test)
import Test.Framework.Providers.HUnit
import Test.Framework.Providers.QuickCheck2
import Test.HUnit hiding (Test)
import Test.QuickCheck
import Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as S
import Text.HTML.TagStream
import qualified Data.Enumerator as E
import qualified Data.Enumerator.List as EL

main :: IO ()
main = defaultMain
         [ testGroup "Property"
             [ testProperty "Text nodes can't be empty" propTextNotEmpty
             , testProperty "Parse results can't empty" propResultNotEmpty
             ]
         , testGroup "One pass parse" onePassTests
         , testGroup "Streamline parse" streamlineTests
         ]

propTextNotEmpty :: ByteString -> Bool
propTextNotEmpty = either (const False) text_not_empty . decode
  where text_not_empty = all not_empty
        not_empty (Text s) = S.length s > 0
        not_empty _ = True

propResultNotEmpty :: ByteString -> Bool
propResultNotEmpty s = either (const False) not_empty . decode $ s
  where not_empty tokens = (S.null s && null tokens)
                        || (not (S.null s) && not (null tokens))

onePassTests :: [Test]
onePassTests = map one testcases
  where
    one (str, tokens) = testCase (S.unpack str) $ do
        result <- combineText <$> assertDecode str
        assertEqual "one-pass parse result incorrent" tokens result

streamlineTests :: [Test]
streamlineTests = map one testcases
  where
    one (str, tokens) = testCase (S.unpack str) $ do
        result <- combineText <$> E.run_ (
                      E.enumList 1 (map S.singleton (S.unpack str))
                      E.$= tokenStream
                      E.$$ EL.consume )
        let msg = "expected prefix of:" ++ show tokens ++ "\n but got: " ++ show result
        assertBool msg (result `isPrefixOf` tokens)
        -- print $ (result, tokens)

testcases :: [(ByteString, [Token])]
testcases =
  -- attributes {{{
  [ ( "<span readonly title=foo class=\"foo bar\" style='display:none;'>"
    , [TagOpen "span" [("readonly", ""), ("title", "foo"), ("class", "foo bar"), ("style", "display:none;")] False]
    )
  , ( "<span a = b = c = d>"
    , [TagOpen "span" [("a", "b"), ("=", ""), ("c", "d")] False]
    )
  , ( "<span a = b = c>"
    , [TagOpen "span" [("a", "b"), ("=", ""), ("c", "")] False]
    )
  , ( "<span /foo=bar>"
    , [TagOpen "span" [("/foo", "bar")] False]
    )
  -- }}}
  -- quoted string and escaping {{{
  , ( "<span \"<p>xx \\\"'\\\\</p>\"=\"<p>xx \\\"'\\\\</p>\">"
    , [TagOpen "span" [("<p>xx \"'\\</p>", "<p>xx \"'\\</p>")] False]
    )
  , ( "<span '<p>xx \\\"\\'\\\\</p>'='<p>xx \\\"\\'\\\\</p>'>"
    , [TagOpen "span" [("<p>xx \"'\\</p>", "<p>xx \"'\\</p>")] False]
    )
  -- }}}
  -- attribute and tag end {{{
  , ( "<br/>"
    , [TagOpen "br" [] True]
    )
  , ( "<img src=http://foo.bar.com/foo.jpg />"
    , [TagOpen "img" [("src", "http://foo.bar.com/foo.jpg")] True]
    )
  , ( "<span foo>"
    , [TagOpen "span" [("foo", "")] False]
    )
  , ( "<span foo/>"
    , [TagOpen "span" [("foo", "")] True]
    )
  , ( "<span foo=/>"
    , [TagOpen "span" [("foo", "/")] False]
    )
  -- }}}
  -- normal tag {{{
  , ( "<p>text</p>"
    , [TagOpen "p" [] False, Text "text", TagClose "p"]
    )
  , ( "<>"
    , [TagOpen "" [] False]
    )
  , ( "<a\ttitle\n=\r\"foo\nbar\" alt=\n/\r\t>"
    , [TagOpen "a" [("title", "foo\nbar"), ("alt", "/")] False]
    )
  -- }}}
  -- comment tag {{{
  , ( "<!--foo-->"
    , [Comment "foo"] )
  , ( "<!--f--oo->-->"
    , [Comment "f--oo->"] )
  , ( "<!--foo-->bar-->"
    , [Comment "foo", Text "bar-->"]
    )
  -- }}}
  -- special tag {{{
  , ( "<!DOCTYPE html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\">"
    , [Special "DOCTYPE" "html PUBLIC \"-//W3C//DTD XHTML 1.0 Transitional//EN\""]
    )
  , ( "<!DOCTYPE html>"
    , [Special "DOCTYPE" "html"]
    )
  -- }}}
  -- close tag {{{
  , ( "</\r\t\nbr>"
    , [TagClose "\r\t\nbr"]
    )
  , ( "</br/>"
    , [TagClose "br/"]
    )
  , ( "</>"
    , [TagClose ""]
    )
  -- }}}
  -- incomplete test {{{
  -- }}}
  -- script tag TODO{{{
  -- }}}
  ]

atLeast :: Arbitrary a => Int -> Gen [a]
atLeast 0 = arbitrary
atLeast n = (:) <$> arbitrary <*> atLeast (n-1)

testChar :: Gen Char
testChar = growingElements "<>/=\"' \t\r\nabcde\\"
testString :: Gen String
testString = listOf testChar
testBS :: Gen ByteString
testBS = S.pack <$> testString

instance Arbitrary ByteString where
    arbitrary = testBS

instance Arbitrary (Token' ByteString) where
    arbitrary = oneof [ TagOpen <$> arbitrary <*> arbitrary <*> arbitrary
                      , TagClose <$> arbitrary
                      , Text <$> S.pack <$> atLeast 1
                      ]

assertEither :: Either String a -> Assertion
assertEither = either (assertFailure . ("Left:"++)) (const $ return ())

assertDecode :: ByteString -> IO [Token]
assertDecode s = do
    let result = decode s
    assertEither result
    let (Right tokens) = result
    return tokens

combineText :: [Token] -> [Token]
combineText [] = []
combineText ((Text t1) : (Text t2) : xs) = combineText $ Text (S.append t1 t2) : xs
combineText (x:xs) = x:combineText xs

testRealworldFiles :: Assertion
testRealworldFiles = mapM_ testFile files
  where
    testFile file = do
        result <- S.readFile file >>= assertDecode
        result' <- assertDecode $ encode result
        assertEqual "not equal" result result'
    files = [ "qq.html"
            ]
