{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE DeriveDataTypeable #-}
-- | Used for loading a catalog file, caching DTDs and applying DTDs to
-- documents.
module Text.XML.Catalog
    ( -- * Catalogs
      Catalog
    , PubSys (..)
    , loadCatalog
    ) where

import Prelude hiding (FilePath)
import qualified Data.Map as Map
import Data.Text (Text)
import qualified Text.XML as X
import Control.Monad (foldM)
import Network.URI.Enumerator
import qualified Data.Text as T
import Control.Monad.IO.Class (MonadIO)

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
