{-|
Module      : Language.GoLite.Syntax.Types.Ops
Description : Definitions and instances for operator syntax
Copyright   : (c) Jacob Errington and Frederic Lafrance, 2016
License     : MIT
Maintainer  : goto@mail.jerrington.me
Stability   : experimental
-}

{-# LANGUAGE DeriveFunctor #-}

module Language.GoLite.Syntax.Types.Ops where

import Language.GoLite.Pretty
import Language.GoLite.Syntax.Precedence


-- | A binary operator.
--
-- Derives Functor so that we can painlessly use "Language.GoLite.Annotation".
data BinaryOp a
    = LogicalOr | LogicalAnd
    | Equal | NotEqual | LessThan | LessThanEqual | GreaterThan | GreaterThanEqual
    | Plus | Minus | BitwiseOr | BitwiseXor
    | Times | Divide | Modulo
    | ShiftLeft | ShiftRight | BitwiseAnd | BitwiseAndNot
    deriving (Eq, Functor, Ord, Read, Show)

-- | Determines if a binary operator is a comparison operator (equal, not equal)
isComparisonOp :: BinaryOp a -> Bool
isComparisonOp o = o == Equal || o == NotEqual

-- | Determines if a
isOrderingOp :: BinaryOp a -> Bool
isOrderingOp o =  o == LessThan || o == LessThanEqual || o ==  GreaterThan
                || o == GreaterThanEqual

-- | Determines if a binary operator is a logical operator (or, and)
isLogicalOp :: BinaryOp a -> Bool
isLogicalOp o = o == LogicalOr || o == LogicalAnd

-- | Determines if a binary operator is an arithmetic operator (plus, multiply,
-- subtract, divide)
isArithmeticOp :: BinaryOp a -> Bool
isArithmeticOp o = o == Plus || o == Minus || o == Times || o == Divide

-- | Determines if a binary operator is integral. Integral operators can only be
-- applied to integral types. Modulo, shift and the bitwise operators are
-- integral.
isIntegralOp :: BinaryOp a -> Bool
isIntegralOp o = o == BitwiseOr || o == BitwiseXor || o == BitwiseAnd
    || o == BitwiseAndNot || o == Modulo || o == ShiftLeft || o == ShiftRight


-- | Associates a precedence with each binary operator.
instance HasPrecedence (BinaryOp a) where
    precedence o = case o of
        LogicalOr -> 0
        LogicalAnd -> 1
        GreaterThanEqual -> 2
        GreaterThan -> 2
        LessThanEqual -> 2
        LessThan -> 2
        NotEqual -> 2
        Equal -> 2
        BitwiseXor -> 3
        BitwiseOr -> 3
        Minus -> 3
        Plus -> 3
        BitwiseAndNot -> 4
        BitwiseAnd -> 4
        ShiftLeft -> 4
        ShiftRight -> 4
        Modulo -> 4
        Divide -> 4
        Times -> 4

-- | Lookup table.
instance Pretty (BinaryOp a) where
    pretty o = case o of
        LogicalOr -> text "||"
        LogicalAnd -> text "&&"
        Equal -> text "=="
        NotEqual -> text "!="
        LessThan -> text "<"
        LessThanEqual -> text "<="
        GreaterThan -> text ">"
        GreaterThanEqual -> text ">="
        Plus -> text "+"
        Minus -> text "-"
        BitwiseOr -> text "|"
        BitwiseXor -> text "^"
        Times -> text "*"
        Divide -> text "/"
        Modulo -> text "%"
        ShiftLeft -> text "<<"
        ShiftRight -> text ">>"
        BitwiseAnd -> text "&"
        BitwiseAndNot -> text "&^"

-- | A unary operator.
--
-- Derives Functor so that we can painlessly use "Language.GoLite.Annotation".
data UnaryOp a
    = Positive
    | Negative
    | LogicalNot
    | BitwiseNot
    | Dereference
    | Reference
    | Receive
    deriving (Eq, Functor, Ord, Read, Show)

-- | Associates a precedence with each unary operator.
instance HasPrecedence (UnaryOp a) where
    precedence o = case o of
        Receive -> 5
        Reference -> 5
        Dereference -> 5
        BitwiseNot -> 5
        LogicalNot -> 5
        Negative -> 5
        Positive -> 5

-- | Lookup table.
instance Pretty (UnaryOp a) where
    pretty o = case o of
        Positive -> text "+"
        Negative -> text "-"
        LogicalNot -> text "!"
        BitwiseNot -> text "^"
        Dereference -> text "*"
        Reference -> text "&"
        Receive -> text "<-"

-- | An assignment operator.
--
-- Derives Functor so that we can painlessly use "Language.GoLite.Annotation".
data AssignOp a
    = Assign
    | PlusEq | MinusEq | BitwiseOrEq | BitwiseXorEq
    | TimesEq | DivideEq | ModuloEq
    | ShiftLeftEq | ShiftRightEq | BitwiseAndEq | BitwiseAndNotEq
    deriving (Eq, Functor, Ord, Read, Show)

-- | From a given assign-op, obtains the corresponding binary op, if one exists.
-- If not, Nothing is returned.
assignOpToBinOp :: AssignOp a -> Maybe (BinaryOp a)
assignOpToBinOp PlusEq = Just Plus
assignOpToBinOp MinusEq = Just Minus
assignOpToBinOp BitwiseOrEq = Just BitwiseOr
assignOpToBinOp BitwiseXorEq = Just BitwiseXor
assignOpToBinOp TimesEq = Just Times
assignOpToBinOp DivideEq = Just Divide
assignOpToBinOp ModuloEq = Just Modulo
assignOpToBinOp ShiftLeftEq = Just ShiftLeft
assignOpToBinOp ShiftRightEq = Just ShiftRight
assignOpToBinOp BitwiseAndEq = Just BitwiseAnd
assignOpToBinOp BitwiseAndNotEq = Just BitwiseAndNot
assignOpToBinOp _ = Nothing

-- | Lookup table.
instance Pretty (AssignOp a) where
    pretty o = case o of
        Assign -> text "="
        PlusEq -> text "+="
        MinusEq -> text "-="
        BitwiseOrEq -> text "|="
        BitwiseXorEq -> text "^="
        TimesEq -> text "*="
        DivideEq -> text "/="
        ModuloEq -> text "%="
        ShiftLeftEq -> text "<<="
        ShiftRightEq -> text ">>="
        BitwiseAndEq -> text "&="
        BitwiseAndNotEq -> text "&^="
