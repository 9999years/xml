{-# LANGUAGE OverloadedStrings #-}
module Text.XML.Enumerator.Token
    ( tokenToBuilder
    , TName (..)
    , Token (..)
    , TAttribute
    , NSLevel (..)
    ) where

import Data.XML.Types (Instruction (..), Content (..), ExternalID (..))
import qualified Data.Text as T
import Data.Text (Text)
import Data.String (IsString (fromString))
import Blaze.ByteString.Builder
    (Builder, fromByteString, writeByteString, copyByteString)
import Blaze.ByteString.Builder.Internal.Write (fromWriteList)
import Blaze.ByteString.Builder.Char.Utf8 (writeChar, fromText)
import Data.Monoid (mconcat, mempty, mappend)
import Data.ByteString.Char8 ()
import Data.Map (Map)
import qualified Blaze.ByteString.Builder.Char8 as BC8

oneSpace :: Builder
oneSpace = copyByteString " "

data Token = TokenBeginDocument [TAttribute]
           | TokenInstruction Instruction
           | TokenBeginElement TName [TAttribute] Bool Int -- ^ indent
           | TokenEndElement TName
           | TokenContent Content
           | TokenComment Text
           | TokenDoctype Text (Maybe ExternalID)
           | TokenCDATA Text
    deriving Show
tokenToBuilder :: Token -> Builder
tokenToBuilder (TokenBeginDocument attrs) =
    mconcat $ fromByteString "<?xml"
        : foldAttrs oneSpace attrs [fromByteString "?>\n"]
tokenToBuilder (TokenInstruction (Instruction target data_)) = mconcat
    [ fromByteString "<?"
    , fromText target
    , fromByteString " "
    , fromText data_
    , fromByteString "?>"
    ]
tokenToBuilder (TokenBeginElement name attrs isEmpty indent) = mconcat
    $ fromByteString "<"
    : tnameToText name
    : foldAttrs
        (if indent == 0 || lessThan3 attrs
            then oneSpace
            else BC8.fromString ('\n' : replicate indent ' '))
        attrs
    [ if isEmpty then fromByteString "/>" else fromByteString ">"
    ]
  where
    lessThan3 [] = True
    lessThan3 [_] = True
    lessThan3 [_, _] = True
    lessThan3 _ = False
tokenToBuilder (TokenEndElement name) = mconcat
    [ fromByteString "</"
    , tnameToText name
    , fromByteString ">"
    ]
tokenToBuilder (TokenContent c) = contentToText c
tokenToBuilder (TokenCDATA t) =
    copyByteString "<![CDATA["
    `mappend` fromText t
    `mappend` copyByteString "]]>"
tokenToBuilder (TokenComment t) = mconcat [fromByteString "<!--", fromText t, fromByteString "-->"]
tokenToBuilder (TokenDoctype name eid) = mconcat
    [ fromByteString "<!DOCTYPE "
    , fromText name
    , go eid
    , fromByteString ">\n"
    ]
  where
    go Nothing = mempty
    go (Just (SystemID uri)) = mconcat
        [ fromByteString " SYSTEM \""
        , fromText uri
        , fromByteString "\""
        ]
    go (Just (PublicID pid uri)) = mconcat
        [ fromByteString " PUBLIC \""
        , fromText pid
        , fromByteString "\" \""
        , fromText uri
        , fromByteString "\""
        ]

data TName = TName (Maybe Text) Text
    deriving Show

tnameToText :: TName -> Builder
tnameToText (TName Nothing name) = fromText name
tnameToText (TName (Just prefix) name) = mconcat [fromText prefix, fromByteString ":", fromText name]

contentToText :: Content -> Builder
contentToText (ContentText t) =
    fromWriteList go $ T.unpack t
  where
    go '<' = writeByteString "&lt;"
    go '>' = writeByteString "&gt;"
    go '&' = writeByteString "&amp;"
    -- Not escaping quotes, since this is only called outside of attributes
    go c   = writeChar c
contentToText (ContentEntity e) = mconcat
    [ fromByteString "&"
    , fromText e
    , fromByteString ";"
    ]

type TAttribute = (TName, [Content])

foldAttrs :: Builder -- ^ before
          -> [TAttribute] -> [Builder] -> [Builder]
foldAttrs before attrs rest' =
    foldr go rest' attrs
  where
    go (key, val) rest =
        before
      : tnameToText key
      : fromByteString "=\""
      : foldr go' (fromByteString "\"" : rest) val
    go' (ContentText t) rest =
        fromWriteList h (T.unpack t) : rest
      where
        h '<' = writeByteString "&lt;"
        h '>' = writeByteString "&gt;"
        h '&' = writeByteString "&amp;"
        h '"' = writeByteString "&quot;"
        -- Not escaping single quotes, since our attributes are always double
        -- quoted
        h c   = writeChar c
    go' (ContentEntity t) rest =
        fromByteString "&" : fromText t : fromByteString ";" : rest

instance IsString TName where
    fromString = TName Nothing . T.pack

data NSLevel = NSLevel
    { defaultNS :: Maybe Text
    , prefixes :: Map Text Text
    }
    deriving Show
