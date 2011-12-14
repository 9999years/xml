{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleContexts #-}
-- | 'Enumeratee's to render XML 'Event's. Unlike libxml-enumerator and
-- expat-enumerator, this module does not provide IO and ST variants, since the
-- underlying rendering operations are pure functions.
module Text.XML.Stream.Render
    ( renderBuilder
    , renderBytes
    , renderText
    , RenderSettings
    , def
    , rsPretty
    , prettify
    ) where

import Data.XML.Types (Event (..), Content (..), Name (..))
import Text.XML.Stream.Token
import qualified Data.Text as T
import Data.Text (Text)
import Blaze.ByteString.Builder
import Data.Conduit.Blaze (builderToByteString)
import qualified Data.Map as Map
import Data.Map (Map)
import Data.Maybe (fromMaybe)
import Data.ByteString (ByteString)
import Data.Char (isSpace)
import Data.Default (Default (def))
import qualified Data.Set as Set
import Data.List (foldl')
import qualified Data.Conduit as C
import qualified Data.Conduit.Text as CT
import Data.Monoid (mconcat)

-- | Render a stream of 'Event's into a stream of 'ByteString's. This function
-- wraps around 'renderBuilder' and 'builderToByteString', so it produces
-- optimally sized 'ByteString's with minimal buffer copying.
--
-- The output is UTF8 encoded.
renderBytes :: C.MonadBaseControl IO m => RenderSettings -> C.ConduitM Event m ByteString
renderBytes rs = renderBuilder rs C.<=$=> builderToByteString

-- | Render a stream of 'Event's into a stream of 'ByteString's. This function
-- wraps around 'renderBuilder', 'builderToByteString' and 'renderBytes', so it
-- produces optimally sized 'ByteString's with minimal buffer copying.
renderText :: C.MonadBaseControl IO m => RenderSettings -> C.ConduitM Event m Text
renderText rs = renderBytes rs C.<=$=> CT.decode CT.utf8

data RenderSettings = RenderSettings
    { rsPretty :: Bool
    }

instance Default RenderSettings where
    def = RenderSettings
        { rsPretty = False
        }

-- | Render a stream of 'Event's into a stream of 'Builder's. Builders are from
-- the blaze-builder package, and allow the create of optimally sized
-- 'ByteString's with minimal buffer copying.
renderBuilder :: C.MonadBaseControl IO m => RenderSettings -> C.ConduitM Event m Builder
renderBuilder RenderSettings { rsPretty = True } = prettify C.<=$=> renderBuilder'
renderBuilder RenderSettings { rsPretty = False } = renderBuilder'

renderBuilder' :: C.MonadBaseControl IO m => C.ConduitM Event m Builder
renderBuilder' = C.conduitMState
    []
    push
    close
  where
    go' front = map tokenToBuilder $ front []
    go stack _ [] front = (stack, [], go' front)
    -- we want to wait and see if the next event is the matching end
    go stack False [e@EventBeginElement{}] front = (stack, [e], go' front)
    go stack atEnd
        ( EventBeginElement n1 as
        : EventEndElement n2
        : rest
        ) front | n1 == n2 =
            let (token, stack') = mkBeginToken False True stack n1 as
             in go stack' atEnd rest (front . token)
    go stack atEnd (EventBeginElement name as:rest) front =
        let (token, stack') = mkBeginToken False False stack name as
         in go stack' atEnd rest (front . token)
    go stack atEnd (e:rest) front =
        let (token, stack') = eventToToken stack e
         in go stack' atEnd rest (front . token)

    push stack es =
        return (stack', C.ConduitResult C.StreamOpen leftover ts)
      where
        (stack', leftover, ts) = go stack False es id

    close stack es =
        return $ C.ConduitCloseResult leftover ts
      where
        (_, leftover, ts) = go stack True es id
{-
    loop []
  where
    loop stack = E.checkDone $ step stack
    step stack k = do
        x <- EL.head
        case x of
            Nothing -> E.yield (E.Continue k) E.EOF
            Just (EventBeginElement name as) -> do
                x' <- E.peek
                if x' == Just (EventEndElement name)
                    then do
                        EL.drop 1
                        go $ mkBeginToken False True stack name as
                    else go $ mkBeginToken False False stack name as
            Just e -> go $ eventToToken stack e
      where
        go (ts, stack') = k (E.Chunks $ map tokenToBuilder $ ts []) >>== loop stack'
-}

eventToToken :: Stack -> Event -> ([Token] -> [Token], [NSLevel])
eventToToken s EventBeginDocument =
    ((:) (TokenBeginDocument
            [ ("version", [ContentText "1.0"])
            , ("encoding", [ContentText "UTF-8"])
            ])
     , s)
eventToToken s EventEndDocument = (id, s)
eventToToken s (EventInstruction i) = ((:) (TokenInstruction i), s)
eventToToken s (EventBeginDoctype n meid) = ((:) (TokenDoctype n meid), s)
eventToToken s EventEndDoctype = (id, s)
eventToToken s (EventCDATA t) = ((:) (TokenCDATA t), s)
eventToToken s (EventEndElement name) =
    ((:) (TokenEndElement $ nameToTName sl name), s')
  where
    (sl:s') = s
eventToToken s (EventContent c) = ((:) (TokenContent c), s)
eventToToken s (EventComment t) = ((:) (TokenComment t), s)
eventToToken _ EventBeginElement{} = error "eventToToken on EventBeginElement" -- mkBeginToken False s name attrs

type Stack = [NSLevel]

nameToTName :: NSLevel -> Name -> TName
nameToTName _ (Name name _ (Just pref))
    | pref == "xml" = TName (Just "xml") name
nameToTName _ (Name name Nothing _) = TName Nothing name -- invariant that this is true
nameToTName (NSLevel def' sl) (Name name (Just ns) _)
    | def' == Just ns = TName Nothing name
    | otherwise =
        case Map.lookup ns sl of
            Nothing -> error "nameToTName"
            Just pref -> TName (Just pref) name

mkBeginToken :: Bool -- ^ pretty print attributes?
             -> Bool -> Stack -> Name -> [(Name, [Content])]
             -> ([Token] -> [Token], Stack)
mkBeginToken isPretty isClosed s name attrs =
    ((:) (TokenBeginElement tname tattrs2 isClosed indent),
     if isClosed then s else sl2 : s)
  where
    indent = if isPretty then 2 + 4 * length s else 0
    prevsl = case s of
                [] -> NSLevel Nothing Map.empty
                sl':_ -> sl'
    (sl1, tname, tattrs1) = newElemStack prevsl name
    (sl2, tattrs2) = foldr newAttrStack (sl1, tattrs1) $ nubAttrs attrs

newElemStack :: NSLevel -> Name -> (NSLevel, TName, [TAttribute])
newElemStack nsl@(NSLevel def' _) (Name local ns _)
    | def' == ns = (nsl, TName Nothing local, [])
newElemStack (NSLevel _ nsmap) (Name local Nothing _) =
    (NSLevel Nothing nsmap, TName Nothing local, [(TName Nothing "xmlns", [])])
newElemStack (NSLevel _ nsmap) (Name local (Just ns) Nothing) =
    (NSLevel (Just ns) nsmap, TName Nothing local, [(TName Nothing "xmlns", [ContentText ns])])
newElemStack (NSLevel def' nsmap) (Name local (Just ns) (Just pref)) =
    case Map.lookup ns nsmap of
        Just pref'
            | pref == pref' ->
                ( NSLevel def' nsmap
                , TName (Just pref) local
                , []
                )
        _ -> ( NSLevel def' nsmap'
             , TName (Just pref) local
             , [(TName (Just "xmlns") pref, [ContentText ns])]
             )
  where
    nsmap' = Map.insert ns pref nsmap

newAttrStack :: (Name, [Content]) -> (NSLevel, [TAttribute]) -> (NSLevel, [TAttribute])
newAttrStack (name, value) (NSLevel def' nsmap, attrs) =
    (NSLevel def' nsmap', addNS $ (tname, value) : attrs)
  where
    (nsmap', tname, addNS) =
        case name of
            Name local Nothing _ -> (nsmap, TName Nothing local, id)
            Name local (Just ns) mpref ->
                let ppref = fromMaybe "ns" mpref
                    (pref, addNS') = getPrefix ppref nsmap ns
                 in (Map.insert ns pref nsmap, TName (Just pref) local, addNS')

getPrefix :: Text -> Map Text Text -> Text -> (Text, [TAttribute] -> [TAttribute])
getPrefix _ _ "http://www.w3.org/XML/1998/namespace" = ("xml", id)
getPrefix ppref nsmap ns =
    case Map.lookup ns nsmap of
        Just pref -> (pref, id)
        Nothing ->
            let pref = findUnused ppref $ Map.elems nsmap
             in (pref, (:) (TName (Just "xmlns") pref, [ContentText ns]))
  where
    findUnused x xs
        | x `elem` xs = findUnused (x `T.snoc` '_') xs
        | otherwise = x

-- | Convert a stream of 'Event's into a prettified one, adding extra
-- whitespace. Note that this can change the meaning of your XML.
prettify :: C.MonadBaseControl IO m => C.ConduitM Event m Event
prettify = prettify' 0 []

prettify' :: C.MonadBaseControl IO m => Int -> [Name] -> C.ConduitM Event m Event
prettify' level names = error "prettify'" {-(Continue k) = do
    mx <- eventHead
    case mx of
        Nothing -> return $ Continue k
        Just x -> do
            y <- E.peek
            (chunks, level', names') <-
                case (x, y) of
                    (Left contents, _) -> do
                        let es = map EventContent $ cleanWhite contents
                        let es' = if null es
                                    then []
                                    else before level : es ++ [after]
                        return (es', level, names)
                    (Right (EventBeginElement name attrs), Just (EventEndElement _)) -> do
                        EL.drop 1
                        return ([before level, EventBeginElement name attrs, EventEndElement name, after], level, names)
                    (Right (EventBeginElement name attrs), _) ->
                        return ([before level, EventBeginElement name attrs, after], level + 1, name : names)
                    (Right (EventEndElement _), _) -> do
                        let newLevel = level - 1
                        return ([before newLevel, EventEndElement $ head names, after], newLevel, tail names)
                    (Right EventBeginDocument, _) -> do
                        return ([EventBeginDocument], level, names)
                    (Right EventEndDocument, _) -> do
                        return ([EventEndDocument, after], level, names)
                    (Right (EventComment t), _) -> do
                        return ([before level, EventComment $ T.map normalSpace t, after], level, names)
                    (Right e, _) -> do
                        return ([before level, e, after], level, names)
            k (E.Chunks chunks) >>== prettify' level' names'
  where
    before l = EventContent $ ContentText $ T.replicate l "    "
    after = EventContent $ ContentText "\n"
prettify' _ _ step = return step
-}

eventHead :: C.MonadBaseControl IO m => C.SinkM Event m (Maybe (Either [Content] Event))
eventHead = error "eventHead" {-do
    x <- EL.head
    case x of
        Just (EventContent e) -> do
            es <- takeContents id
            return $ Just $ Left $ e : es
        Nothing -> return Nothing
        Just e -> return $ Just $ Right e
        -}

takeContents :: C.MonadBaseControl IO m => ([Content] -> [Content]) -> C.SinkM Event m [Content]
takeContents front = error "takeContents" {-do
    x <- E.peek
    case x of
        Just (EventContent e) -> do
            EL.drop 1
            takeContents $ front . (:) e
        _ -> return $ front []
        -}

normalSpace :: Char -> Char
normalSpace c
    | isSpace c = ' '
    | otherwise = c

cleanWhite :: [Content] -> [Content]
cleanWhite x =
    go True [] $ go True [] x
  where
    go _ end (ContentEntity e:rest) = go False (ContentEntity e : end) rest
    go isFront end (ContentText t:rest) =
        if T.null t'
            then go isFront end rest
            else go False (ContentText t' : end) rest
      where
        t' = (if isFront then T.dropWhile isSpace else id) $ T.map normalSpace t
    go _ end [] = end

nubAttrs :: [(Name, v)] -> [(Name, v)]
nubAttrs orig =
    front []
  where
    (front, _) = foldl' go (id, Set.empty) orig
    go (dlist, used) (k, v)
        | k `Set.member` used = (dlist, used)
        | otherwise = (dlist . ((k, v):), Set.insert k used)
