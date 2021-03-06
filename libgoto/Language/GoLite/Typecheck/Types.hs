{-|
Module      : Language.GoLite.Typecheck.Types
Description : Definition of the Typecheck monad
Copyright   : (c) Jacob Errington and Frederic Lafrance, 2016
License     : MIT
Maintainer  : goto@mail.jerrington.me
Stability   : experimental

Defines the @Typecheck@ monad as an instance of
'Language.GoLite.Monad.Traverse.MonadTraversal'.
The purpose of the @Typecheck@ monad is to build type and source
position-annotated syntax trees from merely source-position annotated syntax
trees.

Source position-annotated trees are defined in "Language.GoLite.Syntax.SrcAnn".
Type- and source position-annotated trees are defined in
"Language.GoLite.Syntax.Typecheck".

This module simply defines the types however. The logic for performing that
transformation is in "Language.GoLite.Typecheck".
-}

{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}

module Language.GoLite.Typecheck.Types where

import Language.Common.Monad.Traverse
import Language.GoLite.Pretty
import Language.GoLite.Syntax.SrcAnn
import Language.GoLite.Syntax.Typecheck
import Language.GoLite.Types

-- | The typecheck monad tracks errors in its state. Fatal errors cause a true
-- exception to the thrown (in the 'ExceptT' sense) whereas non-fatal errors
-- merely causes new errors to be accumulated in the state. Hence, when
-- analyzing the 'Either' that results from running the @ExceptT@, 'Left'
-- indicates a fatal error and 'Right' indicates either success or non-fatal
-- errors.
newtype Typecheck a
    = Typecheck { unTypecheck :: Traversal TypecheckError TypecheckState a }
    deriving
        ( Functor
        , Applicative
        , Monad
        , MonadError TypecheckError
        , MonadState TypecheckState
        )

-- | The state of the typechecker is the stack of scopes being traversed and
-- the list of accumulated non-fatal errors.
data TypecheckState
    = TypecheckState
        { _errors :: [TraversalError Typecheck]
        , _scopes :: [Scope]
        , _nextGid :: Int
        , dumpedScopes :: [(Scope, Int)]
        }
    deriving (Eq, Show)

-- | Regular typecheck/ing/ errors. (As opposed to typecheck/er/ errors.)
data TypeError
    = TypeMismatch
        { mismatchExpectedType :: Type
        -- ^ The expected type.
        , mismatchActualType :: Type
        -- ^ The actual type.
        , mismatchCause :: MismatchCause
        -- ^ The expression whose type is invalid.
        , errorReason :: Doc
        -- ^ A human-readable description of the error reason.
        }
    -- | The given symbol has already been declared in this scope.
    | Redeclaration
        { redeclOrigin :: SymbolInfo
        , redeclNew :: SymbolInfo
        }
    -- | The symbol used is not in scope.
    | NotInScope
        { notInScopeIdent :: SrcAnnIdent
        }
    -- | The symbol used is in scope, but is not of the proper kind
    -- (type or variable symbol)
    | SymbolKindMismatch
        { mismatchExpectedKind :: SymbolKind
        , mismatchActualInfo :: SymbolInfo
        , mismatchIdent :: SrcAnnIdent
        }
    -- | The given struct field does not exist.
    | NoSuchField
        { fieldIdent :: SrcAnnIdent
        , fieldExpr :: TySrcAnnExpr
        }
    -- | The type has been checked successfully, but cannot be used in the
    -- given expression.
    | UnsatisfyingType
        { unsatOffender :: Type
        , unsatReason :: Doc
        , errorLocation :: SrcSpan
        }
    -- | An error related to the type argument of a call occured (was present
    -- when not using the built-in make, or was not present when using it).
    | TypeArgumentError
        { errorReason :: Doc
        , typeArgument :: Maybe Type
        , errorLocation :: SrcSpan
        }
    -- | The number of arguments given to a call differ from the number of
    -- declared arguments to the function.
    | ArgumentLengthMismatch
        { argumentExpectedLength :: Int
        , argumentActualLength :: Int
        , errorLocation :: SrcSpan
        }
    -- | The types of a call expression do not match.
    | CallTypeMismatch
        { mismatchExpectedType :: Type
        , mismatchActualType :: Type
        , mismatchPosition :: Int
        , mismatchCause :: MismatchCause
        }
    -- | Two types involved in a binary operation could not be matched.
    | BinaryTypeMismatch
        { mismatchTypeL :: Type
        , mismatchTypeR :: Type
        , errorLocation :: SrcSpan
        }
    -- | Nil was used in a variable declaration without a type.
    | UntypedNil
        { errorLocation :: SrcSpan
        }
    -- | No new variables were introduced on the left-hand side of :=
    | NoNewVariables
        { errorLocation :: SrcSpan
        }
    -- | An expression whose value was required was found to have a type that
    -- does not have values.
    | IllegalNonvalueType
        { offendingType :: Type
        , errorLocation :: SrcSpan
        }
    | InvalidConversion
        { errorReason :: Doc
        , errorLocation :: SrcSpan
        }

    deriving (Eq, Show)

