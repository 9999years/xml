{-# OPTIONS_GHC -fno-warn-orphans #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE CPP #-}
module Text.XML.Xml2Html () where

#if MIN_VERSION_blaze_html(0, 5, 0)
import qualified Text.XML as X
import qualified Text.Blaze as B
import qualified Text.Blaze.Html as B
import qualified Text.Blaze.Html5 as B5
import qualified Text.Blaze.Internal as BI
#define ToHtml ToMarkup
#define toHtml toMarkup
#else
import qualified Text.XML as X
import qualified Text.Blaze as B
import qualified Text.Blaze.Html5 as B5
import qualified Text.Blaze.Internal as BI
#endif
import qualified Data.Text as T
import Data.String (fromString)
import Data.Monoid (mempty, mappend)
import Data.List (foldl')
import qualified Data.Set as Set
import qualified Data.Map as Map
import Control.Arrow (first)

preEscapedText :: T.Text -> B.Html
preEscapedText =
#if MIN_VERSION_blaze_html(0, 5, 0)
    B.preEscapedToMarkup
#else
    B.preEscapedText
#endif

instance B.ToHtml X.Document where
    toHtml (X.Document _ root _) = B5.docType >> B.toHtml root

instance B.ToHtml X.Element where
    toHtml (X.Element
                "{http://www.snoyman.com/xml2html}ie-cond"
                [("cond", cond)]
                children) =
        preEscapedText "<!--[if "
        `mappend` preEscapedText cond
        `mappend` preEscapedText "]>"
        `mappend` mapM_ B.toHtml children
        `mappend` preEscapedText "<![endif]-->"

    toHtml (X.Element name' attrs children) =
        if isVoid
            then foldl' (B.!) leaf attrs'
            else foldl' (B.!) parent attrs' childrenHtml
      where
        childrenHtml :: B.Html
        childrenHtml =
            case (name `elem` ["style", "script"], children) of
                (True, [X.NodeContent t]) -> preEscapedText t
                _ -> mapM_ B.toHtml children

        isVoid = X.nameLocalName name' `Set.member` voidElems

        parent :: B.Html -> B.Html
        parent = BI.Parent tag open close
        leaf :: B.Html
        leaf = BI.Leaf tag open (fromString " />")

        name = T.unpack $ X.nameLocalName name'
        tag = fromString name
        open = fromString $ '<' : name
        close = fromString $ concat ["</", name, ">"]

        attrs' :: [B.Attribute]
        attrs' = map goAttr $ Map.toList $ Map.fromList $ map (first X.nameLocalName) attrs
        goAttr (key, value) = B.customAttribute (B.textTag key) $ B.toValue value

instance B.ToHtml X.Node where
    toHtml (X.NodeElement e) = B.toHtml e
    toHtml (X.NodeContent t) = B.toHtml t
    toHtml _ = mempty

voidElems :: Set.Set T.Text
voidElems = Set.fromAscList $ T.words $ T.pack "area base br col command embed hr img input keygen link meta param source track wbr"
