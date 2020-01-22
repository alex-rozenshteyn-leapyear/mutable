mutable
=======

Associate and generate "piecewise-mutable" versions for your composite data
types.  Think of it like a "generalized `MVector` for all ADTs".

Useful for a situation where you have a record with many fields (or many nested
records) that you want to use for efficient mutable in-place algorithms.  This
library lets you do efficient "piecewise" mutations (operations that only edit
one field), and also efficient entire-datatype copies/updates, as well, in many
cases.

Motivation
----------

### Piecewise-Mutable

For a simple motivating example where in-place piecewise mutations might be
better, consider a large vector.

Let's say you only want to edit the first item in a vector, multiple times.
This is extremely inefficient with a pure vector:

```haskell
addFirst :: Vector Double -> Vector Double
addFirst xs = iterate incr xs !! 1000000
  where
    incr v = v V.// [(0, (v V.! 0) + 1)]
```

That's because `addFirst` will copy over the entire vector for every step
--- every single item, even if not modified, will be copied one million times.
It is `O(n*l)` in memory updates --- it is very bad for long vectors or large
matrices.

However, this is extremely efficient with a mutable vector:

```haskell
addFirst :: Vector Double -> Vector Double
addFirst xs = runST $ do
    v <- V.thaw xs
    replicateM_ 1000000 $ do
        MV.modify v 0 (+ 1)
    V.freeze v
```

This is because all of the other items in the vector are kept the same and not
copied-over over the course of one million updates.  It is `O(n+l)` in memory
updates.  It is very good even for long vectors or large matrices.

(Of course, this situation is somewhat contrived, but it isolates a problem that
many programs face.  A more common situation might be that you have two
functions that each modify different items in a vector in sequence, and you
want to run them many times interleaved, or one after the other.)

Composite Datatype
------------------

That all works for `MVector`, but let's say you have a simple composite data
type that is two vectors:

```haskell
data TwoVec = TV { tv1 :: Vector Double
                 , tv2 :: Vector Double
                 }
  deriving Generic
```

Is there a nice "piecewise-mutable" version of this?  You *could* break up
`TwoVec` manually into its pieces and treat each piece independently, but that method
isn't composable.  If only there was some equivalent of `MVector` for
`TwoVec`...and some equivalent of `MV.modify`.

That's where this library comes in.

```haskell
instance PrimMonad m => Mutable m TwoVec where
    type Ref m TwoVec = GRef m TwoVec
```

Now we can write:

```haskell
addFirst :: TwoVec -> TwoVec
addFirst xs = runST $ do
    v <- thawRef xs
    replicateM_ 1000000 $ do
      withField #tv1 v $ \u ->
        MV.modify u 0 (+ 1)
    freezeRef v
```

This will in-place edit only the first item in the `tv1` field one million
times, without ever needing to copy over the contents `tv2`.  Basically, it
gives you a version of `TwoVec`  that you can modify in-place piecewise.  You
can compose two functions that each work piecewise on `TwoVec`:

```haskell
mut1 :: PrimMonad m => Ref m TwoVec -> m ()
mut1 v = do
    withField #tv1 v $ \u ->
      MV.modify u 0 (+ 1)
      MV.modify u 1 (+ 2)
    withField #tv2 v $ \u ->
      MV.modify u 2 (+ 3)
      MV.modify u 3 (+ 4)

mut2 :: PrimMonad m => Ref m TwoVec -> m ()
mut2 v = do
    withField #tv1 v $ \u ->
      MV.modify u 4 (+ 1)
      MV.modify u 5 (+ 2)
    withField #tv2 v $ \u ->
      MV.modify u 6 (+ 3)
      MV.modify u 7 (+ 4)

doAMillion :: TwoVec -> TwoVec
doAMillion xs = runST $ do
    v <- thawRef xs
    replicateM_ 1000000 $ do
      mut1 v
      mut2 v
    freezeRef v
```

This is a type of composition and interleaving that cannot be achieved by
simply breaking down `TwoVec` and running functions that work purely on each of
the two vectors individually.

Show me the numbers
-------------------

Here are some benchmark cases --- only bars of the same color are comparable,
and shorter bars are better (performance-wise).

![Benchmarks](https://i.imgur.com/frA5gXP.png)

There are four situations here, compared and contrasted between pure and
mutable versions

1.  A large ADT with 256 fields, generated by repeated nestings of `data V4 a =
    V4 !a !a !a !a`

    1.  Updating only a single part (one field out of 256)
    2.  Updating the entire ADT (all 256 fields)

2.  A composite data type of four `Vector`s of 500k elements each, so 2 million
    elements total.

    1.  Updating only a single part (one item out of 2 million)
    2.  Updating all elements of all four vectors (all 2 million items)

We can see four conclusions:

1.  For a large ADT, updating a single field (or multiple fields, interleaved)
    is going to be faster with *mutable*.
2.  For a large ADT, updating the whole ADT (so just replacing the entire
    thing, no actual copies) is faster just as a pure value by a large factor
    (which is a big testament to GHC).
3.  For a small ADT with huge vectors, updating a single field is *much* faster
    with *mutable*.
4.  For a small ADT with huge vectors, updating the entire value (so, the
    entire vectors and entire ADT) is actually faster with *mutable* as well.

Interestingly, the "update entire ADT" case (which should be the worst-case
for *mutable* and the best-case for pure values) actually becomes faster with
*mutable* when you get to the region of *many* values... somewhere between 256
and 2 million, apparently.