newtype ErrorPosition = ErrorPosition SymbolLocation

instance Pretty ErrorPosition where
    pretty (ErrorPosition loc) = case loc of
        SourcePosition s ->
            let start = srcStart s in
            let name = text (sourceName start) in
            let column = int (sourceColumn start) in
            let line = int (sourceLine start) in
            name <> colon <> line <> colon <> column <> colon
        Builtin ->
            text "builtin location:"

data ErrorSymbol = ErrorSymbol SymbolInfo

instance Pretty ErrorSymbol where
    pretty (ErrorSymbol sym) = case sym of
        VariableInfo {} ->
            text "variable (defined at"
            <+> pretty (ErrorPosition $ symLocation sym)
            <> text ")"
            <+> text "with declared type" $+$ nest indentLevel (pretty $ symType sym)
        TypeInfo {} ->
            text "type (defined at"
            <+> pretty (ErrorPosition $ symLocation sym)
            <> text ")"
            <+> text "with underlying type" $+$ nest indentLevel (pretty $ symType sym)

newtype ErrorSymbolKind = ErrorSymbolKind SymbolKind

instance Pretty ErrorSymbolKind where
    pretty (ErrorSymbolKind sym) = case sym of
        VariableInfo {} -> text "variable"
        TypeInfo {} -> text "type"

-- | Newtype for 'Pretty'fying integers followed by their appropriate ordinal
-- suffix in English.
newtype Ordinal = Ordinal Int

-- | Worth it.
instance Pretty Ordinal where
    pretty (Ordinal i) = int i <> case last (show i) of
        '1' -> text "st"
        '2' -> text "nd"
        '3' -> text "rd"
        _ -> text "th"

instance Pretty TypeError where
    pretty err = case err of
        TypeMismatch {} ->
            pretty loc $+$ nest indentLevel (
                text "cannot match expected type" $+$ nest indentLevel (
                    pretty (mismatchExpectedType err)
                ) $+$
                text "with actual type" $+$ nest indentLevel (
                    pretty (mismatchActualType err)
                ) $+$ (case mismatchCause err of
                    Ann _ Nothing -> empty
                    Ann _ (Just e) ->
                        text "in the expression" $+$ nest indentLevel (
                            pretty e
                        )
                )
            )

        Redeclaration {} ->
            pretty loc $+$ nest indentLevel (
                text "redeclaration of" $+$ nest indentLevel (
                    pretty (ErrorSymbol $ redeclOrigin err)
                ) $+$
                text "with" $+$ nest indentLevel (
                    pretty (ErrorSymbol $ redeclNew err)
                )
            )

        NotInScope {} ->
            pretty loc $+$ nest indentLevel (
                text "not in scope" <+> doubleQuotes (pretty $ notInScopeIdent err)
            )

        SymbolKindMismatch {} ->
            pretty loc $+$ nest indentLevel (
                text "cannot match expected symbol kind" $+$ nest indentLevel (
                    pretty (ErrorSymbolKind $ mismatchExpectedKind err)
                ) $+$
                text "with the symbol" $+$ nest indentLevel (
                    pretty (ErrorSymbol $ mismatchActualInfo err)
                ) $+$
                text "represented by the symbol" <+> pretty (mismatchIdent err)
            )

        NoSuchField {} ->
            let (ty, _) = topAnn (fieldExpr err) in
            pretty loc $+$ nest indentLevel (
                text "no such field" <+> doubleQuotes (pretty $ fieldIdent err) <+>
                text "in the expression" $+$ nest indentLevel (
                    pretty $ fieldExpr err
                ) $+$
                text "of type" $+$ nest indentLevel (
                    pretty ty
                )
            )

        UnsatisfyingType {} ->
            pretty loc $+$ nest indentLevel (
                text "unsatisfying type" $+$ nest indentLevel (
                    pretty $ unsatOffender err
                ) $+$ (if isEmpty (unsatReason err)
                    then empty
                    else text "because" $+$ nest indentLevel (
                        unsatReason err
                    )
                )
            )

        TypeArgumentError {} ->
            pretty loc <+> text "type argument error" $+$ nest indentLevel (
                (case typeArgument err of
                    Nothing -> empty
                    Just t ->
                        text "due to the type" $+$ nest indentLevel (
                            pretty t
                        )
                ) $+$
                text "because" <+> errorReason err
            )

        NoNewVariables {} ->
            pretty loc <+> text "no new variables introduced by short declaration"

        ArgumentLengthMismatch {} ->
            pretty loc <+> text "argument length mismatch" $+$ nest indentLevel (
                text "expected" <+> int (argumentExpectedLength err)
                <+> text "arguments, but got" <+> int (argumentActualLength err)
            )

        CallTypeMismatch {} ->
            pretty loc <+> text "call type mismatch" $+$ nest indentLevel (
                text "in the" <+> pretty (Ordinal (mismatchPosition err)) <+>
                text "argument of a function call, can't match expected type" $+$
                nest indentLevel (
                    pretty (mismatchExpectedType err)
                ) $+$
                text "with actual type" $+$ nest indentLevel (
                    pretty (mismatchActualType err)
                )
            )

        BinaryTypeMismatch {} ->
            pretty loc <+> text "binary operator type mismatch" $+$ nest indentLevel (
                text "can't match type of left-hand side" $+$ nest indentLevel (
                    pretty (mismatchTypeL err)
                ) $+$
                text "with type of right-hand side" $+$ nest indentLevel (
                    pretty (mismatchTypeR err)
                )
            )

        UntypedNil {} ->
            pretty loc <+> text "untyped constant nil"

        IllegalNonvalueType {} ->
            pretty loc <+> text "illegal non-value type" $+$ nest indentLevel (
                text "the type" $+$ nest indentLevel (
                    pretty (offendingType err)
                ) $+$
                text "is not a value type"
            )

        InvalidConversion {} ->
            pretty loc <+> text "invalid conversion" $+$ nest indentLevel (
                text "because" <+> errorReason err
            )

        where
            loc = ErrorPosition (typeErrorLocation err)

