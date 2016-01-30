module Language.GoLite.Parser
( -- * Statements
  stmt
, declStmt
, printStmt
, exprStmt
, returnStmt
, ifStmt
, switchStmt
, forStmt
, breakStmt
, continueStmt
  -- * Declarations
, decl
, typeDecl
, varDecl
  -- * Expressions
, module Language.GoLite.Parser.Expression
) where

import Language.GoLite.Lexer
import Language.GoLite.Parser.Expression
import Language.GoLite.Syntax

stmt :: Parser Statement
stmt = declStmt
    <|> printStmt
    <|> returnStmt
    <|> ifStmt
    <|> switchStmt
    <|> forStmt
    <|> breakStmt
    <|> continueStmt
    <|> (SimpleStmt <$> (simpleStmt >>= requireSemiP))

declStmt :: Parser Statement
declStmt = DeclStmt <$> (decl >>= requireSemiP)

printStmt :: Parser Statement
printStmt = do
    hasLn <- (kwPrint *> pure False) <|> (kwPrintLn *> pure True)
    exprs <- parens (expr `sepBy` comma) >>= requireSemiP
    PrintStmt <$> mapM noSemiP exprs <*> pure hasLn

-- | Parses a return statement.
returnStmt :: Parser Statement
returnStmt = do
    s <- kwReturn
    se <- optional expr

    requireSemiP $ case se of
        Nothing -> s *> pure (ReturnStmt Nothing)
        Just e -> s *> noSemi *> fmap (ReturnStmt . Just) e

ifStmt :: Parser Statement
ifStmt = error "ifStmt"

switchStmt :: Parser Statement
switchStmt = error "switchStmt"

forStmt :: Parser Statement
forStmt = error "forStmt"

breakStmt :: Parser Statement
breakStmt = (kwBreak >>= requireSemiP) *> pure BreakStmt

continueStmt :: Parser Statement
continueStmt = (kwContinue >>= requireSemiP) *> pure ContinueStmt

decl :: Parser (Semi Declaration)
decl = typeDecl
    <|> varDecl

typeDecl :: Parser (Semi Declaration)
typeDecl = error "typeDecl"

varDecl :: Parser (Semi Declaration)
varDecl = error "varDecl"

simpleStmt :: Parser (Semi SimpleStatement)
simpleStmt
    = exprStmt
    <|> shortVarDecl
    <|> assignStmt


shortVarDecl :: Parser (Semi SimpleStatement)
shortVarDecl = do
        ids <- (identifier >>= noSemiP) `sepBy1` comma <* shortVarDeclarator
        exprs <- semiTerminatedList expr
        pure $ do
            exprs' <- exprs
            pure $ ShortVarDecl ids exprs'

assignStmt :: Parser (Semi SimpleStatement)
assignStmt = do
        lhs <- (expr >>= noSemiP) `sepBy1` comma
        op <- opAssign >>= noSemiP
        rhs <- semiTerminatedList expr
        pure $ do
            rhs' <- rhs
            pure $ Assignment lhs op rhs'

-- | Parses an expression as a statement.
--
-- TODO: Go only allows certain kinds of expressions to act as statements. We
-- need to introduce a check that causes invalid expressions to raise errors.
exprStmt :: Parser (Semi SimpleStatement)
exprStmt = do
    e <- expr
    pure (ExprStmt <$> e)

-- | Parses one or more instances of `p`, separated by commas, requiring a
-- semicolon on the last instance, but no semicolon on any other instance.
semiTerminatedList :: Parser (Semi a) -> Parser (Semi [a])
semiTerminatedList p = do
        s <- p `sepBy1` comma
        pure $ foldr (\cur acc -> do
                        acc' <- acc
                        cur' <- cur
                        case acc' of
                                [] -> requireSemi
                                _ -> noSemi
                        pure $ cur':acc') (pure []) s