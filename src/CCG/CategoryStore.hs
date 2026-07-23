{-# LANGUAGE OverloadedStrings #-}

module CCG.CategoryStore
  ( CategoryStore
  , emptyCategoryStore
  , internCategory
  , internAtomic
  , internFunctional
  , lookupCategory
  , categoryCount
  , parseCategory
  , prettyCategory
  , allCategories
  ) where

import CCG.Atom (AtomId, AtomTable, atomName, internAtom)
import CCG.Category (CategoryId (..), CategoryNode (..), Slash (..))
import Control.Monad.State.Strict (StateT, get, lift, put, runStateT)
import Data.Bifunctor (first)
import Data.Char (isAlphaNum)
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Data.IntMap.Strict (IntMap)
import qualified Data.IntMap.Strict as IntMap
import Data.Text (Text)
import qualified Data.Text as Text

data CategoryStore = CategoryStore
  { nodeToId :: !(HashMap CategoryNode CategoryId)
  , idToNode :: !(IntMap CategoryNode)
  , nextCategoryId :: !Int
  }
  deriving (Eq, Show)

emptyCategoryStore :: CategoryStore
emptyCategoryStore = CategoryStore HashMap.empty IntMap.empty 0

internCategory :: CategoryNode -> CategoryStore -> (CategoryId, CategoryStore)
internCategory node store = case HashMap.lookup node (nodeToId store) of
  Just categoryId -> (categoryId, store)
  Nothing ->
    let categoryId = CategoryId (nextCategoryId store)
     in ( categoryId
        , CategoryStore
            (HashMap.insert node categoryId (nodeToId store))
            (IntMap.insert (unCategoryId categoryId) node (idToNode store))
            (nextCategoryId store + 1)
        )

internAtomic :: AtomId -> CategoryStore -> (CategoryId, CategoryStore)
internAtomic atomId = internCategory (Atomic atomId)

internFunctional :: Slash -> CategoryId -> CategoryId -> CategoryStore -> (CategoryId, CategoryStore)
internFunctional slash result argument = internCategory (Functional slash result argument)

lookupCategory :: CategoryId -> CategoryStore -> Maybe CategoryNode
lookupCategory (CategoryId categoryId) = IntMap.lookup categoryId . idToNode

categoryCount :: CategoryStore -> Int
categoryCount = IntMap.size . idToNode

allCategories :: CategoryStore -> [(CategoryId, CategoryNode)]
allCategories = map (first CategoryId) . IntMap.toAscList . idToNode

data Token = Name !Text | FSlash | BSlash | LParen | RParen deriving (Eq, Show)

tokenize :: Text -> Either Text [Token]
tokenize input
  | Text.null rest = Right tokens
  | otherwise = Left ("invalid category character near: " <> Text.take 8 rest)
  where
    (tokens, rest) = go [] (Text.strip input)
    go acc text = case Text.uncons text of
      Nothing -> (reverse acc, "")
      Just (c, cs)
        | c == '/' -> go (FSlash : acc) (Text.stripStart cs)
        | c == '\\' -> go (BSlash : acc) (Text.stripStart cs)
        | c == '(' -> go (LParen : acc) (Text.stripStart cs)
        | c == ')' -> go (RParen : acc) (Text.stripStart cs)
        | isAlphaNum c || c == '_' ->
            let (suffix, remaining) = Text.span (\x -> isAlphaNum x || x `elem` ['_', '-']) cs
             in go (Name (Text.cons c suffix) : acc) (Text.stripStart remaining)
        | otherwise -> (reverse acc, text)

type Parser a = StateT ([Token], AtomTable, CategoryStore) (Either Text) a

parseCategory :: Text -> AtomTable -> CategoryStore -> Either Text (CategoryId, AtomTable, CategoryStore)
parseCategory input atoms store = do
  tokens <- tokenize input
  (categoryId, (remaining, atoms', store')) <- runStateT parseExpr (tokens, atoms, store)
  if null remaining then Right (categoryId, atoms', store') else Left "unexpected trailing category tokens"

parseExpr :: Parser CategoryId
parseExpr = parseTerm >>= parseTail
  where
    parseTail left = do
      (tokens, atoms, store) <- get
      case tokens of
        FSlash : rest -> put (rest, atoms, store) >> parseTerm >>= combine ForwardSlash left >>= parseTail
        BSlash : rest -> put (rest, atoms, store) >> parseTerm >>= combine BackwardSlash left >>= parseTail
        _ -> pure left
    combine slash result argument = do
      (tokens, atoms, store) <- get
      let (categoryId, store') = internFunctional slash result argument store
      put (tokens, atoms, store')
      pure categoryId

parseTerm :: Parser CategoryId
parseTerm = do
  (tokens, atoms, store) <- get
  case tokens of
    Name name : rest -> do
      let (atomId, atoms') = internAtom name atoms
          (categoryId, store') = internAtomic atomId store
      put (rest, atoms', store')
      pure categoryId
    LParen : rest -> do
      put (rest, atoms, store)
      categoryId <- parseExpr
      (remaining, atoms', store') <- get
      case remaining of
        RParen : tailTokens -> put (tailTokens, atoms', store') >> pure categoryId
        _ -> lift (Left "missing closing parenthesis")
    _ -> lift (Left "expected atom or parenthesized category")

prettyCategory :: AtomTable -> CategoryStore -> CategoryId -> Either Text Text
prettyCategory atoms store = render False
  where
    render nested categoryId = case lookupCategory categoryId store of
      Nothing -> Left "unknown category id"
      Just (Atomic atomId) -> maybe (Left "unknown atom id") Right (atomName atomId atoms)
      Just (Functional slash result argument) -> do
        resultText <- render True result
        argumentText <- render True argument
        let body = resultText <> slashText slash <> argumentText
        pure (if nested then "(" <> body <> ")" else body)
    slashText ForwardSlash = "/"
    slashText BackwardSlash = "\\"
