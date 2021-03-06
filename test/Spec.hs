module Main where

import Test.Hspec

import Lexer
import Parser
import Weeder


import Language.GoLite
import Language.GoLite.Pretty
import Language.GoLite.Syntax.SrcAnn
import Language.GoLite.Syntax.Typecheck
import Language.GoLite.Typecheck.Types

import Language.Vigil

import Control.Monad ( forM_ )
import System.Directory
import System.FilePath

validSourcesDir :: FilePath
validSourcesDir = "programs/valid"

invalidSourcesDir :: FilePath
invalidSourcesDir = "programs/invalid"

invalidTypeSourcesDir :: FilePath
invalidTypeSourcesDir = "programs/invalid-type"

validTypeSourcesDir :: FilePath
validTypeSourcesDir = "programs/valid-type"

getTestSources :: FilePath -> IO [(String, String)]
getTestSources sourcesDir = getGoFiles >>= mapM readWithPath where
    getGoFiles = filter isGoFile <$> getSourcePaths
    isGoFile = (==) ".go" . takeExtension
    getSourcePaths = getDirectoryContents sourcesDir
    readWithPath p = (,) <$> pure (sourcesDir </> p) <*> readFile (sourcesDir </> p)

main :: IO ()
main = do
    putStrLn "Loading syntactically valid test programs..."
    validSources <- getTestSources validSourcesDir

    putStrLn "Loading syntactically invalid test programs..."
    invalidSources <- getTestSources invalidSourcesDir

    putStrLn "Loading semantically valid test programs..."
    validTypeSources <- getTestSources validTypeSourcesDir

    putStrLn "Loading semantically invalid test programs..."
    invalidTypeSources <- getTestSources invalidTypeSourcesDir

    hspec goLite

    hspec $ describe "Syntactically valid programs" $ do
        forM_ validSources $ \(name, contents) ->
            it ("parses the valid program " ++ name) $
                checkParse
                    (expectationFailure . renderGoLite . pretty)
                    (const (pure ()))
                    name
                    contents

        forM_ invalidSources $ \(name, contents) ->
            it ("fails to parse the invalid program " ++ name) $
                checkParse
                    (const (pure ()))
                    (const (expectationFailure "should not parse"))
                    name
                    contents

    hspec $ describe "Semantically valid programs" $ do
        forM_ validTypeSources $ \(name, contents) ->
            it ("typechecks the valid program " ++ name) $
                checkTypecheck
                    (expectationFailure . renderGoLite . pretty)
                    (const (pure ()))
                    name
                    contents

        forM_ validTypeSources $ \(name, contents) ->
            it ("simplifies the valid program " ++ name) $
                checkSimplify
                    (expectationFailure . show)
                    (const (pure ()))
                    name
                    contents

        forM_ invalidTypeSources $ \(name, contents) ->
            it ("fails to parse the invalid program " ++ name) $
                checkTypecheck
                    (const (pure ()))
                    (const (expectationFailure "should not typecheck"))
                    name
                    contents


checkSimplify
    :: (SimplificationError -> Expectation)
    -> (TyAnnProgram -> Expectation)
    -> String -> String -> Expectation
checkSimplify bad good name contents = case parseOnly packageP name contents of
    Left pe -> expectationFailure (show pe)
    Right pr -> case weedGoLiteProgram pr of
        Just wes -> expectationFailure (show wes)
        Nothing -> case runTypecheck (typecheckPackage pr) of
            (Left fatal, _) -> expectationFailure (show fatal)
            (Right p, tst) -> case _errors tst of
                [] -> case runSimplify (_nextGid tst + 1) (simplifyPackage p) of
                    Left critical -> bad critical
                    Right s -> good (snd s)
                _ -> expectationFailure "Should have typechecked"


checkTypecheck
    :: (SemanticError -> Expectation)
    -> (TySrcAnnPackage -> Expectation)
    -> String -> String -> Expectation
checkTypecheck bad good name contents = case parseOnly packageP name contents of
    Left pe -> expectationFailure (show pe)
    Right pr -> case weedGoLiteProgram pr of
        Just wes -> expectationFailure (show wes)
        Nothing -> case runTypecheck (typecheckPackage pr) of
            (Left fatal, _) -> bad (TypeFatal fatal)
            (Right p, tst) -> case _errors tst of
                [] -> good p
                tes -> bad (Type tes)

checkParse
    :: (SyntaxError -> Expectation)
    -> (SrcAnnPackage -> Expectation)
    -> String -> String -> Expectation
checkParse bad good name contents = case parseOnly packageP name contents of
    Left e -> bad (Parse e)
    Right p -> case weedGoLiteProgram p of
        Nothing -> good p
        Just es -> bad (Weed es)

parseOnly :: Parser a -> String -> String -> Either ParseError a
parseOnly m = parse (sc >> m <* lexeme eof)

weedGoLiteProgram :: SrcAnnPackage -> Maybe WeederExceptions
weedGoLiteProgram p =
    case weed p of
        [] -> Nothing
        xs -> Just $ WeederExceptions xs

data SemanticError =
      Type [TypeError]
    | TypeFatal TypecheckError
    deriving ( Show )

instance Pretty SemanticError where
    pretty (Type e) = vcat (map pretty e)
    pretty (TypeFatal e) = text $ show e

data SyntaxError =
      Parse ParseError
    | Weed WeederExceptions
    deriving ( Show )

instance Pretty SyntaxError where
    pretty (Parse e) = text $ show e
    pretty (Weed e) = pretty e

goLite :: SpecWith ()
goLite = describe "Language.GoLite" $ do
    lexer
    parser
    weeder
