module Text.XML.Enumerator.Cursor
    (
      Boolean(..)
    , Axis
    , Cursor
    , fromDocument
    , fromNode
    , cut
    , parent
    , precedingSibling
    , followingSibling
    , child
    , node
    , preceding
    , following
    , ancestor
    , descendant
    , orSelf
    , (./)
    , (.//)
    , (..//)
    , ($|)
    , ($/)
    , ($//)
    , ($.//)
    , check
    , checkNode
    , checkElement
    , checkName
    , anyElement
    , element
    , content
    , attribute
    , (>=>)
    ) where

import Data.XML.Types
import Control.Monad
import Data.List (foldl')

-- TODO: Consider [Cursor] -> [Cursor]?
-- | The type of an Axis that returns a list of Cursors.
-- They are roughly modeled after <http://www.w3.org/TR/xpath/#axes>.
-- 
-- Axes can be composed with '>=>', where e.g. @f >=> g@ means that on all results of
-- the @f@ axis, the @g@ axis will be applied, and all results joined together. 
-- Because Axis is just a type synonym for @Cursor -> [Cursor]@, it is possible to use
-- other standard functions like '>>=' or 'concatMap' similarly.
-- 
-- The operators './', './/' and '..//' can be used to combine axes so that the second
-- axis works on the children, descendants, respectively the context node as well as its
-- descendants of the results of the first axis.
-- 
-- The operators '$|', '$/', '$//' and '$.//' can be used to apply an axis (right-hand side)
-- to a cursor so that it is applied on the cursor itself, its children, its descendants,
-- respectively itself and its descendants.
-- 
-- Note that many of these operators also work on /generalised Axes/ that can return 
-- lists of something other than Cursors, for example Content elements.
type Axis = Cursor -> [Cursor]

-- XPath axes as in http://www.w3.org/TR/xpath/#axes

type DiffCursor = [Cursor] -> [Cursor]

-- TODO: Decide whether to use an existing package for this
-- | Something that can be used in a predicate check as a "boolean".
class Boolean a where
    bool :: a -> Bool

instance Boolean Bool where 
    bool = id
instance Boolean [a] where 
    bool = not . null
instance Boolean (Maybe a) where 
    bool (Just _) = True
    bool _        = False
instance Boolean (Either a b) where
    bool (Left _)  = False
    bool (Right _) = True

-- | A cursor: contains an XML 'Node' and pointers to its children, ancestors and siblings.
data Cursor = Cursor
    { parent' :: Maybe Cursor
    , precedingSibling' :: DiffCursor
    , followingSibling' :: DiffCursor
    -- | The child axis. XPath:
    -- /the child axis contains the children of the context node/.
    , child :: [Cursor]
    -- | The current node.
    , node :: Node
    }

instance Show Cursor where
    show Cursor { node = n } = "Cursor @ " ++ show n

-- | Cut a cursor off from its parent. The idea is to allow restricting the scope of queries on it.
cut :: Cursor -> Cursor
cut c = c { parent' = Nothing, precedingSibling' = id, followingSibling' = id }

-- | The parent axis. As described in XPath:
-- /the parent axis contains the parent of the context node, if there is one/.
parent :: Axis
parent c = case parent' c of
             Nothing -> []
             Just p -> [p]

-- | The preceding-sibling axis. XPath:
-- /the preceding-sibling axis contains all the preceding siblings of the context node [...]/.
precedingSibling :: Axis
precedingSibling = ($ []) . precedingSibling'

-- | The following-sibling axis. XPath:
-- /the following-sibling axis contains all the following siblings of the context node [...]/.
followingSibling :: Axis
followingSibling = ($ []) . followingSibling'

-- | Convert a 'Document' to a 'Cursor'. It will point to the document root.
fromDocument :: Document -> Cursor
fromDocument = fromNode . NodeElement . documentRoot

-- | Convert a 'Node' to a 'Cursor' (without parents).
fromNode :: Node -> Cursor
fromNode = toCursor' Nothing id id

toCursor' :: Maybe Cursor -> DiffCursor -> DiffCursor -> Node -> Cursor
toCursor' par pre fol n =
    me
  where
    me = Cursor par pre fol chi n
    chi' =
        case n of
            NodeElement (Element _ _ x) -> x
            _ -> []
    chi = go id chi' []
    go _ [] = id
    go pre' (n':ns') =
        (:) me' . fol'
      where
        me' = toCursor' (Just me) pre' fol' n'
        fol' = go (pre' . (:) me') ns'

-- | The preceding axis. XPath:
-- /the preceding axis contains all nodes in the same document as the context node that are before the context node in document order, excluding any ancestors and excluding attribute nodes and namespace nodes/.
preceding :: Axis
preceding c =
    go (precedingSibling' c []) (parent c >>= preceding)
  where
    go x y = foldl' (\b a -> go' a b) y x
    go' :: Cursor -> DiffCursor
    go' x rest = foldl' (\b a -> go' a b) (x : rest) (child x)

-- | The following axis. XPath:
-- /the following axis contains all nodes in the same document as the context node that are after the context node in document order, excluding any descendants and excluding attribute nodes and namespace nodes/.
following :: Axis
following c =
    go (followingSibling' c) (parent c >>= following)
  where
    go x z =
        foldr (\a b -> go' a b) z y
      where
        y = x []
    go' :: Cursor -> DiffCursor
    go' x rest = x : foldr (\a b -> go' a b) rest (child x)

-- | The ancestor axis. XPath:
-- /the ancestor axis contains the ancestors of the context node; the ancestors of the context node consist of the parent of context node and the parent's parent and so on; thus, the ancestor axis will always include the root node, unless the context node is the root node/.
ancestor :: Axis
ancestor = parent >=> (\p -> p : ancestor p)

-- | The descendant axis. XPath:
-- /the descendant axis contains the descendants of the context node; a descendant is a child or a child of a child and so on; thus the descendant axis never contains attribute or namespace nodes/.
descendant :: Axis
descendant = child >=> (\c -> c : descendant c)

-- | Modify an axis by adding the context node itself as the first element of the result list.
orSelf :: Axis -> Axis
orSelf ax c = c : ax c

infixr 1 ./ 
infixr 1 .// 
infixr 1 ..// 
infixr 1 $|
infixr 1 $/
infixr 1 $//
infixr 1 $.//

-- | Combine two axes so that the second works on the children of the results
-- of the first.
(./) :: Axis -> (Cursor -> [a]) -> (Cursor -> [a])
f ./ g = f >=> child >=> g

-- | Combine two axes so that the second works on the descendants of the results
-- of the first.
(.//) :: Axis -> (Cursor -> [a]) -> (Cursor -> [a])
f .// g = f >=> descendant >=> g

-- | Combine two axes so that the second works on both the result nodes, and their
-- descendants.
(..//) :: Axis -> (Cursor -> [a]) -> (Cursor -> [a])
f ..// g = f >=> orSelf descendant >=> g

-- | Apply an axis to a 'Cursor'.
($|) :: Cursor -> (Cursor -> [a]) -> [a]
v $| f = f v

-- | Apply an axis to the children of a 'Cursor'.
($/) :: Cursor -> (Cursor -> [a]) -> [a]
v $/ f = child v >>= f

-- | Apply an axis to the descendants of a 'Cursor'.
($//) :: Cursor -> (Cursor -> [a]) -> [a]
v $// f = descendant v >>= f

-- | Apply an axis to a 'Cursor' as well as its descendants.
($.//) :: Cursor -> (Cursor -> [a]) -> [a]
v $.// f = orSelf descendant v >>= f

-- | Filter cursors that don't pass a check.
check :: Boolean b => (Cursor -> b) -> Axis
check f c = case bool $ f c of
              False -> []
              True -> [c]

-- | Filter nodes that don't pass a check.
checkNode :: Boolean b => (Node -> b) -> Axis
checkNode f c = check (f . node) c

-- | Filter elements that don't pass a check, and remove all non-elements.
checkElement :: Boolean b => (Element -> b) -> Axis
checkElement f c = case node c of
                     NodeElement e -> case bool $ f e of
                                        True -> [c]
                                        False -> []
                     _ -> []

-- | Filter elements that don't pass a name check, and remove all non-elements.
checkName :: Boolean b => (Name -> b) -> Axis
checkName f c = checkElement (f . elementName) c

-- | Remove all non-elements. Compare roughly to XPath:
-- /A node test * is true for any node of the principal node type. For example, child::* will select all element children of the context node [...]/.
anyElement :: Axis
anyElement = checkElement (const True)

-- | Select only those elements with a matching tag name. XPath:
-- /A node test that is a QName is true if and only if the type of the node (see [5 Data Model]) is the principal node type and has an expanded-name equal to the expanded-name specified by the QName./
element :: Name -> Axis
element n = checkName (== n)

-- | Select only text nodes, and directly give the 'Content' values. XPath:
-- /The node test text() is true for any text node./
-- 
-- Note that this is not strictly an 'Axis', but will work with most combinators.
content :: Cursor -> [Content]
content c = case node c of
              (NodeContent v) -> [v]
              _               -> []

-- | Select attributes on the current element (or nothing if it is not an element). XPath:
-- /the attribute axis contains the attributes of the context node; the axis will be empty unless the context node is an element/
-- 
-- Note that this is not strictly an 'Axis', but will work with most combinators.
-- 
-- The return list of the generalised axis contains as elements lists of 'Content' 
-- elements, each full list representing an attribute value.
attribute :: Name -> Cursor -> [[Content]]
attribute n Cursor{node=NodeElement e} = do (n', v) <- elementAttributes e
                                            guard $ n == n'
                                            return v
attribute _ _ = []
