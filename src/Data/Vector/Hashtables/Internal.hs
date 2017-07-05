{-# LANGUAGE RecordWildCards, BangPatterns #-}
module Data.Vector.Hashtables.Internal where

import Data.Bits
import Data.Hashable
import qualified Data.Vector.Generic.Mutable as V
import Data.Vector.Generic.Mutable (MVector)
import qualified Data.Vector.Storable.Mutable as S
import qualified Data.Vector.Unboxed as UI
import Data.Maybe
import Control.Monad.Primitive
import Data.Primitive.MutVar

type IntArray s = S.MVector s Int

newtype Dictionary s ks k vs v = DRef { getDRef :: MutVar s (Dictionary_ s ks k vs v) }

data Dictionary_ s ks k vs v = Dictionary {
    hashCode, 
    next, 
    buckets,
    refs :: IntArray s,
    key :: ks s k,
    value :: vs s v
}

getCount, getFreeList, getFreeCount :: Int
getCount = 0
getFreeList = 1
getFreeCount = 2

(!) :: (MVector v a, PrimMonad m) => v (PrimState m) a -> Int -> m a
(!) = V.unsafeRead

(<~) :: (MVector v a, PrimMonad m) => v (PrimState m) a -> Int -> a -> m ()
(<~) = V.unsafeWrite

initialize :: (MVector ks k, MVector vs v, PrimMonad m) 
           => Int -> m (Dictionary (PrimState m) ks k vs v)
initialize capacity = do
    let size = getPrime capacity
    hashCode <- V.replicate size 0
    next <- V.replicate size 0
    key <- V.new size
    value <- V.new size
    buckets <- V.replicate size (-1)
    refs <- V.replicate 3 0
    refs <~ 1 $ -1
    dr <- newMutVar Dictionary {..}
    return . DRef $ dr

at :: (MVector ks k, MVector vs v, PrimMonad m, Hashable k, Eq k) 
     => Dictionary (PrimState m) ks k vs v -> k -> m v
at d k = do
    i <- findEntry d k
    if i >= 0
        then do
            Dictionary{..} <- readMutVar . getDRef $ d
            value ! i
        else error "KeyNotFoundException!"
{-# INLINE at #-}

findEntry :: (MVector ks k, MVector vs v, PrimMonad m, Hashable k, Eq k) 
          => Dictionary (PrimState m) ks k vs v -> k -> m Int
findEntry d key' = do
    Dictionary{..} <- readMutVar . getDRef $ d
    let hashCode' = hash key' .&. 0x7FFFFFFFFFFFFFFF
        go i | i >= 0 = do
                hc <- hashCode ! i
                if hc == hashCode'
                    then do
                        k <- key ! i
                        if k == key'
                            then return i
                            else go =<< next ! i
                    else go =<< next ! i
             | otherwise = return $ -1
    go =<< buckets ! (hashCode' `rem` V.length buckets)
{-# INLINE findEntry #-}

insert :: (MVector ks k, MVector vs v, PrimMonad m, Hashable k, Eq k) 
       => Dictionary (PrimState m) ks k vs v -> k -> v -> m ()
insert d key' value' = do
    Dictionary{..} <- readMutVar . getDRef $ d
    let
        hashCode' = hash key' .&. 0x7FFFFFFFFFFFFFFF
        targetBucket = hashCode' `rem` V.length buckets

        go i    | i >= 0 = do
                    hc <- hashCode ! i
                    if hc == hashCode'
                        then do
                            k  <- key ! i
                            if k == key'
                                then value <~ i $ value'
                                else go =<< next ! i
                        else go =<< next ! i
                | otherwise = addOrResize

        addOrResize = do
            freeCount <- refs ! getFreeCount
            if freeCount > 0
                then do
                    index <- refs ! getFreeList
                    nxt <- next ! index
                    refs <~ getFreeList $ nxt
                    refs <~ getFreeCount $ freeCount - 1
                    add index targetBucket
                else do
                    count <- refs ! getCount
                    refs <~ getCount $ count + 1
                    if count == V.length next
                        then error "resize"
                            -- return $ count & (hashCode' `rem` V.length buckets)
                        else add (fromIntegral count) (fromIntegral targetBucket)

        add !index !targetBucket = do
            hashCode <~ index $ hashCode'
            b <- buckets ! targetBucket
            next <~ index $ b
            key <~ index $ key'
            value <~ index $ value'
            buckets <~ targetBucket $ index

    go =<< buckets ! targetBucket

{-# INLINE insert #-}

primes :: UI.Vector Int
primes = UI.fromList [
    3, 7, 11, 17, 23, 29, 37, 47, 59, 71, 89, 107, 131, 163, 197, 239, 293, 353, 431, 521, 631,
    761, 919, 1103, 1327, 1597, 1931, 2333, 2801, 3371, 4049, 4861, 5839, 7013, 8419, 10103, 12143,
    14591, 17519, 21023, 25229, 30293, 36353, 43627, 52361, 62851, 75431, 90523, 108631, 130363,
    156437, 187751, 225307, 270371, 324449, 389357, 467237, 560689, 672827, 807403, 968897,
    1162687, 1395263, 1674319, 2009191, 2411033, 2893249, 3471899, 4166287, 4999559, 5999471,
    7199369, 8639249, 10367101, 12440537, 14928671, 17914409, 21497293, 25796759, 30956117,
    37147349, 44576837, 53492207, 64190669, 77028803, 92434613, 110921543, 133105859, 159727031,
    191672443, 230006941, 276008387, 331210079, 397452101, 476942527, 572331049, 686797261,
    824156741, 988988137, 1186785773, 1424142949, 1708971541, 2050765853 ]

getPrime :: Int -> Int
getPrime n = fromJust $ UI.find (>= n) primes