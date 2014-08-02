{-# LANGUAGE GeneralizedNewtypeDeriving, ViewPatterns, GADTs #-}
{-
Copyright (C) 2014 Matthew Pickering <matthewtpickering@gmail.com>

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

-}

module Text.TeXMath.Writers.TeXMath (writeTeXMath, writeTeXMathWith, addLaTeXEnvironment ) where

import Text.TeXMath.Types
import Text.TeXMath.Unicode.ToTeXMath (getTeXMath)
import Text.TeXMath.Unicode.ToUnicode (fromUnicode)
import qualified Text.TeXMath.Shared as S
import Data.Maybe (fromMaybe)
import Data.Generics (everywhere, mkT)
import Control.Applicative ((<$>), (<|>), Applicative)
import qualified Data.Map as M
import Control.Monad (when, unless)
import Control.Monad.Reader (MonadReader, runReader, Reader, asks, ask)
import Control.Monad.Writer( MonadWriter, WriterT,
                             execWriterT, tell, censor)
import Text.TeXMath.TeX

-- import Debug.Trace
-- tr' x = trace (show x) x

-- | Transforms an expression tree to equivalent LaTeX with the default
-- packages (amsmath and amssymb)
writeTeXMath :: [Exp] -> String
writeTeXMath = writeTeXMathWith defaultEnv

-- | Adds the correct LaTeX environment around a TeXMath fragment
addLaTeXEnvironment :: DisplayType -> String -> String
addLaTeXEnvironment dt math =
    case dt of
      DisplayInline -> "\\(" ++ math ++ "\\)"
      DisplayBlock  -> "\\[" ++ math ++ "\\]"

-- |  Transforms an expression tree to equivalent LaTeX with the specified
-- packages
writeTeXMathWith :: Env -> [Exp] -> String
writeTeXMathWith env e = drop 1 . init . flip renderTeX "" . Grouped $
                            runExpr env $
                              mapM_ writeExp (fixTree e)

runExpr :: Env -> Math () -> [TeX]
runExpr e m = flip runReader e $ execWriterT (runTeXMath m)

square :: [String]
square = ["\\sqrt", "\\surd"]

newtype Math a = Math {runTeXMath :: WriterT [TeX] (Reader Env) a}
                  deriving (Functor, Applicative, Monad, MonadReader Env
                           , MonadWriter [TeX])

getTeXMathM :: String -> Math [TeX]
getTeXMathM s = asks (getTeXMath s)

tellGroup :: Math () -> Math ()
tellGroup = censor ((:[]) . Grouped)

writeExp :: Exp -> Math ()
writeExp (ENumber s) = tell =<< getTeXMathM s
writeExp (EGrouped es) = tellGroup (mapM_ writeExp es)
writeExp (EDelimited "{" "" [Right (EArray [AlignDefault,AlignDefault] rows)]) =
  table "cases" [] [AlignDefault,AlignDefault] rows
writeExp (EDelimited "(" ")" [Right (EArray aligns rows)])
  | all (== AlignCenter) aligns =
  matrixWith "pmatrix" aligns rows
writeExp (EDelimited "[" "]" [Right (EArray aligns rows)])
  | all (== AlignCenter) aligns =
  matrixWith "bmatrix" aligns rows
writeExp (EDelimited "{" "}" [Right (EArray aligns rows)])
  | all (== AlignCenter) aligns =
  matrixWith "Bmatrix" aligns rows
writeExp (EDelimited "\x2223" "\x2223" [Right (EArray aligns rows)])
  | all (== AlignCenter) aligns =
  matrixWith "vmatrix" aligns rows
writeExp (EDelimited "\x2225" "\x2225" [Right  (EArray aligns rows)])
  | all (== AlignCenter) aligns =
  matrixWith "Vmatrix" aligns rows
writeExp (EDelimited open close es) =  do
  writeDelim DLeft open
  mapM_ (either (writeDelim DMiddle) writeExp) es
  writeDelim DRight close
writeExp (EIdentifier s) = do
  math <- getTeXMathM s
  case math of
       []      -> return ()
       [t]     -> tell [t]
       ts      -> tell [Grouped ts]
writeExp o@(EMathOperator s) = do
  math <- getTeXMathM s
  case S.getOperator o of
       Just op  -> tell [op]
       Nothing  -> tell [ControlSeq "\\operatorname", Grouped math]
writeExp (ESymbol Ord [c])  -- do not render "invisible operators"
  | c `elem` ['\x2061'..'\x2064'] = return () -- see 3.2.5.5 of mathml spec
writeExp (ESymbol t s) = do
  when (t == Bin || t == Rel) $ tell [Space]
  tell =<< getTeXMathM s
  when (t == Bin || t == Rel) $ tell [Space]
writeExp (ESpace width) = tell [ControlSeq $ getSpaceCommand width]
writeExp (EBinary s e1 e2) = do
  tell [ControlSeq s]
  if (s `elem` square)
    then do tell [Token '[']
            writeExp e1
            tell [Token ']']
    else tellGroup (writeExp e1)
  tellGroup (writeExp e2)
writeExp (ESub b e1) = do
  (if isFancy b then tellGroup else id) $ writeExp b
  tell [Token '_']
  tellGroup (writeExp e1)
writeExp (ESuper b e1) = do
  (if isFancy b then tellGroup else id) $ writeExp b
  tell [Token '^']
  tellGroup (writeExp e1)
writeExp (ESubsup b e1 e2) = do
  (if isFancy b then tellGroup else id) $ writeExp b
  tell [Token '_']
  tellGroup (writeExp e1)
  tell [Token '^']
  tellGroup (writeExp e2)
writeExp (EDown b e1) = do
  (if isFancy b then tellGroup else id) $ writeExp b
  tell [ControlSeq "\\limits", Token '_']
  tellGroup (writeExp e1)
writeExp (EUp b e1) = do
  (if isFancy b then tellGroup else id) $ writeExp b
  tell [ControlSeq "\\limits", Token '^']
  tellGroup (writeExp e1)
writeExp (EDownup b e1 e2) = do
  (if isFancy b then tellGroup else id) $ writeExp b
  tell [ControlSeq "\\limits", Token '_']
  tellGroup (writeExp e1)
  tell [Token '^']
  tellGroup (writeExp e2)
writeExp (EOver b e1) =
  case b of
    (EMathOperator _) -> writeExp (EUp b e1)
    (ESymbol Op _)    -> writeExp (EUp b e1)
    _ -> do
          tell [ControlSeq "\\overset"]
          tellGroup (writeExp e1)
          tellGroup (writeExp b)
writeExp (EUnder b e1) =
  case b of
    (EMathOperator _) -> writeExp (EDown b e1)
    (ESymbol Op _)    -> writeExp (EDown b e1)
    _ -> do
          tell [ControlSeq "\\underset"]
          tellGroup (writeExp e1)
          tellGroup (writeExp b)
writeExp (EUnderover b e1 e2) =
  case b of
    (EMathOperator _) -> writeExp (EDownup b e1 e2)
    (ESymbol Op _)    -> writeExp (EDownup b e1 e2)
    _ -> writeExp (EUnder (EOver b e2) e1)
writeExp (EUnary s e) = do
    tell [ControlSeq s]
    tellGroup (writeExp e)
writeExp (EScaled size e)
  | case e of
         (ESymbol Open _)  -> True
         (ESymbol Close _) -> True
         _ -> False = do
    case S.getScalerCommand size of
         Just s  -> tell [ControlSeq s]
         Nothing -> return ()
    writeExp e
  | otherwise = writeExp e
writeExp (EText ttype s) = do
  let txtcmd x =
         case ttype of
              TextNormal     -> [ControlSeq "\\text", x]
              TextItalic     -> [ControlSeq "\\textit", x]
              TextBold       -> [ControlSeq "\\textbf", x]
              TextMonospace  -> [ControlSeq "\\texttt", x]
              TextBoldItalic -> [ControlSeq "\\textit",
                                 Grouped [ControlSeq "\\textbf", x]]
              TextSansSerif  -> [ControlSeq "\\textsf", x]
              TextSansSerifBold -> [ControlSeq "\\textbf",
                                    Grouped [ControlSeq "\\textsf", x]]
              TextSansSerifItalic -> [ControlSeq "\\textit",
                                      Grouped [ControlSeq "\\textsf", x]]
              TextSansSerifBoldItalic -> [ControlSeq "\\textbf",
                                      Grouped [ControlSeq "\\textit",
                                        Grouped [ControlSeq "\\textsf", x]]]
              _  -> [ControlSeq "\\text", x]
  case map escapeLaTeX (fromUnicode ttype s) of
       []   -> return ()
       xs   -> tell $ txtcmd (Grouped xs)
writeExp (EStyled ttype es) = do
  txtcmd <- asks (flip S.getLaTeXTextCommand ttype)
  tell [ControlSeq txtcmd]
  tellGroup (mapM_ writeExp $ everywhere (mkT (fromUnicode ttype)) es)
writeExp (EArray [AlignRight, AlignLeft] rows) =
  table "aligned" [] [AlignRight, AlignLeft] rows
writeExp (EArray aligns rows)
  | all (== AlignCenter) aligns = table "matrix" [] aligns rows
  | otherwise                   = table "array" aligns aligns rows

table :: String -> [Alignment] -> [Alignment] -> [ArrayLine] -> Math ()
table name aligns origAligns rows = do
  env <- ask
  if "amsmath" `elem` env
     then table' name aligns rows
     else table' "array" origAligns rows

table' :: String -> [Alignment] -> [ArrayLine] -> Math ()
table' name aligns rows = do
  tell [ControlSeq "\\begin", Grouped [Literal name]]
  unless (null aligns) $
     tell [Grouped [Literal columnAligns]]
  tell [Token '\n']
  mapM_ row rows
  tell [ControlSeq "\\end", Grouped [Literal name]]
  where
    columnAligns = map alignmentToLetter aligns
    alignmentToLetter AlignLeft = 'l'
    alignmentToLetter AlignCenter = 'c'
    alignmentToLetter AlignRight = 'r'
    alignmentToLetter AlignDefault = 'l'

matrixWith :: String -> [Alignment] -> [ArrayLine] -> Math ()
matrixWith name aligns rows = table name' aligns' aligns rows
    where name' = if null aligns' then name else "array"
          aligns' = [a | a <- aligns, any (/= AlignCenter) aligns]

row :: ArrayLine -> Math ()
row []     = tell [Space, Literal "\\\\", Token '\n']
row [c]    = cell c >> row []
row (c:cs) = cell c >> tell [Space, Token '&', Space] >> row cs

cell :: [Exp] -> Math ()
cell = mapM_ writeExp

data FenceType = DLeft | DMiddle | DRight

type Delim = String

writeDelim :: FenceType -> Delim -> Math ()
writeDelim fence delim = do
    tex <- getTeXMathM delim
    valid <- elem tex <$> delimiters
    nullLim <- getTeXMathM "."
    let delimCmd = if valid then tex else nullLim
    tell $ case fence of
             DLeft -> [ControlSeq "\\left"] ++ delimCmd ++ [Space] ++ if valid then [] else tex
             DMiddle -> case valid of
                              True -> [Space] ++ [ControlSeq "\\middle"] ++ tex ++ [Space]
                              False -> tex 
             DRight -> [Space, ControlSeq "\\right"] ++ delimCmd ++ if valid then [] else tex

-- Utility

-- | Maps a length in em to the nearest bigger LaTeX space command
getSpaceCommand :: Double -> String
getSpaceCommand width = snd $ fromMaybe (M.findMax spaceMap) (lookupGE width spaceMap)
  where
    spaceMap = M.fromList (map (\(k, ESpace s) -> (s, k)) spaceCommands)

lookupGE :: Ord k =>  k -> M.Map k v -> Maybe (k, v)
lookupGE k m = let (_, v, g) = M.splitLookup k m in
                    (fmap ((,) k) (v <|> (fst <$> M.minView g)))

spaceCommands :: [(String, Exp)]
spaceCommands =
           [ ("\\!", ESpace (-0.167))
           , (""   , ESpace 0.0)
           , ("\\,", ESpace 0.167)
           , ("\\>", ESpace 0.222)
           , ("\\:", ESpace 0.222)
           , ("\\;", ESpace 0.278)
           , ("~", ESpace 0.333)
           , ("\\quad", ESpace 1.0)
           , ("\\qquad", ESpace 2.0)]

-- Commands which can be used with \left and \right
delimiters :: Math [[TeX]]
delimiters = do
    env <- ask
    let commands' = [ ".", "(", ")", "[", "]", "|", "\x2016", "{", "}"
                    , "\x2309", "\x2308", "\x2329", "\x232A"
                    , "\x230B", "\x230A", "\x231C", "\x231D"]
    return $ filter (not . null) (map (flip getTeXMath env) commands')

-- Fix up

reorderDiacritical' :: Position -> Exp -> Exp -> Exp
reorderDiacritical' p b e@(ESymbol Accent a) =
  case S.getDiacriticalCommand p a of
    Just accentCmd -> EUnary accentCmd b
    Nothing -> case p of
                    Over  -> EOver b e
                    Under -> EUnder b e
reorderDiacritical' _ _ _ = error "Must be called with Accent"

reorderDiacritical :: Exp -> Exp
reorderDiacritical (EOver b e@(ESymbol Accent _)) =
  reorderDiacritical' Over b e
reorderDiacritical (EUnder b e@(ESymbol Accent _)) =
  reorderDiacritical' Under b e
reorderDiacritical (EUnderover b e@(ESymbol Accent _) e1) =
  reorderDiacritical' Under (EOver b e1) e
reorderDiacritical (EUnderover b e1 e@(ESymbol Accent _)) =
  reorderDiacritical' Over (EUnder b e1) e
reorderDiacritical x = x

fixTree :: [Exp] -> [Exp]
fixTree (EGrouped -> es) =
    let removeGroup (EGrouped e) = e
        removeGroup e = [e] in
    removeGroup $ everywhere (mkT reorderDiacritical) es

isFancy :: Exp -> Bool
isFancy (ESub _ _) = True
isFancy (ESuper _ _) = True
isFancy (ESubsup _ _ _) = True
isFancy (EOver _ _) = True
isFancy (EUnder _ _) = True
isFancy (EUnderover _ _ _) = True
isFancy (EUp _ _) = True
isFancy (EDown _ _) = True
isFancy (EDownup _ _ _) = True
isFancy (EUnary _ _) = True
isFancy _ = False

