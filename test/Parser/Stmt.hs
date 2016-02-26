{-|
Module      : Stmt
Description : Tests for statements
Copyright   : (c) Jacob Errington and Frederic Lafrance, 2016
License     : MIT
Maintainer  : goto@mail.jerrington.me
Stability   : experimental
-}

{-# LANGUAGE OverloadedStrings #-}

module Parser.Stmt
( statement
) where

import Language.GoLite
import Language.GoLite.Syntax.SrcAnn
import Language.GoLite.Syntax.Sugar as Sugar

import Core

import Parser.For
import Parser.If
import Parser.Switch
import Parser.StmtDecl
import Parser.Simple

-- | Used for a specific test with blocks.
varDeclStmt :: [id] -> Maybe ty -> [e]
            -> Fix (StatementF (Declaration tyDecl (VarDecl id ty e)) ex i a c)
varDeclStmt i t e = Fix $ DeclStmt $ VarDecl $ VarDeclBody i t e

statement :: SpecWith ()
statement = describe "stmt" $ do
                describe "assignStmt" assign
                describe "shortVarDecl" shortVariableDeclaration
                describe "exprStmt" expressionStatement
                describe "simpleStmt" simpleStatement
                describe "varDecl" variableDeclaration
                describe "typeDecl" typeDeclaration
                describe "break/continue/fallthrough" simpleKeywordStmts
                describe "blockStmt" blockStatement
                describe "switchStmt" switchStatement
                describe "forStmt" forStatement
                describe "ifStmt" ifStatement

simpleKeywordStmts :: SpecWith ()
simpleKeywordStmts = do
    let parseStmt = parseOnly (fmap (map bareStmt) stmt)
    it "parses the keywords `break`, `continue` and `fallthrough`" $ do
        parseStmt "break" `shouldBe` r [breakStmt]
        parseStmt "continue" `shouldBe` r [continueStmt]
        parseStmt "fallthrough" `shouldBe` r [fallthroughStmt]

    it "does not parses if the keywords are missing a semi" $ do
        parseStmt "break {}" `shouldSatisfy` isLeft
        parseStmt "continue {}" `shouldSatisfy` isLeft
        parseStmt "fallthrough {}" `shouldSatisfy` isLeft

blockStatement :: SpecWith ()
blockStatement = do
    let parseBlock = parseOnly (fmap bareStmt blockStmt)
    it "parses a block containing one, many or no statements" $ do
        parseBlock "{}" `shouldBe` r (block [])
        parseBlock "{x++\n}" `shouldBe`
            r (block [assignment [variable "x"] PlusEq [int 1]])

        parseBlock "{x++\ny++\n}" `shouldBe`
            r (block [ assignment [variable "x"] PlusEq [int 1],
                assignment [variable "y"] PlusEq [int 1] ])

    it "doesn't parse if one of the enclosing statements don't have a semi" $ do
        parseBlock "{x++}" `shouldSatisfy` isLeft
        parseBlock "{x++; y++}" `shouldSatisfy` isLeft

    it "doesn't parse if the block doesn't have a semi" $ do
        parseBlock "{} {}" `shouldSatisfy` isLeft

    it "parses nested blocks" $ do
        parseBlock "{x++;{y++;{z++;};};}" `shouldBe`
            r (block [(assignment [variable "x"] PlusEq [int 1]),
                block [(assignment [variable "y"] PlusEq [int 1]),
                 block [(assignment [variable "z"] PlusEq [int 1])]]])

    it "handles statements parsers that return multiple statements" $ do
        parseBlock "{var (x = 2; y = 3;); x++;}" `shouldBe`
            r (block [
                varDeclStmt ["x"] Nothing [int 2],
                varDeclStmt ["y"] Nothing [int 3],
                (assignment [variable "x"] PlusEq [int 1])])