type MismatchCause = SrcAnn Maybe TySrcAnnExpr

-- | Determines the primary location of a type error.
typeErrorLocation :: TypeError -> SymbolLocation
typeErrorLocation e = case e of
    TypeMismatch { mismatchCause = Ann a _ } -> SourcePosition a
    Redeclaration { redeclNew = d } -> symLocation d
    NotInScope { notInScopeIdent = Ann a _ } -> SourcePosition a
    SymbolKindMismatch { mismatchIdent = Ann a _ } -> SourcePosition a
    NoSuchField { fieldIdent = Ann a _ } -> SourcePosition a
    UnsatisfyingType { errorLocation = a } -> SourcePosition a
    TypeArgumentError { errorLocation = a } -> SourcePosition a
    ArgumentLengthMismatch { errorLocation = a } -> SourcePosition a
    CallTypeMismatch { mismatchCause = Ann a _ } -> SourcePosition a
    BinaryTypeMismatch { errorLocation = a } -> SourcePosition a
    UntypedNil { errorLocation = a } -> SourcePosition a
    IllegalNonvalueType { errorLocation = a } -> SourcePosition a
    NoNewVariables { errorLocation = a } -> SourcePosition a
    InvalidConversion { errorLocation = a } -> SourcePosition a

-- | All errors that can actually be thrown.
data TypecheckError
    = ScopeImbalance
    -- ^ More scopes were popped than were pushed.
    | EmptyScopeStack
    -- ^ An attempt to modify the scope stack was made when the stack was
    -- empty.
    | WeederInvariantViolation
        { errorDescription :: Doc
        }
    -- ^ An illegal situation that should have been caught by a weeding pass
    -- arose during typechecking.
    | ParserInvariantViolation
        { errorDescription :: Doc
        }
    | TypecheckerInvariantViolation
        { errorDescription :: Doc
        }
    | UncategorizedOperator
    -- ^ An operator could not be categorized as either arithmetic, comparison,
    -- logical, or ordering.
    | GenericError
        { errorDescription :: Doc
        }
    -- ^ Used for testing.
    deriving (Eq, Show)

-- | Decides whether a declaration is allowed in isolation.
isValidDeclaration :: Maybe (Integer, SymbolInfo) -> Bool
isValidDeclaration e = case e of
    Nothing -> True -- the identifier is unique in the scope stack
    Just (distance, _) ->
        if distance <= 0
            then False -- redeclaration
            else True -- shadowing

-- | Typechecking is a traversal requiring state and the possibility of fatal
-- errors.
instance MonadTraversal Typecheck where
    type TraversalError Typecheck = TypeError
    type TraversalException Typecheck = TypecheckError
    type TraversalState Typecheck = TypecheckState

    reportError e = modify $ \s -> s { _errors = e : _errors s }
    getErrors = _errors
