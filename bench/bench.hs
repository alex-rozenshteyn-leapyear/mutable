{-# LANGUAGE BangPatterns                  #-}
{-# LANGUAGE DeriveFoldable                #-}
{-# LANGUAGE DeriveFunctor                 #-}
{-# LANGUAGE DeriveGeneric                 #-}
{-# LANGUAGE DeriveTraversable             #-}
{-# LANGUAGE DerivingVia                   #-}
{-# LANGUAGE FlexibleContexts              #-}
{-# LANGUAGE FlexibleInstances             #-}
{-# LANGUAGE MultiParamTypeClasses         #-}
{-# LANGUAGE NumericUnderscores            #-}
{-# LANGUAGE OverloadedLabels              #-}
{-# LANGUAGE QuantifiedConstraints         #-}
{-# LANGUAGE RankNTypes                    #-}
{-# LANGUAGE TemplateHaskell               #-}
{-# LANGUAGE TypeFamilies                  #-}
{-# LANGUAGE TypeOperators                 #-}
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
import           Data.Functor.Compose
import           Data.Mutable
import           Data.Time
import           Data.Vector (Vector)
import           GHC.Generics
import           Lens.Micro
import           Lens.Micro.TH
import           Prelude hiding            ((.))
import           System.Directory
import qualified Data.Vector               as V
import qualified Data.Vector.Mutable as MV

data V4 a = V4 { _v4X :: !a
               , _v4Y :: !a
               , _v4Z :: !a
               , _v4W :: !a
               }
  deriving (Show, Generic, Functor, Foldable, Traversable)

instance NFData a => NFData (V4 a)
instance Mutable m a => Mutable m (V4 a) where
    type Ref m (V4 a) = GRef m (V4 a)

makeLenses 'V4

instance Applicative V4 where
    pure x = V4 x x x x
    V4 a b c d <*> V4 x y z w = V4 (a x) (b y) (c z) (d w)

newtype V256 a = V256 { _v256 :: V4 (V4 (V4 (V4 a))) }
  deriving (Show, Generic, Functor, Foldable, Traversable)
  deriving Applicative via (V4 :.: V4 :.: V4 :.: V4)

instance NFData a => NFData (V256 a)
instance Mutable m a => Mutable m (V256 a) where
    type Ref m (V256 a) = CoerceRef m (V256 a) (V4 (V4 (V4 (V4 a))))

makeLenses 'V256

type ADT = V256 Double
type Vec = V4 (Vector Double)

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
    freezeRef r

modifyPartMut :: Int -> ADT -> ADT
modifyPartMut = mutLoop $ \r -> modifyPart' modPart r (+1)

modifyWholeMut :: Int -> ADT -> ADT
modifyWholeMut = mutLoop          $ \r ->
                   withAllRefV256 r $ \s ->
                     modifyRef s (+ 1)

-- modifyWholeMut' :: Int -> ADT -> ADT
-- modifyWholeMut' = mutLoop          $ \r ->
--                   withAllRefV16 r $ \s ->
--                     modifyRef s ((fmap . fmap) (+ 1))

modifyPartMutV :: Int -> Vec -> Vec
modifyPartMutV = mutLoop $ \r -> withMutPart (fieldMut #_v4X) r $ \mv ->
                    (MV.write mv 0 $!) . (+ 1) =<< MV.read mv 0

modifyWholeMutV :: Int -> Vec -> Vec
modifyWholeMutV = mutLoop $ \r -> withAllRefV4 r $ \mv -> do
    forM_ [0 .. MV.length mv - 1] $ \i ->
      (MV.write mv i $!) . (+ 1) =<< MV.read mv i

main :: IO ()
main = do
    t     <- getZonedTime
    let tstr = formatTime defaultTimeLocale "%Y%m%d-%H%M%S" t
    createDirectoryIfMissing True "bench-results"
    defaultMainWith defaultConfig
          { reportFile = Just $ "bench-results/mutable-bench_" ++ tstr ++ ".html"
          , timeLimit  = 30
          } [
        bgroup "adt-256" [
          bgroup "part-50M"
            [ bench "pure"    $ nf (modifyPartPure 50_000_000) bigADT
            , bench "mutable" $ nf (modifyPartMut  50_000_000) bigADT
            ]
        , bgroup "whole-20K"
            [ bench "pure"    $ nf (modifyWholePure 20_000) bigADT
            , bench "mutable" $ nf (modifyWholeMut  20_000) bigADT
            ]
        ]
      , bgroup "vector-2M" [
          bgroup "part-100"
            [ bench "pure"    $ nf (modifyPartPureV 100) bigVec
            , bench "mutable" $ nf (modifyPartMutV  100) bigVec
            ]
        , bgroup "whole-3"
            [ bench "pure"    $ nf (modifyWholePureV 3) bigVec
            , bench "mutable" $ nf (modifyWholeMutV  3) bigVec
            ]
        ]

      ]
  where
    bigADT :: ADT
    !bigADT = populate $ pure ()
    bigVec :: Vec
    !bigVec = getCompose . populate . Compose $ pure (V.replicate 500_000 ())




modPart :: Mutable m a => MutPart m (V256 a) a
modPart = fieldMut #_v4X
        . fieldMut #_v4X
        . fieldMut #_v4X
        . fieldMut #_v4X
        . coerceRef

withAllRefV4 :: Mutable m a => Ref m (V4 a) -> (Ref m a -> m ()) -> m ()
withAllRefV4 r f = do
    withMutPart (fieldMut #_v4X) r f
    withMutPart (fieldMut #_v4Y) r f
    withMutPart (fieldMut #_v4Z) r f
    withMutPart (fieldMut #_v4W) r f

-- withAllRefV16 :: Mutable m a => Ref m (V256 a) -> (Ref m (V4 (V4 a)) -> m ()) -> m ()
-- withAllRefV16 r f = flip runContT pure $ do
--     s   <- ContT . withAllRefV4
--        =<< ContT . withAllRefV4
--        =<< ContT (withMutPart coerceRef r)
--     lift $ f s

withAllRefV256 :: Mutable m a => Ref m (V256 a) -> (Ref m a -> m ()) -> m ()
withAllRefV256 r f = flip runContT pure $ do
    s   <- ContT . withAllRefV4
       =<< ContT . withAllRefV4
       =<< ContT . withAllRefV4
       =<< ContT . withAllRefV4
       =<< ContT (withMutPart coerceRef r)
    lift $ f s

populate :: Traversable f => f () -> f Double
populate = flip evalState 0 . traverse go
  where
    go _ = state $ \i -> (fromInteger i, i + 1)
