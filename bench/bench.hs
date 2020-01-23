{-# LANGUAGE BangPatterns                  #-}
{-# LANGUAGE DataKinds                     #-}
{-# LANGUAGE DeriveFoldable                #-}
{-# LANGUAGE DeriveFunctor                 #-}
{-# LANGUAGE DeriveGeneric                 #-}
{-# LANGUAGE DeriveTraversable             #-}
{-# LANGUAGE DerivingVia                   #-}
{-# LANGUAGE FlexibleContexts              #-}
{-# LANGUAGE FlexibleInstances             #-}
{-# LANGUAGE LambdaCase                    #-}
{-# LANGUAGE MultiParamTypeClasses         #-}
{-# LANGUAGE NumericUnderscores            #-}
{-# LANGUAGE OverloadedLabels              #-}
{-# LANGUAGE QuantifiedConstraints         #-}
{-# LANGUAGE RankNTypes                    #-}
{-# LANGUAGE ScopedTypeVariables           #-}
{-# LANGUAGE TemplateHaskell               #-}
{-# LANGUAGE TypeApplications              #-}
{-# LANGUAGE TypeApplications              #-}
{-# LANGUAGE TypeFamilies                  #-}
{-# LANGUAGE TypeOperators                 #-}
{-# OPTIONS_GHC -fno-warn-orphans          #-}
{-# OPTIONS_GHC -fno-warn-unused-top-binds #-}

import           Control.Category          ((.))
import           Control.DeepSeq
import           Control.Monad.ST
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Cont
import           Control.Monad.Trans.State
import           Criterion.Main
import           Criterion.Types
import           Data.Foldable
import           Data.Mutable
import           Data.Time
import           Data.Vector               (Vector)
import           Data.Vinyl.Functor
import           GHC.Generics
import           Lens.Micro
import           Lens.Micro.TH
import           Prelude hiding            ((.))
import           System.Directory
import qualified Data.Vector               as V
import qualified Data.Vector.Mutable       as MV

data V4 a = V4 { _v4X :: !a
               , _v4Y :: !a
               , _v4Z :: !a
               , _v4W :: !a
               }
  deriving (Show, Generic, Functor, Foldable, Traversable)

instance NFData a => NFData (V4 a)
instance Mutable m a => Mutable m (V4 a) where
    type Ref m (V4 a) = GRef m (V4 a)
instance Applicative V4 where
    pure x = V4 x x x x
    V4 a b c d <*> V4 x y z w = V4 (a x) (b y) (c z) (d w)
makeLenses 'V4

newtype V256 a = V256 { _v256 :: V4 (V4 (V4 (V4 a))) }
  deriving (Show, Generic, Functor, Foldable, Traversable)
  deriving Applicative via (V4 :.: V4 :.: V4 :.: V4)
instance NFData a => NFData (V256 a)
instance Mutable m a => Mutable m (V256 a) where
    type Ref m (V256 a) = CoerceRef m (V256 a) (V4 (V4 (V4 (V4 a))))
makeLenses 'V256

-- HKD variant of V4
data V4F a f = V4F { _vf4X :: !(f a)
                   , _vf4Y :: !(f a)
                   , _vf4Z :: !(f a)
                   , _vf4W :: !(f a)
                   }
  deriving (Show, Generic)
instance NFData (f a) => NFData (V4F a f)
instance Mutable m a => Mutable m (V4F a Identity) where
    type Ref m (V4F a Identity) = V4F a (RefFor m)

-- HKD variant of V256
newtype V256F a = V256F { _v256F :: V4F (V4F (V4F (V4F a Identity) Identity) Identity) Identity }
  deriving (Show, Generic)
instance NFData a => NFData (Identity a)
instance NFData a => NFData (V256F a)
instance Mutable m a => Mutable m (V256F a) where
    type Ref m (V256F a) = CoerceRef m (V256F a) (V4F (V4F (V4F (V4F a Identity) Identity) Identity) Identity)


type ADT  = V256 Double
type ADTF = V256F Double
type Vec  = V4  (Vector Double)
type VecF = V4F (Vector Double) Identity

pureLoop :: (a -> a) -> Int -> a -> a
pureLoop f n = go 0
  where
    go !i !x
      | i < n     = go (i + 1) (f x)
      | otherwise = x

modifyPartPure :: Int -> ADT -> ADT
modifyPartPure = pureLoop $ over (v256 . v4X . v4X . v4X . v4X) (+1)

modifyWholePure :: Int -> ADT -> ADT
modifyWholePure = pureLoop $ fmap (+ 1)

modifyPartPureV :: Int -> Vec -> Vec
modifyPartPureV = pureLoop $ over v4X $ \v -> v V.// [(0, (v V.! 0) + 1)]

modifyWholePureV :: Int -> Vec -> Vec
modifyWholePureV = pureLoop $ (fmap . fmap) (+ 1)




mutLoop :: (forall s. Mutable (ST s) a) => (forall s. Ref (ST s) a -> ST s ()) -> Int -> a -> a
mutLoop f n x0 = runST $ do
    r <- thawRef x0
    let go !i
          | i < n = do
              f r
              go (i + 1)
          | otherwise = pure ()
    go 0
    unsafeFreezeRef r

modifyPartMut :: (forall s. Mutable (ST s) a) => (forall s. MutPart (ST s) a Double) -> Int -> a -> a
modifyPartMut f = mutLoop $ \r -> modifyPart' f r (+1)

modifyWholeMut :: (forall s b. Mutable (ST s) b => Ref (ST s) (V4 b) -> ContT () (ST s) (Ref (ST s) b)) -> Int -> ADT -> ADT
modifyWholeMut f = mutLoop          $ \r ->
                     withAllRefV256 f r $ \s ->
                       modifyRef s (+ 1)

modifyWholeMutHKD :: Int -> ADTF -> ADTF
modifyWholeMutHKD = mutLoop          $ \r ->
                      withAllRefV256HKD r $ \s ->
                        modifyRef s (+ 1)

modifyPartMutV :: (forall s. Mutable (ST s) a) => (forall s. MutPart (ST s) a (Vector Double)) -> Int -> a -> a
modifyPartMutV f = mutLoop $ \r -> withPart f r $ \mv ->
                     (MV.write mv 0 $!) . (+ 1) =<< MV.read mv 0

modifyWholeMutV :: (forall s. Mutable (ST s) a) => (forall s. Ref (ST s) a -> ContT () (ST s) (MV.MVector s Double)) -> Int -> a -> a
modifyWholeMutV f = mutLoop $ \r -> runContT (f r) $ \mv -> do
    forM_ [0 .. MV.length mv - 1] $ \i ->
      (MV.write mv i $!) . (+ 1) =<< MV.read mv i

main :: IO ()
main = do
    t     <- getZonedTime
    let tstr = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" t
    createDirectoryIfMissing True "bench-results"
    defaultMainWith defaultConfig
          { reportFile = Just $ "bench-results/mutable-bench_" ++ tstr ++ ".html"
          , timeLimit  = 10
          } [
        bgroup "adt-256" [
          bgroup "part-50M"
            [ bench "pure"      $ nf (modifyPartPure                           50_000_000) bigADT
            -- , bench "mutable" $ nf (modifyPartMut (partRep (fieldMut #_v4X)) 50_000_000) bigADT
            , bgroup "mutable" [
                  bench "field" $ nf (modifyPartMut (partRep (fieldMut #_v4X)) 50_000_000) bigADT
                , bench "pos"   $ nf (modifyPartMut (partRep (posMut @1     )) 50_000_000) bigADT
                , bench "list"  $ nf (modifyPartMut (partRep firstList       ) 50_000_000) bigADT
                , bench "hkd"   $ nf (modifyPartMut modPartHKD                 50_000_000) bigADTF
                ]
            ]
        , bgroup "whole-20K"
            [ bench "pure"      $ nf (modifyWholePure                     20_000) bigADT
            -- , bench "mutable" $ nf (modifyWholeMut    withAllRefV4Field 20_000) bigADT
            , bgroup "mutable" [
                  bench "field" $ nf (modifyWholeMut    withAllRefV4Field 20_000) bigADT
                , bench "pos"   $ nf (modifyWholeMut    withAllRefV4Pos   20_000) bigADT
                , bench "list"  $ nf (modifyWholeMut    withAllRefV4List  20_000) bigADT
                , bench "hkd"   $ nf (modifyWholeMutHKD                   20_000) bigADTF
                ]
            ]
        ]
      , bgroup "vector-2M" [
          bgroup "part-100"
            [ bench "pure"      $ nf (modifyPartPureV                 100) bigVec
            -- , bench "mutable" $ nf (modifyPartMutV (fieldMut #_v4X) 100) bigVec
            , bgroup "mutable" [
                  bench "field" $ nf (modifyPartMutV (fieldMut #_v4X) 100) bigVec
                , bench "pos"   $ nf (modifyPartMutV (posMut @1     ) 100) bigVec
                , bench "list"  $ nf (modifyPartMutV (firstList     ) 100) bigVec
                , bench "hkd"   $ nf (modifyPartMutV  (_vf4X vfParts) 100) bigVecF
                ]
            ]
        , bgroup "whole-3"
            [ bench "pure"      $ nf (modifyWholePureV                  3) bigVec
            -- , bench "mutable" $ nf (modifyWholeMutV withAllRefV4Field 3) bigVec
            , bgroup "mutable" [
                  bench "field" $ nf (modifyWholeMutV withAllRefV4Field 3) bigVec
                , bench "pos"   $ nf (modifyWholeMutV withAllRefV4Pos   3) bigVec
                , bench "list"  $ nf (modifyWholeMutV withAllRefV4List  3) bigVec
                , bench "hkd"   $ nf (modifyWholeMutV withAllRefV4HKD   3) bigVecF
                ]
            ]
        ]
      ]
  where
    bigADT :: ADT
    !bigADT = populate $ pure ()
    bigADTF :: ADTF
    !bigADTF = toADTF bigADT
    bigVec :: Vec
    !bigVec = getCompose . populate . Compose $ pure (V.replicate 500_000 ())
    bigVecF :: VecF
    !bigVecF = toVF bigVec



toADTF :: ADT -> ADTF
toADTF = V256F
       . toVF . fmap (toVF . fmap (toVF . fmap toVF))
       . _v256

toVF :: V4 a -> V4F a Identity
toVF (V4 a b c d) = V4F (Identity a) (Identity b) (Identity c) (Identity d)

vfParts :: forall m a. Mutable m a => V4F a (MutPart m (V4F a Identity))
vfParts = hkdMutParts @(V4F a)

partRep :: Mutable m a => (forall b. Mutable m b => MutPart m (V4 b) b) -> MutPart m (V256 a) a
partRep f = f . f . f . f . coerceRef

firstList :: Mutable m a => MutPart m (V4 a) a
firstList = MutPart (\case x :!> _ -> x) . listMut

modPartHKD :: forall m a. Mutable m a => MutPart m (V256F a) a
modPartHKD = _vf4X vfParts
           . _vf4X vfParts
           . _vf4X vfParts
           . _vf4X vfParts
           . coerceRef



withAllRefV4Field :: Mutable m a => Ref m (V4 a) -> ContT () m (Ref m a)
withAllRefV4Field r = ContT $ \f -> do
    withPart (fieldMut #_v4X) r f
    withPart (fieldMut #_v4Y) r f
    withPart (fieldMut #_v4Z) r f
    withPart (fieldMut #_v4W) r f

withAllRefV4Pos :: Mutable m a => Ref m (V4 a) -> ContT () m (Ref m a)
withAllRefV4Pos r = ContT $ \f -> do
    withPart (posMut @1) r f
    withPart (posMut @2) r f
    withPart (posMut @3) r f
    withPart (posMut @4) r f

withAllRefV4List :: Mutable m a => Ref m (V4 a) -> ContT () m (Ref m a)
withAllRefV4List r = ContT         $ \f ->
                     withListMut r $ \(x :!> y :!> z :!> w :!> NilRef) -> do
      f x
      f y
      f z
      f w

withAllRefV4HKD :: forall m a. Mutable m a => V4F a (RefFor m) -> ContT () m (Ref m a)
withAllRefV4HKD r = ContT $ \f -> do
    withPart (_vf4X vfParts) r f
    withPart (_vf4Y vfParts) r f
    withPart (_vf4Z vfParts) r f
    withPart (_vf4W vfParts) r f

withAllRefV256
    :: Mutable m a
    => (forall b. Mutable m b => Ref m (V4 b) -> ContT () m (Ref m b))
    -> Ref m (V256 a)
    -> (Ref m a -> m ())
    -> m ()
withAllRefV256 a r f = flip runContT pure $ do
    s   <- a =<< a =<< a =<< a
       =<< ContT (withPart coerceRef r)
    lift $ f s


withAllRefV256HKD :: Mutable m a => Ref m (V256F a) -> (Ref m a -> m ()) -> m ()
withAllRefV256HKD r f = flip runContT pure $ do
    s   <- withAllRefV4HKD
       =<< withAllRefV4HKD
       =<< withAllRefV4HKD
       =<< withAllRefV4HKD
       =<< ContT (withPart coerceRef r)
    lift $ f s

populate :: Traversable f => f () -> f Double
populate = flip evalState 0 . traverse go
  where
    go _ = state $ \i -> (fromInteger i, i + 1)

