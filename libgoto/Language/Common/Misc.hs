{-|
Module      : Language.Common.Misc
Description : Stuff that fits nowhere else.
Copyright   : (c) Jacob Errington and Frederic Lafrance, 2016
License     : MIT
Maintainer  : goto@mail.jerrington.me
Stability   : experimental

Defines miscellaneous useful functions. We won't kid ourselves by calling this
module \"Util\".
-}

{-# LANGUAGE TupleSections #-}

module Language.Common.Misc
( ($>)
, safeZip
, distTuple
, unFix
, enumerate
, bun
, bun'
, whenM
, sequence2
, sequence3
, fmap2
  -- * Convenience re-exports
, isJust
, isNothing
) where

import Control.Monad ( when )
import Data.Functor.Foldable ( Fix(..) )
import Data.Maybe ( isJust, isNothing )

-- | The \"fmap const\" operator replaces the contents of a "Functor" with a
-- given value.
($>) :: Functor f => f a -> b -> f b
f $> c = fmap (const c) f

-- | Zips two lists and returns the part that would have been truncated.
safeZip :: [a] -> [b] -> ([(a, b)], Maybe (Either [a] [b]))
safeZip [] [] = ([], Nothing)
safeZip [] ys = ([], Just $ Right ys)
safeZip xs [] = ([], Just $ Left xs)
safeZip (x:xs) (y:ys) = ((x, y) : xys, z) where
    (xys, z) = safeZip xs ys

distTuple :: [a] -> b -> [(a, b)]
distTuple = flip $ \x -> map (, x)

unFix :: Fix f -> f (Fix f)
unFix (Fix x) = x

-- | Enumerates the elements of a list, starting at 1.
enumerate :: [a] -> [(Int, a)]
enumerate = zip [1..]

whenM :: Monad m => m Bool -> m () -> m ()
whenM mb m = flip when m =<< mb

-- | Near-dual of @nub@. Keeps only the elements of a list that have already
-- been seen before in the list.
bun :: Eq a => [a] -> [a]
bun = bun' elem

-- | Same as "bun" but with a user-supplied \"contains\" function.
bun' :: (a -> [a] -> Bool) -> [a] -> [a]
bun' in_ x = fst $ foldr (\c a -> ( if c `in_` (snd a) then c:(fst a) else fst a
                              , c:(snd a)))
                    ([], [])
                    x

sequence2
    :: (Monad m, Traversable t, Traversable t1)
    => t (t1 (m a)) -> m (t (t1 a))
sequence2 = sequence . fmap sequence

sequence3
    :: (Monad m, Traversable t, Traversable t1, Traversable t2)
    => t (t1 (t2 (m a))) -> m (t (t1 (t2 a)))
sequence3 = sequence2 . fmap (fmap sequence)

fmap2 :: (Functor f, Functor g) => (a -> b) -> f (g a) -> f (g b)
fmap2 f = fmap (fmap f)
