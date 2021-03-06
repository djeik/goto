{-|
Module      : Language.Vigil
Description : Core Vigil module
Copyright   : (c) Jacob Errington and Frederic Lafrance, 2016
License     : MIT
Maintainer  : goto@mail.jerrington.me
Stability   : experimental

This module merely reexports the most important submodules for dealing with
Vigil code.
-}

{-# LANGUAGE OverloadedStrings #-}

module Language.Vigil
( module Language.Vigil.Syntax
, module Language.Vigil.Syntax.TyAnn
, module Language.Vigil.SimplifyTraversal
, module Language.Vigil.Simplify
) where

import Language.Vigil.Syntax
import Language.Vigil.Syntax.TyAnn
import Language.Vigil.SimplifyTraversal
import Language.Vigil.Simplify
