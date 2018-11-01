module Sound.Tidal.Transition where

import Control.Concurrent.MVar (readMVar)

import qualified Sound.OSC.FD as O
import qualified Data.Map.Strict as Map
import Data.Maybe (fromJust)

import Sound.Tidal.Core
import Sound.Tidal.Params (gain, pan)
import Sound.Tidal.Pattern
import Sound.Tidal.Stream
import Sound.Tidal.Tempo (timeToCycles)
import Sound.Tidal.UI (fadeOutFrom)
import Sound.Tidal.Utils (enumerate)

transition :: Show a => Stream -> (Time -> [ControlPattern] -> ControlPattern) -> a -> ControlPattern -> IO ()
transition stream f patId pat = do pMap <- readMVar (sPMapMV stream)
                                   let match = Map.lookup (show patId) pMap
                                   transition' match
  where
    transition' (Just playState) = do let context = pat:(pattern playState):(history playState)
                                      tempo <- readMVar $ sTempoMV stream
                                      now <- O.time
                                      let c = timeToCycles tempo now
                                      streamReplace stream patId $ f c context
    transition' Nothing = putStrLn $ "No such pattern: " ++ show patId



{-| Washes away the current pattern after a certain delay by applying a
    function to it over time, then switching over to the next pattern to
    which another function is applied.
-}
wash :: (Pattern a -> Pattern a) -> (Pattern a -> Pattern a) -> Time -> Time -> Time -> Time -> [Pattern a] -> Pattern a
wash _ _ _ _ _ _ [] = silence
wash _ _ _ _ _ _ (pat:[]) = pat
wash fout fin delay durin durout now (pat:pat':_) =
   stack [(filterWhen (< (now + delay)) pat'),
          (filterWhen (between (now + delay) (now + delay + durin)) $ fout pat'),
          (filterWhen (between (now + delay + durin) (now + delay + durin + durout)) $ fin pat),
          (filterWhen (>= (now + delay + durin + durout)) $ pat)
         ]
 where
   between lo hi x = (x >= lo) && (x < hi)

xfadeIn :: Time -> Time -> [ControlPattern] -> ControlPattern
xfadeIn _ _ [] = silence
xfadeIn _ _ (pat:[]) = pat
xfadeIn t now (pat:pat':_) = overlay (pat |*| gain (now `rotR` (_slow t envEqR))) (pat' |*| gain (now `rotR` (_slow t (envEq))))

-- | Pans the last n versions of the pattern across the field
histpan :: Int -> Time -> [ControlPattern] -> ControlPattern
histpan _ _ [] = silence
histpan 0 _ _ = silence
histpan n _ ps = stack $ map (\(i,pat) -> pat # pan (pure $ (fromIntegral i) / (fromIntegral n'))) (enumerate ps')
  where ps' = take n ps
        n' = length ps' -- in case there's fewer patterns than requested

-- | Just stop for a bit before playing new pattern
wait :: Time -> Time -> [ControlPattern] -> ControlPattern
wait _ _ [] = silence
wait t now (pat:_) = filterWhen (>= (nextSam (now+t-1))) pat

{- | Just as `wait`, `waitT` stops for a bit and then applies the given transition to the playing pattern

@
d1 $ sound "bd"

t1 (waitT (xfadeIn 8) 4) $ sound "hh*8"
@
-}
waitT :: (Time -> [ControlPattern] -> ControlPattern) -> Time -> Time -> [ControlPattern] -> ControlPattern
waitT _ _ _ [] = silence
waitT f t now pats = filterWhen (>= (nextSam (now+t-1))) (f (now + t) pats)

{- |
Jumps directly into the given pattern, this is essentially the _no transition_-transition.

Variants of @jump@ provide more useful capabilities, see @jumpIn@ and @jumpMod@
-}
jump :: Time -> [ControlPattern] -> ControlPattern
jump = jumpIn 0

{- | Sharp `jump` transition after the specified number of cycles have passed.

@
t1 (jumpIn 2) $ sound "kick(3,8)"
@
-}
jumpIn :: Int -> Time -> [ControlPattern] -> ControlPattern
jumpIn n = wash id id (fromIntegral n) 0 0

{- | Unlike `jumpIn` the variant `jumpIn'` will only transition at cycle boundary (e.g. when the cycle count is an integer).
-}
jumpIn' :: Int -> Time -> [ControlPattern] -> ControlPattern
jumpIn' n now = wash id id ((nextSam now) - now + (fromIntegral n)) 0 0 now

-- | Sharp `jump` transition at next cycle boundary where cycle mod n == 0
jumpMod :: Int -> Time -> [ControlPattern] -> ControlPattern
jumpMod n now = jumpIn ((n-1) - ((floor now) `mod` n)) now

-- | Degrade the new pattern over time until it ends in silence
mortal :: Time -> Time -> Time -> [ControlPattern] -> ControlPattern
mortal _ _ _ [] = silence
mortal lifespan release now (p:_) = overlay (filterWhen (<(now+lifespan)) p) (filterWhen (>= (now+lifespan)) (fadeOutFrom (now + lifespan) release p))


interpolate :: Time -> [ControlPattern] -> ControlPattern
interpolate = interpolateIn 4

interpolateIn :: Time -> Time -> [ControlPattern] -> ControlPattern
interpolateIn _ _ [] = silence
interpolateIn _ _ (p:[]) = p
interpolateIn t now (p:p':_) = do n <- now `rotR` (_slow t envL)
                                  combineV (mixNums n) <$> p <*> p'
  where mixNums v (VF a) (VF b) = VF $ (a * v) + (b * (1-v))
        mixNums v (VI a) (VI b) = VI $ floor $ (fromIntegral a * v) + (fromIntegral b * (1-v))
        mixNums _ _ b = b
        combineV :: (Value -> Value -> Value) -> ControlMap -> ControlMap -> ControlMap
        combineV f a b = Map.mapWithKey pairUp a
          where pairUp k v | Map.notMember k b = v
                           | otherwise = f v (fromJust $ Map.lookup k b)
