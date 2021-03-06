{-|
Module      : Language.GoLite.Typecheck
Description : Typechecking traversal logic
Copyright   : (c) Jacob Errington and Frederic Lafrance, 2016
License     : MIT
Maintainer  : goto@mail.jerrington.me
Stability   : experimental

Defines the functions for typechecking a source-annotated syntax tree. The
result is a typechecked syntax tree, as described in
"Language.GoLite.Syntax.Typecheck".
-}

{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE Rank2Types #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ViewPatterns #-}

module Language.GoLite.Typecheck
( runTypecheck
, _errors
, typecheckPackage
) where

import qualified Language.Common.GlobalId as Gid
import Language.Common.Misc
import Language.Common.Monad.Traverse
import Language.GoLite.Syntax.SrcAnn
import Language.GoLite.Syntax.Typecheck
import Language.GoLite.Syntax.Types as T
import Language.GoLite.Types as Ty
import Language.GoLite.Typecheck.Types
import Language.X86.Mangling

import Control.Applicative ( (<|>), Const(..) )
import Data.Bifunctor ( first )
import qualified Data.Map as M
import Data.Functor.Foldable ( cata )
import Text.PrettyPrint

-- | Fully runs a computation in the 'Typecheck' monad using the default root
-- scope.
runTypecheck :: Typecheck a -> (Either TypecheckError a, TypecheckState)
runTypecheck t
    = runIdentity (
        runStateT (
            runExceptT (
                runTraversal (
                    unTypecheck (genDefaultRootScope *> t)
                )
            )
        ) $
        TypecheckState
            { _errors = []
            , _scopes = []
            , _nextGid = 0
            , dumpedScopes = []
            }
    )

-- | Build a globally unique identifier tied to a given type.
nextGid :: SrcAnnIdent -> Type -> DataOrigin -> Typecheck GlobalId
nextGid (Ann a (Ident name)) ty orig = do
    n <- gets _nextGid
    modify $ \s -> s { _nextGid = n + 1 }
    pure Gid.GlobalId
        { gidTy = ty
        , gidNum = n
        , gidOrigName = case unFix ty of
            BuiltinType _ -> Ann a (symbolFromString $ mangleFuncName $ name)
            _ -> Ann a (symbolFromString $ mangleFuncName $ "gocode_" ++ name)
        , gidOrigin = orig
        }

-- | Construct a dummy global identifier for an arbitrary variable.
noGid
    :: String
    -> GlobalId
noGid name = Gid.GlobalId
    { gidTy = unknownType
    , gidNum = -1
    , gidOrigName = Ann builtinSpan $ symbolFromString name
    , gidOrigin = Local
    }

blank :: SymbolInfo
blank = VariableInfo
    { symLocation = Builtin
    , symType = unknownType
    , symGid = noGid "_"
    }

genDefaultRootScope :: Typecheck ()
genDefaultRootScope = do
    s <- forM defaultRootScope $ \(name, t, mkSymInfo) -> do
        g <- nextGid (Ann builtinSpan (Ident name)) t Local
        pure (name, mkSymInfo t g)
    pushScope (Scope { scopeMap = M.fromList s })

-- | The root scope containing builtin functions and types.
defaultRootScope :: [(String, Type, Type -> GlobalId -> SymbolInfo)]
defaultRootScope =
        [ -- Predeclared types
          ( "bool"
          , typedBoolType
          , \t -> const $ TypeInfo
            { symLocation = Builtin
            , symType = t
            }
          ),
          ( "float64"
          , typedFloatType
          , \t -> const $ TypeInfo
            { symLocation = Builtin
            , symType = t
            }
          ),
          ( "int"
          , typedIntType
          , \t -> const $ TypeInfo
            { symLocation = Builtin
            , symType = t
            }
          ),
          ( "rune"
          , typedRuneType
          , \t -> const $ TypeInfo
            { symLocation = Builtin
            , symType = t
            }
          ),
          ( "string"
          , typedStringType
          , \t -> const $ TypeInfo
            { symLocation = Builtin
            , symType = t
            }
          ),
          ( "true"
          , untypedBoolType
          , \t gid -> VariableInfo
            { symLocation = Builtin
            , symType = t
            , symGid = gid
            }
          ),
          ( "false"
          , untypedBoolType
          , \t gid -> VariableInfo
            { symLocation = Builtin
            , symType = t
            , symGid = gid
            }
          ),
          ( "nil"
          , nilType
          , \t gid -> VariableInfo
            { symLocation = Builtin
            , symType = t
            , symGid = gid
            }
          ),
          ( "false"
          , untypedBoolType
          , \t gid -> VariableInfo
            { symLocation = Builtin
            , symType = t
            , symGid = gid
            }
          ),
          ( "append"
          , builtinType AppendType
          , \t gid -> VariableInfo
            { symLocation = Builtin
            , symType = t
            , symGid = gid
            }
          ),
          ( "cap"
          , builtinType CapType
          , \t gid -> VariableInfo
            { symLocation = Builtin
            , symType = t
            , symGid = gid
            }
          ),
          ( "copy"
          , builtinType CopyType
          , \t gid -> VariableInfo
            { symLocation = Builtin
            , symType = t
            , symGid = gid
            }
          ),
          ( "len"
          , builtinType LenType
          , \t gid -> VariableInfo
            { symLocation = Builtin
            , symType = t
            , symGid = gid
            }
          ),
          ( "make"
          , builtinType MakeType
          , \t gid -> VariableInfo
            { symLocation = Builtin
            , symType = t
            , symGid = gid
            }
          )
        ]

-- | Pushes a given scope onto the stack.
pushScope :: Scope -> Typecheck ()
pushScope scope = modify $ \s -> s { _scopes = scope : _scopes s }

-- | Pops the topmost scope off the stack.
--
-- Aborts the traversal with a fatal 'ScopeImbalance' error.
popScope :: Typecheck Scope
popScope = do
    scopes <- gets _scopes
    case scopes of
        [] -> throwError ScopeImbalance
        s:ss -> do
            modify $ \t -> t { _scopes = ss,
                            dumpedScopes = (s, length ss):(dumpedScopes t) }
            pure s

-- | Pushes an empty scope onto the stack.
newScope :: Typecheck ()
newScope = pushScope $ Scope { scopeMap = M.empty }

-- | Pops a scope from the stack, discarding it.
dropScope :: Typecheck ()
dropScope = popScope $> ()

withScope :: Typecheck a -> Typecheck a
withScope m = newScope *> m <* dropScope

-- | Runs a pure function on the top scope of the stack. If the stack is empty,
-- throws 'EmptyScopeStack'.
modifyTopScope :: (Scope -> Typecheck Scope) -> Typecheck ()
modifyTopScope f = do
    scopes <- gets _scopes
    case scopes of
        [] -> throwError EmptyScopeStack
        top:others -> do
            top' <- f top
            modify $ \s -> s { _scopes = top' : others }

-- | Adds a symbol to the top scope.
--
-- If the scope stack is empty, throws 'EmptyScopeStack'.
--
-- If the symbol already exists, then a non-fatal redeclaration error is
-- raised and the insertion is not performed.
declareSymbol :: SymbolName -> SymbolInfo -> Typecheck ()
-- | Trying to declare the blank doesn't do anything.
declareSymbol "_" _ = pure ()
declareSymbol name info = modifyTopScope $ \(Scope m) -> do
    case M.lookup name m of
        Just info' -> do
            reportError $ Redeclaration
                { redeclOrigin = info'
                , redeclNew = info
                }
            pure (Scope m) -- return the scope unchanged
        Nothing -> do
            pure (Scope $ M.insert name info m)

-- | Looks up a variable in the scope stack.
--
-- This function does not report any errors.
lookupSymbol :: SymbolName -> Typecheck (Maybe (Integer, SymbolInfo))
lookupSymbol "_" = pure $ Just (0, blank)
lookupSymbol name = foldr (<|>) Nothing . map (sequence . fmap (M.lookup name)) . zip [0..] . map scopeMap <$> gets _scopes

-- | Computes the canonical type representation for a source-annotated type.
canonicalize :: SrcAnnType -> Typecheck TySrcAnnType
canonicalize = annCata f where
    f :: SrcSpan -> SrcAnnTypeF (Typecheck TySrcAnnType) -> Typecheck TySrcAnnType
    f a t = case t of
        SliceType m -> do
            s@(Fix (Ann (t', _) _)) <- m
            pure $ Fix $ Ann (Fix $ Ty.Slice t', a) (SliceType s)
        ArrayType b@(Ann _ (getConst -> n)) m -> do
            s@(Fix (Ann (t', _) _)) <- m
            pure $ Fix $ Ann (Fix $ Array n t', a) (ArrayType b s)
        StructType h -> do
            h' <- forM h $ \(i, t') ->
                (,) <$> pure i <*> t'

            t' <- forM h $ \(i, m) -> (,)
                <$> pure (annNat (symbolFromString . unIdent) i)
                <*> (fst . topAnn <$> m)

            pure $ Fix $ Ann (Fix $ Struct t', a) (StructType h')
        NamedType i@(Ann b (Ident name)) -> do
            minfo <- lookupSymbol name

            info <- case minfo of
                Just (_, info) -> case info of
                    VariableInfo {} -> do
                        reportError $ SymbolKindMismatch
                            { mismatchExpectedKind = typeKind
                            , mismatchActualInfo = info
                            , mismatchIdent = i
                            }
                        pure $ TypeInfo
                            { symLocation = SourcePosition b
                            , symType = unknownType
                            }

                    TypeInfo _ _ -> pure info

                Nothing -> do
                    reportError $ NotInScope { notInScopeIdent = i }
                    pure $ TypeInfo
                        { symLocation = SourcePosition b
                        , symType = unknownType
                        }

            pure $ Fix $ Ann (symType info, a) (NamedType i)

-- | Typechecks a source position-annotated 'Package'.
typecheckPackage :: SrcAnnPackage -> Typecheck TySrcAnnPackage
typecheckPackage (Package ident decls)
    = withScope $ Package <$> pure ident <*> (mapM typecheckTopLevelDecl decls) <* dropScope

-- | Typechecks a source position-annotated 'TopLevelDecl'.
typecheckTopLevelDecl :: SrcAnnTopLevelDecl -> Typecheck TySrcAnnTopLevelDecl
typecheckTopLevelDecl d = case d of
    TopLevelDecl decl -> TopLevelDecl <$> typecheckDecl decl
    TopLevelFun decl -> TopLevelFun <$> typecheckFun decl

-- | Typechecks a source position-annotated 'Declaration'.
typecheckDecl :: SrcAnnDeclaration -> Typecheck TySrcAnnDeclaration
typecheckDecl d = case d of
    TypeDecl tyDeclBody -> TypeDecl <$> typecheckTypeDecl tyDeclBody
    VarDecl varDeclBody -> VarDecl <$> typecheckVarDecl varDeclBody

-- | Typechecks a source position-annotated 'TypeDecl'.
typecheckTypeDecl :: SrcAnnTypeDecl -> Typecheck TySrcAnnTypeDecl
typecheckTypeDecl d = case d of
    TypeDeclBody si@(Ann a (Ident i)) ty -> do
        ty' <- canonicalize ty
        declareSymbol i $ TypeInfo
            { symLocation = SourcePosition a
            , symType = aliasType si (fst (topAnn ty'))
            }
        pure $ TypeDeclBody (Ann a (Ident i)) ty'

-- | Typechecks a source position-annotated 'VarDecl'.
typecheckVarDecl :: SrcAnnVarDecl -> Typecheck TySrcAnnVarDecl
typecheckVarDecl d = case d of
    VarDeclBody idents mty [] -> do
        declTy <- case mty of
            Nothing -> throwError ParserInvariantViolation
                { errorDescription
                    = text "at least one of the expression list and type must\
                            \be present in a declaration"
                }
            Just ty -> canonicalize ty

        gs <- forM idents $ \ident@(Ann a (Ident i)) -> do
            let ty = defaultType (fst (topAnn declTy))
            g <- nextGid ident ty Local

            declareSymbol i $ VariableInfo
                { symLocation = SourcePosition a
                , symType = ty
                , symGid = g
                }

            pure g

        pure $ VarDeclBody gs (pure declTy) []

    VarDeclBody idents mty exprs -> do
        let (ies, rest) = safeZip idents exprs

        unless (isNothing rest) $ throwError WeederInvariantViolation
            { errorDescription
                = text "VarDecl with differing length on each side:"
                <+> text (show rest)
            }

        ty <- traverse canonicalize mty

        ies' <- forM ies $ \(ident, expr) -> do
            (ty', expr') <- case ty of
                Nothing -> do
                    expr' <- typecheckExpr expr
                    let (tye, ae) = topAnn expr'
                    case tye of
                        Fix NilType -> do
                            reportError $ UntypedNil ae
                            pure (unknownType, expr')
                        _ ->
                            if not $ isValue tye then do
                                reportError $ IllegalNonvalueType tye ae
                                pure (unknownType, expr')
                            else pure (tye, expr')

                Just declTy -> do
                    let (t, _) = topAnn declTy
                    expr' <- requireExprType t empty expr
                    pure (t, expr')

            g <- nextGid ident (defaultType ty') Local

            pure $ (g, expr')

        let (idents', exprs') = unzip ies'

        -- Declare all identifiers AFTER typechecking the expressions.
        forM (zip idents' (map fst ies)) $ \(g, (Ann a (Ident i))) ->
            declareSymbol i $ VariableInfo
                    { symLocation = SourcePosition a
                    , symType = gidTy g
                    , symGid = g
                    }

        pure $ VarDeclBody idents' ty exprs'

-- | Typechecks a source position-annotated 'FunDecl'.
typecheckFun :: SrcAnnFunDecl -> Typecheck TySrcAnnFunDecl
typecheckFun e = case e of
    FunDecl ident@(Ann a (Ident name)) margs mretty stmts -> do
        rettyAnn <- traverse canonicalize mretty

        let retty = maybe voidType (fst . topAnn) rettyAnn

        args <- forM margs $ \(i, t) -> (,)
            <$> pure i
            <*> canonicalize t

        let ty = funcType
                (map
                    (\(i, t) -> (,)
                        (annNat (symbolFromString . unIdent) i)
                        (fst (topAnn t))
                    ) args
                ) retty

        g <- nextGid ident ty Local
        declareSymbol name $ VariableInfo
            { symLocation = SourcePosition a
            , symType = ty
            , symGid = g
            }

        (args', stmts') <- withScope $ do
            args' <- forM
                (zip [0..] args) $
                \(i, (ident'@(Ann b (Ident argName)), argTy)) -> do
                    let t = fst (topAnn argTy)
                    g' <- nextGid ident' t (Argument i)
                    declareSymbol argName $ VariableInfo
                        { symLocation = SourcePosition b
                        , symType = t
                        , symGid = g'
                        }
                    pure (g', argTy)

            stmts' <- typecheckFunctionBody ty stmts
            pure (args', stmts')

        FunDecl <$> pure g <*> pure args' <*> pure rettyAnn <*> pure stmts'

fixConversions :: SrcAnnExpr -> Typecheck SrcAnnExpr
fixConversions = annCata f where
    f :: SrcSpan
        -> SrcAnnExprF (Typecheck SrcAnnExpr)
        -> Typecheck SrcAnnExpr
    f a eff = case eff of
        Call m mty args -> do
            let fa = Fix . Ann a

            e <- m
            args' <- sequence args
            case e of
                Fix (Ann _ (Variable j)) -> do
                    -- check whether the type is a NamedType and try to convert it to
                    -- an expression, constructing a new argument list with the new
                    -- expression added on
                    mty' <- forM mty $ \ty -> do
                        case unFix ty of
                            Ann b (NamedType name) -> do
                                sym <- lookupSymbol (unIdent (bare name))
                                case sym of
                                    -- not in scope error will be triggered by
                                    -- canonicalize later
                                    Nothing -> pure $ Left ty

                                    -- if the lookup succeeds, need to verify whether
                                    -- the named type is actually a *type*.
                                    -- If it isn't then convert it to a Variable and
                                    -- add it to the arguments list
                                    Just (_, info) -> case info of
                                        VariableInfo {} -> do
                                            pure $ Right $
                                                (Fix (Ann b (Variable name)))
                                        TypeInfo {} -> pure $ Left $ ty
                            _ -> pure $ Left ty

                    let ok = fa $ case mty' of
                            Nothing ->
                                Call e Nothing args'
                            Just (Left ty) ->
                                Call e (Just ty) args'
                            Just (Right ex) ->
                                Call e Nothing (ex : args')

                    sym <- lookupSymbol (unIdent (bare j))

                    -- analyze the expression to call
                    case sym of
                        Nothing -> pure ok
                        -- if the child did pass up an identifier, then we need to
                        -- analyze the info to see whether it's a variable or a type
                        Just (_, info) -> case info of
                            -- if it's a variable, then business as usual; we're just
                            -- calling a named function
                            VariableInfo {} -> pure ok

                            -- if it's a type, then we need to convert this call into a
                            -- conversion
                            TypeInfo {} -> do
                                let convert argus = case argus of
                                        [x] -> pure $ fa $ Conversion
                                            (Fix $ Ann (ann j) $ NamedType j)
                                            x

                                        -- if we have a non-one number of arguments,
                                        -- then the conversion is invalid
                                        _ -> do
                                            reportError InvalidConversion
                                                { errorReason
                                                    = text "conversions may only take \
                                                    \one argument"
                                                , errorLocation = a
                                                }
                                            pure ok

                                case mty' of
                                    -- if we have no type argument, then we need to
                                    -- ensure that we have only one argument
                                    Nothing -> convert args'

                                    -- if we have a bona fide type argument, then
                                    -- that's no good, because we can't convert a
                                    -- type!
                                    Just (Left _) -> do
                                        reportError TypeArgumentError
                                            { errorReason
                                                = text "type arguments may not be \
                                                \used in conversions"
                                            , typeArgument = Nothing
                                            , errorLocation = a
                                            }
                                        pure ok

                                    Just (Right arg) -> convert (arg:args')
                _ -> pure $ fa $ Call e mty args'
        _ -> do
            eff' <- sequence eff
            pure (Fix $ Ann a eff')


-- | Typechecks a source position-annotated fixed point of 'ExprF'.
typecheckExpr :: SrcAnnExpr -> Typecheck TySrcAnnExpr
typecheckExpr xkcd = fixConversions xkcd >>= cata f where
    -- the boilerplate for reconstructing the tree but in which the branches
    -- now contain type information along with source position information.
    wrap a = Fix . uncurry Ann . first (, a)

    -- the monadic F-algebra that typechecks expressions bottom-up.
    f :: SrcAnn SrcAnnExprF (Typecheck TySrcAnnExpr) -> Typecheck TySrcAnnExpr
    f (Ann a e) = fmap (wrap a) $ case e of
        BinaryOp o me1 me2 ->
            let subs = (,) <$> me1 <*> me2
                in (,)
                    <$> (uncurry (typecheckBinaryOp o) =<< subs)
                    <*> (uncurry (BinaryOp o) <$> subs)

        UnaryOp o me -> (,)
            <$> (typecheckUnaryOp o =<< me)
            <*> (UnaryOp o <$> me)

        Conversion ty me -> do
            ty' <- canonicalize ty
            e' <- me
            let cty = fst (topAnn ty')
            typecheckConversion cty e'
            pure (cty, Conversion ty' e')

        Selector me i -> do
            e' <- me
            let (ty, b) = topAnn e'
            let sym = annNat (symbolFromString . unIdent) i

            -- check that ty is a struct type or an alias thereof, perform the
            -- lookup of the identifier in the struct to get the component's
            -- type; that becomes the type of the selector expression.
            ty' <- case unFix $ unalias ty of
                Ty.Struct fs ->
                    case lookup (bare sym) $ map (\(s, fi) -> (bare s, fi)) fs of
                        Nothing -> do
                            reportError $ NoSuchField
                                { fieldIdent = i
                                , fieldExpr = e'
                                }
                            pure unknownType
                        Just ty' -> pure ty'
                _ -> do
                    reportError $ TypeMismatch
                        { mismatchExpectedType
                            = structType [(sym, unknownType)]
                        , mismatchActualType
                            = ty
                        , mismatchCause = Ann b (Just e')
                        , errorReason = empty
                        }
                    pure unknownType

            pure (ty', Selector e' i)

        Index mie miev -> do
            ie <- mie -- the expression to index *in*
            iev <- miev -- the expression to index *by*

            let (iety, be) = topAnn ie
            let (defaultType -> ievty, bev) = topAnn iev

            -- check that the expression to index in is indexable (is an array,
            -- a slice, or a string) and get the element type
            t <- case unFix (unalias iety) of
                Ty.Slice t -> pure t
                Array _ t -> pure t
                StringType _ -> pure typedRuneType
                _ -> do
                    reportError $ TypeMismatch
                        { mismatchExpectedType = arrayType 0 unknownType
                        , mismatchActualType = iety
                        , mismatchCause = Ann be (Just ie)
                        , errorReason = empty
                        }
                    pure unknownType

            -- check that the expression to index by is an integer
            case unFix ievty of
                IntType _ -> pure ()
                _ -> reportError $ TypeMismatch
                    { mismatchExpectedType = typedIntType
                    , mismatchActualType = ievty
                    , mismatchCause = Ann bev (Just iev)
                    , errorReason = empty
                    }

            pure (t, Index ie iev)

        T.Slice me melo mehi mebound -> do
            e' <- me
            let (ty, b) = topAnn e'

            -- check that the expression to slice is a slice/array
            ty' <- case unFix ty of
                Ty.Slice ty' -> pure ty'
                Ty.Array _ ty' -> pure ty'
                _ -> do
                    reportError $ TypeMismatch
                        { mismatchExpectedType = sliceType unknownType
                        , mismatchActualType = ty
                        , mismatchCause = Ann b (Just e')
                        , errorReason = empty
                        }
                    pure unknownType

            lo <- sequence melo
            hi <- sequence mehi
            bound <- sequence mebound

            let checkIndex i = do
                    let (ity, c) = topAnn i
                    (typedIntType, ity) <== TypeMismatch
                        { mismatchExpectedType = typedIntType
                        , mismatchActualType = ity
                        , mismatchCause = Ann c (Just i)
                        , errorReason = empty
                        }

            mapM_ (traverse checkIndex) [lo, hi, bound]

            pure (Fix $ Ty.Slice ty', T.Slice e' lo hi bound)

        TypeAssertion me ty -> do
            e' <- me
            ty' <- canonicalize ty

            throwError $ WeederInvariantViolation $ text "type assertion not supported"

            pure (fst $ topAnn ty', TypeAssertion e' ty')

        Call me mty margs -> do
            e' <- me

            let usual = sequence (forM mty canonicalize, sequence margs)
            (ty', args) <- case mty of
                Just (Fix (Ann _ (NamedType i@(Ann b (Ident name))))) -> do
                    inf <- lookupSymbol name
                    case inf of
                        Just (_, info) -> case info of
                            VariableInfo {} -> do
                                -- Obtain the args, synthesize a fake expression
                                -- from the type, then repackage everything.
                                args <- sequence margs
                                synth <- typecheckExpr (Fix (Ann b (Variable i)))
                                pure (pure Nothing, synth:args)
                            TypeInfo _ _ -> usual
                        -- This will cause an error, but that's kind of what we
                        -- want.
                        Nothing -> usual
                _ -> usual

            ty <- ty'

            let normal = do
                    let (funTy, b) = topAnn e'
                    t <- case unFix funTy of
                        BuiltinType bu -> typecheckBuiltin a bu ty args
                        FuncType fargs fret -> do
                            typecheckCall a ty args fargs
                            pure fret
                        UnknownType -> pure unknownType
                        _ -> do
                            reportError $ TypeMismatch
                                { mismatchExpectedType = Fix $ FuncType
                                    { funcTypeArgs = map
                                        (\a' ->
                                            let (t, c) = topAnn a'
                                            in (Ann c blankSymbol, t))
                                        args
                                    , funcTypeRet = unknownType
                                    }
                                , mismatchActualType = funTy
                                , mismatchCause = Ann b (Just e')
                                , errorReason = empty
                                }
                            pure unknownType

                    pure (t, Call e' ty args)

            case bare (unFix e') of
                Variable (Gid.GlobalId { gidOrigName = Ann b s }) -> do
                    minfo <- lookupSymbol (stringFromSymbol s)
                    case minfo of
                        Nothing -> normal
                        Just (_, info) -> case info of
                            VariableInfo {} -> normal
                            TypeInfo {} -> do
                                let symTy = symType info
                                case ty of
                                    Just t -> do
                                        reportError $ TypeArgumentError
                                            { errorReason
                                                = text "only make can receive \
                                                \type arguments"
                                            , typeArgument
                                                = Just $ fst (topAnn t)
                                            , errorLocation = b
                                            }
                                    Nothing -> pure ()

                                let n = length args

                                case args of
                                    [] -> do
                                        reportError $ ArgumentLengthMismatch
                                            { argumentExpectedLength = 1
                                            , argumentActualLength = n
                                            , errorLocation = b
                                            }
                                        pure $ (unknownType, Call e' ty args)
                                    x:_ -> do
                                        typecheckConversion symTy x
                                        let at = Ann
                                                (symTy, b)
                                                (NamedType
                                                    (Ann b $ Ident $ stringFromSymbol s)
                                                )
                                        pure $
                                            ( symTy
                                            , Conversion (Fix at) x
                                            )

                _ -> normal

        Literal (Ann la l) ->
            fmap (\ty -> (ty, Literal $ Ann (ty, la) l)) $ case l of
                IntLit _ -> pure untypedIntType
                FloatLit _ -> pure untypedFloatType
                RuneLit _ -> pure untypedRuneType
                StringLit _ -> pure untypedStringType

        Variable x@(Ann _ (Ident name)) -> do
            minfo <- lookupSymbol name
            case minfo of
                Just (_, info) -> case info of
                    VariableInfo {} -> pure
                        ( symType info
                        , Variable (symGid info)
                        )
                    TypeInfo {} -> do
                        reportError SymbolKindMismatch
                            { mismatchExpectedKind = variableKind
                            , mismatchActualInfo = info
                            , mismatchIdent = x
                            }
                        pure (unknownType, Variable $ noGid name)
                Nothing -> do
                    reportError $ NotInScope { notInScopeIdent = x }
                    pure (unknownType, Variable $ noGid name)

    -- | Computes the canonical type of a unary operator expression.
    typecheckUnaryOp
        :: SrcAnnUnaryOp
        -> TySrcAnnExpr
        -> Typecheck Type
    typecheckUnaryOp o e =
        let (ty, a) = topAnn e in
        case bare o of
            LogicalNot ->
                if isLogical $ unalias ty then
                    pure ty
                else do
                    reportError $ UnsatisfyingType
                        { unsatOffender = ty
                        , unsatReason = text "it is not logical"
                        , errorLocation = a }
                    pure unknownType
            BitwiseNot ->
                if isIntegral $ unalias ty then
                    pure ty
                else do
                    reportError $ UnsatisfyingType
                        { unsatOffender = ty
                        , unsatReason = text "it is not logical"
                        , errorLocation = a }
                    pure unknownType
            _ ->
                if isArithmetic $ unalias ty then
                    pure ty
                else do
                    reportError $ UnsatisfyingType
                        { unsatOffender = ty
                        , unsatReason = text "it is not numerical"
                        , errorLocation = a }
                    pure unknownType


-- | Checks that a conversion is valid.
--
-- We say that a conversion between types S and T is valid if one of the
-- following is true:
--  * the underlying types of S and T are both convertible
--  * the underlying types of S and T are assignment compatible
--
-- /See also/ 'isConvertible', 'unalias'
typecheckConversion
    :: Type
    -> TySrcAnnExpr
    -> Typecheck ()
typecheckConversion ty e = do
    let (t', b) = topAnn e
    case (unalias ty, unalias t') of
        (isConvertible -> True, isConvertible -> True) -> pure ()
        t@(_, _) -> do
            t <== TypeMismatch
                { mismatchExpectedType = ty
                , mismatchActualType = t'
                , mismatchCause = Ann b (Just e)
                , errorReason = empty
                }
            pure ()
    pure ()

-- | Computes the canonical type of a binary operator expression.
typecheckBinaryOp
    :: SrcAnnBinaryOp
    -> TySrcAnnExpr
    -> TySrcAnnExpr
    -> Typecheck Type
typecheckBinaryOp o l r
    -- In general:
    -- Types must be indentical modulo typedness
    -- Expression is untyped iff both operands are untyped.
    | isArithmeticOp $ bare o = case bare o of
        -- Plus is defined on strings.
        Plus -> checkBinary (\ty -> isArithmetic ty || isString ty)
            (text "it is not numerical or string")
        _ -> checkBinary isArithmetic (text "it is not numerical")

    | isComparisonOp $ bare o =
        -- Special case: we check that the types are comparable, and
        -- not that they're equal. The resulting type is always a typed
        -- boolean, except when both operands are untyped booleans.
            let tyl = fst $ topAnn l in
            let tyr = fst $ topAnn r in do

            if isComparable tyl tyr then
                case (unFix tyl, unFix tyr) of
                    (BoolType False, BoolType False) -> pure untypedBoolType
                    (_, _) -> pure typedBoolType
            else do
                reportError $ BinaryTypeMismatch
                    { mismatchTypeL = tyl
                    , mismatchTypeR = tyr
                    , errorLocation = snd (topAnn l)
                    }
                pure unknownType

    | isLogicalOp $ bare o =
        checkBinary isLogical (text "it is not logical")

    | isOrderingOp $ bare o =
        -- Ordering operators produce booleans
        checkBinaryYieldingType
            isOrdered
            (text "it cannot be ordered")
            (Just untypedBoolType)

    | isIntegralOp $ bare o =
        checkBinary isIntegral (text "it is not integral")

    | otherwise = throwError UncategorizedOperator
    where
        -- Convenience alias.
        checkBinary p e = checkBinaryYieldingType p e Nothing

        -- Checks the type of the binary expression, yielding the given type if
        -- there is Just one, or the type of the left operand if it is Nothing.
        checkBinaryYieldingType p e mty =
            let (tyl, al) = topAnn l in
            let (tyr, ar) = topAnn r in do

            -- Check that the left type satisfies the predicate.
            when (not $ p tyl)
                (reportError $ UnsatisfyingType
                    { unsatOffender = tyl
                    , unsatReason = e
                    , errorLocation = al })

            -- Check that the right type satisfies the predicate.
            when (not $ p tyr)
                (reportError $ UnsatisfyingType
                    { unsatOffender = tyr
                    , unsatReason = e
                    , errorLocation = ar })

            if p tyr && p tyl then
                -- If they both satisfy the predicate, make sure they don't
                -- differ. We don't unalias them here.
                if defaultType tyr /= defaultType tyl then do
                    reportError $ BinaryTypeMismatch
                        { mismatchTypeL = tyl
                        , mismatchTypeR = tyr
                        , errorLocation = snd (topAnn l)
                        }
                    pure unknownType
                else
                    -- If they are both untyped, the expression is untyped.
                    -- Otherwise, it is typed.
                    if isUntyped tyl && isUntyped tyr then
                        pure $ case mty of
                            Nothing -> tyl
                            Just ty -> ty
                    else
                        pure $ defaultType $ case mty of
                            Nothing -> tyl
                            Just ty -> ty
            else
                pure unknownType

-- | Typecheck the body of a function of a given type.
typecheckFunctionBody
    :: Type
    -> [SrcAnnStatement]
    -> Typecheck [TySrcAnnStatement]
typecheckFunctionBody fty = mapM typecheckStmt where
    typecheckStmt :: SrcAnnStatement -> Typecheck TySrcAnnStatement
    typecheckStmt = cata f where
        f :: Ann SrcSpan SrcAnnStatementF (Typecheck TySrcAnnStatement)
          -> Typecheck TySrcAnnStatement
        f (Ann a s) = Fix . Ann a <$> case s of
            DeclStmt decl -> DeclStmt <$> typecheckDecl decl

            ExprStmt expr -> do
                t <- typecheckExpr expr
                case bare $ unFix t of
                    (Call ee _ _) -> do
                        let (tyCall, _) = topAnn ee
                        when (not $ isAllowedInExprStmt tyCall)
                            (reportError $ UnsatisfyingType
                                { unsatOffender = tyCall
                                , unsatReason = text "it cannot be used in \
                                  \expression statement context"
                                , errorLocation = a})
                    _ -> throwError $ ParserInvariantViolation
                                    $ text "ExprStmt should always be a call"
                pure $ ExprStmt t

            ShortVarDecl idents exprs -> do
                noNew <- all (not . isValidDeclaration)
                    <$> mapM (lookupSymbol . unIdent . bare) idents

                when noNew $ reportError $ NoNewVariables
                        { errorLocation = a
                        }

                ies <- forM (zip idents exprs) $ \(ident@(Ann b (Ident i)), e) -> do
                    e' <- typecheckExpr e
                    let (ty, a') = topAnn e'

                    ty' <-  if not $ isValue ty then do
                                reportError $ IllegalNonvalueType
                                    { offendingType = ty
                                    , errorLocation = a'
                                    }
                                pure unknownType
                            else pure ty

                    sym <- lookupSymbol i
                    g <- case sym of
                        Just (n, inf) -> case n of
                            0 -> do
                                _ <- typecheckAssignment
                                    (Fix (Ann builtinSpan $ Variable ident))
                                    e
                                    (Ann builtinSpan Assign)
                                pure $ symGid inf
                            _ -> do
                                g <- nextGid ident (defaultType ty') Local
                                declareSymbol i $ VariableInfo
                                    { symLocation = SourcePosition b
                                    , symType = defaultType ty'
                                    , symGid = g
                                    }
                                pure g
                        Nothing -> do
                            g <- nextGid ident (defaultType ty') Local
                            declareSymbol i $ VariableInfo
                                { symLocation = SourcePosition b
                                , symType = defaultType ty'
                                , symGid = g
                                }
                            pure g

                    pure $ (g, e')

                -- throwError $ GenericError (text $ show $ unzip ies)

                pure $ uncurry ShortVarDecl $ unzip ies

            Assignment exprs1 assignOp exprs2 -> do
                es <- forM (zip exprs1 exprs2) $ \(e1, e2) -> do
                    typecheckAssignment e1 e2 assignOp

                let (exprs1', exprs2') = unzip es
                pure $ Assignment exprs1' assignOp exprs2'

            PrintStmt exprs -> PrintStmt <$> forM exprs (\e -> do
                e' <- typecheckExpr e
                let (ty, b) = topAnn e'
                when (not $ isPrintable ty)
                    (reportError $ UnsatisfyingType
                        { unsatOffender = ty
                        , unsatReason = text "it is not printable, senpai"
                        , errorLocation = b
                        })
                pure e')

            ReturnStmt me -> let rty = funcTypeRet (unFix fty) in case me of
                Just e -> do
                    e' <- typecheckExpr e
                    let (ty, b) = topAnn e'

                    (rty, ty) <== TypeMismatch
                        { mismatchExpectedType = rty
                        , mismatchActualType = ty
                        , mismatchCause = Ann b (Just e')
                        , errorReason = text "the types are not assignment compatible"
                        }

                    when (rty == voidType)
                        (throwError $ WeederInvariantViolation
                                    $ text "Return with expr in void function")

                    pure $ ReturnStmt (Just e')

                Nothing -> do
                    when (rty /= voidType)
                        (throwError $ WeederInvariantViolation
                                    $ text "Return with no expr in non-void function")

                    pure $ ReturnStmt Nothing

            IfStmt minit cond thenBody melseBody -> withScope $ IfStmt
                <$> sequence minit
                <*> requireExprType
                    typedBoolType
                    (text "the guard of an if statement must be a boolean")
                    cond
                <*> (withScope $ sequence thenBody)
                <*> (withScope $ traverse sequence melseBody)

            SwitchStmt minit mcond cases -> withScope $ do
                minit' <- sequence minit
                mcond' <- forM mcond $
                            (\e -> do
                                e' <- typecheckExpr e
                                let (ty, a') = topAnn e'
                                if not $ isValue ty then do
                                    reportError $ IllegalNonvalueType
                                        { offendingType = ty
                                        , errorLocation = a'
                                        }
                                    -- Reconstruct an expression annotated
                                    -- with unknown type.
                                    pure $ replaceTopAnn
                                        (\(_, a'') -> (unknownType, a''))
                                        e'
                                else pure $ e')

                cases' <- forM cases $ \(hd, body) -> (,)
                    <$> typecheckCaseHead mcond' hd
                    <*> withScope (sequence body)
                pure $ SwitchStmt minit' mcond' cases'

            ForStmt minit mcond mstep body -> withScope $ ForStmt
                <$> sequence minit
                <*> sequence (requireExprType typedBoolType empty <$> mcond)
                <*> sequence mstep
                <*> sequence body

            IncDecStmt dir expr -> do
                expr' <- typecheckExpr expr
                if isArithmetic (unalias (fst (topAnn expr')))
                    then pure $ IncDecStmt dir expr'
                    else do
                        reportError UnsatisfyingType
                            { unsatOffender = fst (topAnn expr')
                            , unsatReason
                                = text "the expression to increment/decrement \
                                \must have arithmetic type"
                            , errorLocation = a
                            }
                        pure $ IncDecStmt dir expr'

            Block body -> withScope $ Block <$> sequence body

            BreakStmt -> pure BreakStmt
            ContinueStmt -> pure ContinueStmt
            FallthroughStmt -> pure FallthroughStmt
            EmptyStmt -> pure EmptyStmt

        typecheckCaseHead
            :: Maybe TySrcAnnExpr -- ^ The switch-expression in context.
            -> SrcAnnCaseHead
            -> Typecheck TySrcAnnCaseHead
        typecheckCaseHead mcond hd
            = case hd of
                CaseDefault -> pure CaseDefault
                CaseExpr exprs -> CaseExpr <$> case mcond of
                    Nothing -> mapM (requireExprType typedBoolType empty) exprs
                    Just e -> mapM (requireExprType (fst (topAnn e)) empty) exprs

typecheckAssignment
    :: SrcAnnExpr
    -> SrcAnnExpr
    -> SrcAnnAssignOp
    -> Typecheck (TySrcAnnExpr, TySrcAnnExpr)
typecheckAssignment e1 e2 (Ann aop op) = do
    e1' <- typecheckExpr e1
    let (ty, _) = topAnn e1'
    e2' <- requireExprType ty empty e2

    let bop = assignOpToBinOp op

    case bop of
        -- Occurs when we have a normal assignment. In this case we have nothing
        -- further to check.
        Nothing -> pure (e1', e2')
        -- Occurs when we have an assign-op. In this case we can check using the
        -- rules for the corresponding binary operation. The only difference
        -- between a = a `op` b and a `op=` b is that a is evaluated once in the
        -- second case - the same typing rules should apply.
        Just bop' -> do
            typecheckBinaryOp (Ann aop bop') e1' e2'
            pure (e1', e2')

{- | Typechecks a built-in. Each built-in has special rules governing it.
    Below are the expected function signatures for them.

    * append([]T, T) -> []T
    * cap([]T) -> int
    * cap([x]T) -> int
    * copy([]T, []T) -> int
    * len(string) -> int
    * len([]T) -> int
    * len([x]T) -> int
    * make(<type literal []T>, int, [int]) -> []T

    Note that for array or slice types, aliases work equally well.
-}
typecheckBuiltin
    :: SrcSpan -- ^ The source position of the builtin call
    -> BuiltinType
    -> Maybe TySrcAnnType
    -> [TySrcAnnExpr]
    -> Typecheck Type
typecheckBuiltin a b mty exprs = do
    when (b /= MakeType)
        (case mty of
            Nothing -> pure ()
            Just ty ->
                reportError $ TypeArgumentError
                    { errorReason = text "only make can take type arguments"
                    , errorLocation = snd (topAnn ty)
                    , typeArgument = Just (fst (topAnn ty))
                    })
    case b of
        AppendType -> withArgLengthCheck 2 a exprs (\_ ->
            let x = head exprs in
            let y = exprs !! 1 in
            let (tyx, ax) = topAnn x in
            let (tyy, ay) = topAnn y in
            case unFix $ unalias tyx of
                Ty.Slice tyx' -> do
                    -- We have []T and U, check T <== U.
                    (tyx', tyy) <== TypeMismatch
                        { mismatchExpectedType = tyx'
                        , mismatchActualType = tyy
                        , mismatchCause = Ann ay (Just y)
                        , errorReason = empty }

                    pure tyx
                -- First argument is not a slice.
                _ -> do
                        reportError $ TypeMismatch
                            { mismatchExpectedType = sliceType tyy
                            , mismatchActualType = tyx
                            , mismatchCause = Ann ax (Just x)
                            , errorReason = empty }

                        pure unknownType)

        CapType -> withArgLengthCheck 1 a exprs (\_ ->
            let x = head exprs in
            let (ty, ax) = topAnn x in
            case unFix $ unalias ty of
                Ty.Array _ _ -> pure typedIntType
                Ty.Slice _ -> pure typedIntType
                _ -> do
                    reportError $ TypeMismatch
                        { mismatchExpectedType =
                            typeSum [sliceType unknownType,
                                    arrayType 0 unknownType]
                        , mismatchActualType = ty
                        , mismatchCause = Ann ax (Just x)
                        , errorReason = empty }

                    -- The return type is always int.
                    pure typedIntType)

        CopyType -> withArgLengthCheck 2 a exprs (\_ ->
            let x = head exprs in
            let y = exprs !! 1 in
            let (tyx, ax) = topAnn x in
            let (tyy, ay) = topAnn y in
            case (unFix $ unalias tyx, unFix $ unalias tyy) of

                -- Normal case: two slices
                (Ty.Slice tyx', Ty.Slice tyy') -> do

                    -- We have copy([]T, []U). Check that T <== U, since the
                    -- first argument is the destination.
                    (tyx', tyy') <== TypeMismatch
                        { mismatchExpectedType = tyx'
                        , mismatchActualType = tyy'
                        , mismatchCause = Ann ay (Just y)
                        , errorReason = empty }
                    pure typedIntType

                -- Try to have some better error reporting in case we have
                -- a slice somewhere.
                (Ty.Slice _, _) ->
                    mismatchWithInt tyx tyy (Ann ay $ Just y)

                (_, Ty.Slice _) ->
                    mismatchWithInt tyy tyx (Ann ax $ Just x)

                -- Finally if we have no good match, have an error for each
                -- argument.
                (_, _) -> do
                    mismatchWithInt tyx (sliceType unknownType) (Ann ax $ Just x)
                    mismatchWithInt tyy (sliceType unknownType) (Ann ay $ Just y))

        LenType -> withArgLengthCheck 1 a exprs (\_ ->
            let x = head exprs in
            let (ty, ax) = topAnn x in
            case unFix $ unalias ty of
                Ty.Array _ _ -> pure typedIntType
                Ty.Slice _ -> pure typedIntType
                Ty.StringType _ -> pure typedIntType
                _ -> mismatchWithInt ty
                        (typeSum [ arrayType 0 unknownType
                                , sliceType unknownType
                                , stringType True])
                            -- This expected typed string could as well be
                            -- untyped. For error reporting we don't care.
                        (Ann ax $ Just x))

        -- In Golang, make() can take either two or three arguments in the case
        -- of a slice. In the interest of making this a bit simpler, we're
        -- going to enforce three arguments. If we were to support maps or
        -- channels we'd need to change this.
        MakeType -> do
            case mty of
                Nothing -> do
                    reportError $ TypeArgumentError
                        { errorReason = text "make requires a type argument"
                        , errorLocation = a
                        , typeArgument = Nothing
                        }
                    pure unknownType
                Just (Fix (Ann aTy ty)) ->
                    case ty of
                        SliceType _ ->
                            -- Note: this isn't really optimal for error messages,
                            -- since we'd expect 3 arguments, but one will be a type.
                            withArgLengthCheck 2 a exprs $ const $
                                let x = head exprs in
                                let y = exprs !! 1 in
                                let (tyx, ax) = topAnn x in
                                let (tyy, ay) = topAnn y in
                                case (unFix $ unalias tyx, unFix $ unalias tyy) of
                                    (Ty.IntType _, Ty.IntType _) -> pure (fst aTy)
                                    (x', y') -> do
                                        when (not $ isIntegral $ Fix y')
                                            (mismatchWithUnk tyy
                                                typedIntType (Ann ay $ Just y) $> ())
                                        when (not $ isIntegral $ Fix x')
                                            (mismatchWithUnk tyx
                                                typedIntType (Ann ax $ Just x) $> ())
                                        pure (fst aTy)
                        _ -> do
                            reportError $ UnsatisfyingType
                                { unsatOffender = fst aTy
                                , unsatReason = text "the type argument of make\
                                    \ should be a slice type"
                                , errorLocation = snd aTy }
                            pure unknownType
    where
        -- Checks that there are the specified number of arguments and, if yes,
        -- runs the given function, or reports an error if no.
        withArgLengthCheck n annot es f =
            if length es == n then
                f ()
            else do
                reportError $ ArgumentLengthMismatch
                    { argumentExpectedLength = n
                    , argumentActualLength = length es
                    , errorLocation = annot }
                pure unknownType

        -- Reports a type mismatch error, then returns the given type.
        mismatchWithTy expected actual cause ty = do
            reportError $ TypeMismatch
                { mismatchExpectedType = expected
                , mismatchActualType = actual
                , mismatchCause = cause
                , errorReason = empty }

            pure ty

        -- Reports a type mismatch error, then returns an unknown type
        mismatchWithUnk ex ac ca = mismatchWithTy ex ac ca unknownType

        -- Reports a type mismatch error, then returns a typed int type
        mismatchWithInt ex ac ca = mismatchWithTy ex ac ca typedIntType

-- | Typechecks a regular function call. See 'typecheckBuiltin' for
-- typechecking built-in functions.
--
-- Regular functions may not accept type arguments. The number of supplied
-- arguments must match the number of arguments in the function's signature.
-- Each expression's type must be assignment compatible to the declared type of
-- the formal parameter in the corresponding position of the function's
-- signature.
typecheckCall
    :: SrcSpan -- ^ The function call expression's source position
    -> Maybe TySrcAnnType -- ^ An optional type argument
    -> [TySrcAnnExpr] -- ^ The expression arguments
    -> [(SrcAnn Symbol (), Type)] -- ^ The arguments of the function
    -> Typecheck ()
typecheckCall pos tyArg exprs args = do
    case tyArg of
        Nothing -> pure ()
        Just (topAnn -> (t, a)) ->
            reportError $ TypeArgumentError
                { errorReason = text "regular functions cannot take type arguments"
                , errorLocation = a
                , typeArgument = Just t
                }

    matched <- case safeZip exprs args of
        (matched, excess) -> do
            case excess of
                Nothing -> pure ()
                Just _ ->
                    reportError $ ArgumentLengthMismatch
                        { argumentExpectedLength = length args
                        , argumentActualLength = length exprs
                        , errorLocation = pos
                        }

            pure matched

    forM_ (enumerate matched) $ \(i, (e, snd -> t)) -> do
        let (t', a) = topAnn e
        (t, t') <== CallTypeMismatch
            { mismatchExpectedType = t
            , mismatchActualType = t'
            , mismatchPosition = i
            , mismatchCause = Ann a (Just e)
            }

-- | Checks that an expression is assignment-compatible to a given type. If it
-- isn't a 'TypeMismatch' error is reported with the given reason.
requireExprType :: Type -> Doc -> SrcAnnExpr -> Typecheck TySrcAnnExpr
requireExprType t d e = do
    e' <- typecheckExpr e
    let (ty, b) = topAnn e'
    (t, ty) <== TypeMismatch
        { mismatchExpectedType = t
        , mismatchActualType = ty
        , mismatchCause = Ann b (Just e')
        , errorReason = d
        }
    pure e'

infixl 3 <==
-- | The assignment compatibility assertion operator, pronounced \"compat\"
-- verifies that the second type is assignment compatible to the first.
--
-- If it is compatible, then nothing happens.
-- If it isn't compatible, the provided error is reported.
-- Whether an error is reported or not is returned.
(<==) :: (Type, Type) -> TypeError -> Typecheck Bool
(<==) (t1, t2) e
    -- Special cases:
    -- Anything can be assigned to and from unknown type. This is because
    -- unknown type is generated only in the case of an error, so we don't
    -- want to generate extra errors on top of that.
    | t1 == Fix UnknownType || t2 == Fix UnknownType = pure False
    -- Nothing can be assigned to nil.
    | isNilType t1 = e'
    -- Nothing can be assigned to untyped constants.
    | isUntyped t1 = e'
    -- Functions cannot assign or be assigned.
    | isFuncType t1 || isFuncType t2 = e'
    -- Builtins cannot assign or be assigned.
    | isBuiltinType t1 || isBuiltinType t2 = e'
    -- End of special cases.

    -- (1.)
    | t1 == t2 = pure False
    | Fix (Struct fs1) <- t1
    , Fix (Struct fs2) <- t2
    , True <- cleanFields fs1 == cleanFields fs2
    = pure False
    -- (2.)
    | isReferenceType t1 && isNilType t2 = pure False
    -- (3.)
    | isUntyped t2
        = (t1, defaultType t2) <== e
    | otherwise = e'
    where
        e' = reportError e *> pure True
        cleanFields = map (\(i, m) -> (bare i, m))

{- Assignability
 - -------------

(Adapted from the Go specification.)

A value x is assignable to a variable of type T ("x is assignable to T") in any
of these cases:

 1. x's type is identical to T.
 2. x is the predeclared identifier nil and T is a pointer, function, slice,
    map, channel, or interface type.
 3. x is an untyped constant representable by a value of type T.
-}
