{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
-- | Used for loading a catalog file, caching DTDs and applying DTDs to
-- documents.
module Text.XML.Catalog
    ( -- * Catalogs
      Catalog
    , PubSys (..)
    , loadCatalog
      -- * DTD caching
    , DTDCache
    , dcSchemeMap
    , newDTDCache
    , loadDTD
    , UnknownExternalID (..)
      -- * Applying DTDs
    , applyDTD
    ) where

import Prelude hiding (FilePath)
import qualified Data.Map as Map
import Data.Text (Text)
import qualified Text.XML as X
import Control.Monad (foldM)
import qualified Data.IORef as I
import Data.XML.DTD.Parse (parseDTD)
import qualified Data.XML.DTD.Types as D
import Control.Exception (Exception, throwIO)
import Data.Typeable (Typeable)
import Data.Maybe (mapMaybe)
import Network.URI.Enumerator
import Network.URI.Enumerator.File (toFilePath)
import Filesystem.Path.CurrentOS (encodeString)
import Data.Enumerator (run_, ($$))
--import Data.Enumerator.List (consume)
import Data.Text.Lazy.Encoding (decodeUtf8With)
import Data.Text.Encoding.Error (lenientDecode)
--import qualified Data.ByteString.Lazy as L
import qualified Data.ByteString.Lazy.Char8 as L8
import Control.Monad.IO.Class (MonadIO (liftIO))
import qualified Data.Text as T
--import System.Process (readProcess)
--import Control.Monad (liftM)
import Data.Attoparsec.Text.Enumerator (iterParser)

-- | Either a public or system identifier.
data PubSys = Public Text | System Text
    deriving (Eq, Show, Ord)

-- | An XML catalog, mapping public and system identifiers to filepaths.
type Catalog = Map.Map PubSys URI

-- | Load a 'Catalog' from the given path.
loadCatalog :: MonadIO m => SchemeMap m -> URI -> m Catalog
loadCatalog sm uri = do
    X.Document _ (X.Element _ _ ns) _ <- X.parseEnum_ X.def $ readURI sm uri
    foldM addNode Map.empty ns
  where
    addNode c (X.NodeElement (X.Element name as ns)) = do
        c'' <- c'
        foldM addNode c'' ns
      where
        -- FIXME handle hierarchies
        base =
            case lookup "{http://www.w3.org/XML/1998/namespace}base" as of
                Nothing -> ""
                Just x -> x
        withBase = T.append base

        c' =
            case name of
                "{urn:oasis:names:tc:entity:xmlns:xml:catalog}public" ->
                    case (lookup "publicId" as, lookup "uri" as) of
                        (Just pid, Just ref) ->
                            case parseURIReference (withBase ref) >>= flip relativeTo uri of
                                Just uri' -> return $ Map.insert (Public pid) uri' c
                                Nothing -> return c
                        _ -> return c
                "{urn:oasis:names:tc:entity:xmlns:xml:catalog}system" ->
                    case (lookup "systemId" as, lookup "uri" as) of
                        (Just sid, Just ref) ->
                            case parseURIReference (withBase ref) >>= flip relativeTo uri of
                                Just uri' -> return $ Map.insert (System sid) uri' c
                                Nothing -> return c
                        _ -> return c
                "{urn:oasis:names:tc:entity:xmlns:xml:catalog}nextCatalog" ->
                    case lookup "catalog" as of
                        Just catalog ->
                            case parseURIReference catalog >>= flip relativeTo uri of
                                Just uri' -> do
                                    c'' <- loadCatalog sm uri'
                                    return $ c'' `Map.union` c
                                Nothing -> return c
                        Nothing -> return c
                _ -> return c
    addNode c _ = return c

data DTDCache m = DTDCache
    { _dcCache :: I.IORef (Map.Map PubSys AttrMap)
    , _dcCatalog :: Catalog
    , dcSchemeMap :: SchemeMap m
    , _dcFlattenJar :: String
    }

newDTDCache :: MonadIO m => String -> Catalog -> SchemeMap m -> m (DTDCache m)
newDTDCache fj c sm = do
    x <- liftIO $ I.newIORef Map.empty
    return $ DTDCache x c sm fj

loadDTD :: MonadIO m => DTDCache m -> X.ExternalID -> m AttrMap
loadDTD (DTDCache icache catalog sm _flattenJar) ext = do
    res <- liftIO $ fmap (Map.lookup pubsys) $ I.readIORef icache
    case res of
        Just dtd -> return dtd
        Nothing ->
            case Map.lookup pubsys catalog of
                Nothing -> liftIO $ throwIO $ UnknownExternalID ext
                Just uri -> do
                    attLists <- liftIO $ run_ $ readURI sm uri $$ iterAttLists
                    let attrMap = toAttrs attLists
                    liftIO $ I.atomicModifyIORef icache $ \m ->
                        (Map.insert pubsys attrMap m, ())
                    return attrMap
  where
    pubsys =
        case ext of
            X.SystemID t -> System t
            X.PublicID t _ -> Public t

data UnknownExternalID = UnknownExternalID X.ExternalID
    deriving (Show, Typeable)
instance Exception UnknownExternalID

applyDTD :: MonadIO m
         => DTDCache m -> X.Document -> m X.Document
applyDTD dc doc@(X.Document pro@(X.Prologue _ mdoctype _) root epi) =
    case mdoctype of
        Just (X.Doctype _ (Just extid)) -> do
            attrs <- loadDTD dc extid
            let root' = go attrs root
            return $ X.Document pro root' epi
        _ -> return doc
  where
    go attrs (X.Element name as ns) =
        X.Element name as' ns'
      where
        as' =
            case Map.lookup name attrs of
                Nothing -> as
                Just x -> foldr goa as x
        ns' = map gon ns
        gon (X.NodeElement e) = X.NodeElement $ go attrs e
        gon n = n
    goa (name, Fixed t) as = (name, t) : filter (\(n, _) -> name /= n) as
    goa (name, Def t) as =
        case lookup name as of
            Nothing -> (name, t) : as
            Just _ -> as

data Att = Def Text | Fixed Text

type AttrMap = Map.Map X.Name [(X.Name, Att)]

toAttrs :: D.DTD -> AttrMap
toAttrs (D.DTD _ comps) =
    Map.fromList $ mapMaybe go comps
  where
    go (D.DTDAttList (D.AttList lname atts)) = Just $ (X.Name lname Nothing Nothing, mapMaybe go' atts)
    go _ = Nothing
    go' (D.AttDecl lname _ def) =
        case def of
            D.AttFixed t -> Just (name, Fixed t)
            D.AttDefaultValue t -> Just (name, Def t)
            _ -> Nothing
      where
        name = X.Name lname Nothing Nothing

iterAttLists :: Iteratee Text m 
