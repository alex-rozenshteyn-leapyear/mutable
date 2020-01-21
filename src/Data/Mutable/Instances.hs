{-# LANGUAGE BangPatterns          #-}
{-# LANGUAGE DeriveFoldable        #-}
{-# LANGUAGE DeriveFunctor         #-}
{-# LANGUAGE DeriveGeneric         #-}
{-# LANGUAGE DeriveTraversable     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE LambdaCase            #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE TypeInType            #-}
{-# LANGUAGE TypeOperators         #-}
{-# LANGUAGE UndecidableInstances  #-}
{-# OPTIONS_GHC -fno-warn-orphans  #-}

module Data.Mutable.Instances (
    ListRefCell(..)
  , unconsListRef, consListRef
  , RecRef(..)
  ) where

import           Control.Monad.Primitive
import           Data.Coerce
import           Data.Complex
import           Data.Foldable
import           Data.Functor
import           Data.Mutable.Internal
import           Data.Primitive.MutVar
import           Data.Ratio
import           Data.Vinyl                    as V
import           Data.Vinyl.Functor
import           Foreign.Storable
import           GHC.Generics
import qualified Data.Vector                   as V
import qualified Data.Vector.Generic           as VG
import qualified Data.Vector.Mutable           as MV
import qualified Data.Vector.Primitive         as VP
import qualified Data.Vector.Primitive.Mutable as MVP
import qualified Data.Vector.Storable          as VS
import qualified Data.Vector.Storable.Mutable  as MVS
import qualified Data.Vector.Unboxed           as VU
import qualified Data.Vector.Unboxed.Mutable   as MVU
import qualified Data.Vinyl.ARec               as V
import qualified Data.Vinyl.TypeLevel          as V

instance PrimMonad m => Mutable m Int
instance PrimMonad m => Mutable m Integer
instance PrimMonad m => Mutable m (Ratio a)
instance PrimMonad m => Mutable m Float
instance PrimMonad m => Mutable m Double
instance PrimMonad m => Mutable m (Complex a)
instance PrimMonad m => Mutable m Bool

-- | Single linked list cell
data ListRefCell m a = MutNil
                     | MutCons (Ref m a) (Ref m [a])

-- | Uncons mutable linked list into a 'ListRefCell'.
unconsListRef
    :: PrimMonad m
    => Ref m [a]
    -> m (ListRefCell m a)
unconsListRef (GRef (M1 (Comp1 x))) = readMutVar x <&> \case
    L1 _ -> MutNil
    R1 (M1 (M1 (K1 y) :*: M1 (K1 z))) -> MutCons y z

-- | Cons the contents of a 'ListRefCell' into a mutable linked list.
consListRef
    :: PrimMonad m
    => ListRefCell m a
    -> m (Ref m [a])
consListRef lrc = GRef . M1 . Comp1 <$> newMutVar go
  where
    go = case lrc of
      MutNil       -> L1 . M1 $ U1
      MutCons x xs -> R1 . M1 $ M1 (K1 x) :*: M1 (K1 xs)

-- | Mutable linked list with mutable references in each cell.  See
-- 'unconsListRef' and 'consListRef' for ways to directly work with this
-- type as a mutable linked list.
instance (PrimMonad m, Mutable m a) => Mutable m [a] where
    type Ref m [a] = GRef m [a]

-- | Similar to 'MutRef', this allows you to overwrite the normal 'Mutable'
-- instance for a type to utilize its 'Traversable' instance instead of its
-- normal instance.
--
-- For example, the instance of @'Mutable' ('TraverseMut' [] a)@ is
-- a normal list of mutable references, instead of a full-on mutable linked
-- list.
newtype TraverseMut f a = TraverseMut { getTraverseMut :: f a }
  deriving (Show, Eq, Ord, Generic, Functor, Foldable, Traversable)

instance (Traversable f, Mutable m a) => Mutable m (TraverseMut f a) where
    type Ref m (TraverseMut f a) = TraverseRef m (TraverseMut f) a

instance Mutable m a => Mutable m (Identity a) where
    type Ref m (Identity a) = RefFor m a
    thawRef (Identity x) = RefFor <$> thawRef x
    freezeRef (RefFor r) = Identity <$> freezeRef r
    copyRef (RefFor r) (Identity x) = copyRef r x

-- | Mutable reference is 'MV.MVector'.
instance PrimMonad m => Mutable m (V.Vector a) where
    type Ref m (V.Vector a) = MV.MVector (PrimState m) a
    thawRef   = VG.thaw
    freezeRef = VG.freeze
    copyRef   = VG.copy

-- | Mutable reference is 'MVS.MVector'.
instance (PrimMonad m, Storable a) => Mutable m (VS.Vector a) where
    type Ref m (VS.Vector a) = MVS.MVector (PrimState m) a
    thawRef   = VG.thaw
    freezeRef = VG.freeze
    copyRef   = VG.copy

-- | Mutable reference is 'MVU.MVector'.
instance (PrimMonad m, VU.Unbox a) => Mutable m (VU.Vector a) where
    type Ref m (VU.Vector a) = MVU.MVector (PrimState m) a
    thawRef   = VG.thaw
    freezeRef = VG.freeze
    copyRef   = VG.copy

-- | Mutable reference is 'MVP.MVector'.
instance (PrimMonad m, MVP.Prim a) => Mutable m (VP.Vector a) where
    type Ref m (VP.Vector a) = MVP.MVector (PrimState m) a
    thawRef   = VG.thaw
    freezeRef = VG.freeze
    copyRef   = VG.copy

instance Monad m => Mutable m () where
    type Ref m () = ()
    thawRef   _ = pure ()
    freezeRef _ = pure ()
    copyRef _ _ = pure ()

instance (Monad m, Mutable m a, Mutable m b) => Mutable m (a, b) where
    type Ref m (a, b) = (Ref m a, Ref m b)
    thawRef   (!x, !y) = (,) <$> thawRef x   <*> thawRef y
    freezeRef (u , v ) = (,) <$> freezeRef u <*> freezeRef v
    copyRef   (u , v ) (!x, !y) = copyRef u x *> copyRef v y

instance (Monad m, Mutable m a, Mutable m b, Mutable m c) => Mutable m (a, b, c) where
    type Ref m (a, b, c) = (Ref m a, Ref m b, Ref m c)
    thawRef   (!x, !y, !z) = (,,) <$> thawRef x   <*> thawRef y   <*> thawRef z
    freezeRef (u , v , w ) = (,,) <$> freezeRef u <*> freezeRef v <*> freezeRef w
    copyRef   (u , v , w ) (!x, !y, !z) = copyRef u x *> copyRef v y *> copyRef w z

instance (Monad m, Mutable m a, Mutable m b, Mutable m c, Mutable m d) => Mutable m (a, b, c, d) where
    type Ref m (a, b, c, d) = (Ref m a, Ref m b, Ref m c, Ref m d)
    thawRef   (!x, !y, !z, !a) = (,,,) <$> thawRef x   <*> thawRef y   <*> thawRef z   <*> thawRef a
    freezeRef (u , v , w , j ) = (,,,) <$> freezeRef u <*> freezeRef v <*> freezeRef w <*> freezeRef j
    copyRef   (u , v , w , j ) (!x, !y, !z, !a) = copyRef u x *> copyRef v y *> copyRef w z *> copyRef j a

-- | 'Ref' for components in a vinyl 'Rec'.
newtype RecRef m f a = RecRef { getRecRef :: Ref m (f a) }

instance Monad m => Mutable m (Rec f '[]) where
    type Ref m (Rec f '[]) = Rec (RecRef m f) '[]
    thawRef   _ = pure RNil
    freezeRef _ = pure RNil
    copyRef _ _ = pure ()

instance (Monad m, Mutable m (f a), Mutable m (Rec f as), Ref m (Rec f as) ~ Rec (RecRef m f) as) => Mutable m (Rec f (a ': as)) where
    type Ref m (Rec f (a ': as)) = Rec (RecRef m f) (a ': as)
    thawRef   = \case
      x :& xs -> (:&) <$> (RecRef <$> thawRef x) <*> thawRef xs
    freezeRef = \case
      RecRef v :& vs -> (:&) <$> freezeRef v <*> freezeRef vs
    copyRef = \case
      RecRef v :& vs -> \case
        x :& xs -> copyRef v x >> copyRef vs xs

instance (Monad m, RecApplicative as, V.NatToInt (V.RLength as), RPureConstrained (V.IndexableField as) as, Mutable m (Rec f as), Ref m (Rec f as) ~ Rec (RecRef m f) as) => Mutable m (ARec f as) where
    type Ref m (ARec f as) = ARec (RecRef m f) as

    thawRef   = fmap toARec . thawRef   . fromARec
    freezeRef = fmap toARec . freezeRef . fromARec
    copyRef r x = copyRef (fromARec r) (fromARec x)

