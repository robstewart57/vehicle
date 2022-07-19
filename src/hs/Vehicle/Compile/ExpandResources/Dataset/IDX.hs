module Vehicle.Compile.ExpandResources.Dataset.IDX
  ( readIDX
  ) where

import Control.Monad.IO.Class
import Control.Monad.Except
import Control.Monad.State
import Control.Exception
import Data.IDX
import Data.Map qualified as Map
import Data.Vector.Unboxed (Vector)
import Data.Vector.Unboxed qualified as Vector

import Vehicle.Compile.Prelude
import Vehicle.Compile.Error
import Vehicle.Language.Print
import Vehicle.Compile.ExpandResources.Core

-- | Reads the IDX dataset from the provided file, checking that the user type
-- matches the type of the stored data.
readIDX :: (MonadExpandResources m, MonadIO m)
        => FilePath
        -> DeclProvenance
        -> CheckedExpr
        -> m CheckedExpr
readIDX file decl expectedType = do
  contents <- readIDXFile decl file
  case contents of
    Nothing      -> throwError $ UnableToParseResource decl Dataset file
    Just idxData -> do
      let actualDimensions = Vector.toList $ idxDimensions idxData
      if isIDXIntegral idxData then do
        let elems = idxIntContent idxData
        let parser = intElemParser decl
        let ctx = (decl, expectedType, actualDimensions, parser)
        parseIDX ctx elems
      else do
        let elems = idxDoubleContent idxData
        let parser = doubleElemParser decl
        let ctx = (decl, expectedType, actualDimensions, parser)
        parseIDX ctx elems

readIDXFile :: (MonadCompile m, MonadIO m)
            => DeclProvenance
            -> FilePath
            -> m (Maybe IDXData)
readIDXFile decl file = do
  result <- liftIO $ try (decodeIDXFile file)
  case result of
    Right idxData  -> return idxData
    Left  ioExcept -> do
      throwError $ ResourceIOError decl Dataset ioExcept

-- WARNING: There appears to be a pernicious bug with the
-- current version of the HLS (VSCode plugin v2.2.0, HLS v1.7.0)
-- where the below function causes the IDE to start spinning forever shortly
-- after changing things in this file. Can't currently find a workaround.
parseIDX ::  ( MonadExpandResources m, Vector.Unbox a)
            => ParseContext m a
            -> Vector a
            -> m CheckedExpr
parseIDX ctx@(_, expectedDatasetType, actualDatasetDims, _) elems = do
  parseContainer ctx True actualDatasetDims elems expectedDatasetType

parseContainer :: (MonadExpandResources m, Vector.Unbox a)
               => ParseContext m a
               -> Bool
               -> [Int]
               -> Vector a
               -> CheckedExpr
               -> m CheckedExpr
parseContainer ctx topLevel actualDims elems expectedType = case expectedType of
  ListType   _ expectedElemType      -> parseList ctx expectedElemType actualDims elems
  TensorType _ expectedElemType dims -> case dims of
    SeqExpr _ _ _ expectedDims -> parseTensor ctx actualDims elems expectedElemType expectedDims
    _                          -> typingError ctx
  _ -> if topLevel
    then typingError ctx
    else parseElement ctx actualDims elems expectedType


parseTensor :: (MonadExpandResources m, Vector.Unbox a)
            => ParseContext m a
            -> [Int]
            -> Vector a
            -> CheckedExpr
            -> [CheckedExpr]
            -> m CheckedExpr
parseTensor ctx@(decl, _, _, _) actualDims elems expectedElemType expectedDims  =
  case (expectedDims, actualDims) of
    ([], _)       -> parseContainer ctx False actualDims elems expectedElemType
    (_, [])       -> dimensionMismatchError ctx
    (expectedDim : expectedDims', actualDim : actualDims') -> do

      currentDim <- case expectedDim of
        NatLiteralExpr _ _ n ->
          if n == actualDim
            then return actualDim
            else dimensionMismatchError ctx

        FreeVar _ dimIdent -> do
          implicitParams <- get
          let newEntry = (decl, Dataset, actualDim)
          case Map.lookup (nameOf dimIdent) implicitParams of
            Nothing       -> variableSizeError ctx expectedDim

            Just Nothing -> do
              modify (Map.insert (nameOf dimIdent) (Just newEntry))
              return actualDim

            Just (Just existingEntry@(_, _, value)) ->
              if value == actualDim
                then return value
                else throwError $ ImplicitParameterContradictory dimIdent existingEntry newEntry

        _ -> variableSizeError ctx expectedDim

      let rows = partitionData currentDim actualDims' elems
      rowExprs <- traverse (\es -> parseTensor ctx actualDims' es expectedElemType expectedDims' ) rows
      return $ mkTensor (snd decl) expectedElemType expectedDims rowExprs

parseList :: (MonadExpandResources m, Vector.Unbox a)
          => ParseContext m a
          -> CheckedExpr
          -> [Int]
          -> Vector a
          -> m CheckedExpr
parseList ctx@(decl, _, _, _) expectedElemType actualDims actualElems =
  case actualDims of
    []     -> dimensionMismatchError ctx
    d : ds -> do
      let splitElems = partitionData d ds actualElems
      exprs <- traverse (\es -> parseContainer ctx False ds es expectedElemType) splitElems
      return $ mkList (snd decl) expectedElemType exprs

parseElement :: (MonadExpandResources m, Vector.Unbox a)
             => ParseContext m a
             -> [Int]
             -> Vector a
             -> CheckedExpr
             -> m CheckedExpr
parseElement ctx@(_, _, _, elemParser) dims elems expectedType
  | not (null dims)          = dimensionMismatchError ctx
  | Vector.length elems /= 1 = compilerDeveloperError "Malformed IDX file: mismatch between dimensions and acutal data"
  | otherwise                = elemParser (Vector.head elems) expectedType

type ParseContext m a = (DeclProvenance, CheckedExpr, [Int], ElemParser m a)

type ElemParser m a = a -> CheckedExpr -> m CheckedExpr

doubleElemParser :: MonadExpandResources m
                 => DeclProvenance
                 -> ElemParser m Double
doubleElemParser decl value typeInProgram = do
  let p = freshProvenance decl
  case typeInProgram of
    RatType{} ->
      return $ RatLiteralExpr p typeInProgram (toRational value)
    _ -> do
      throwError $ DatasetTypeMismatch decl typeInProgram (RatType p)

intElemParser :: MonadExpandResources m
              => DeclProvenance
              -> ElemParser m Int
intElemParser decl value typeInProgram = do
  let p = freshProvenance decl
  case typeInProgram of
    ConcreteIndexType _ n ->
      if value >= 0 && value < n
        then return $ NatLiteralExpr p typeInProgram value
        else throwError $ DatasetInvalidIndex decl n value
    NatType{} ->
      if value >= 0
        then return $ NatLiteralExpr p typeInProgram value
        else throwError $ DatasetInvalidNat decl value
    IntType{} ->
      return $ IntLiteralExpr p typeInProgram value
    _ ->
      throwError $ DatasetTypeMismatch decl typeInProgram (IntType p)

-- | Split data by the first dimension of the C-Array.
partitionData :: Vector.Unbox a => Int -> [Int] -> Vector a -> [Vector a]
partitionData dim dims content = do
  let entrySize = product dims
  i <- [0 .. dim - 1]
  return $ Vector.slice (i * entrySize) entrySize content

freshProvenance :: DeclProvenance -> Provenance
freshProvenance (ident, _) = datasetProvenance (nameOf ident)

variableSizeError :: MonadCompile m => ParseContext m a -> CheckedExpr -> m b
variableSizeError (decl, _, _, _) dim =
  throwError $ DatasetVariableSizeTensor decl dim

dimensionMismatchError :: MonadCompile m => ParseContext m a -> m b
dimensionMismatchError (decl, expectedDatasetType, actualDatasetDims, _) =
  throwError $ DatasetDimensionMismatch decl expectedDatasetType actualDatasetDims

typingError :: MonadCompile m => ParseContext m a -> m b
typingError (_, expectedDatasetType, _, _) = compilerDeveloperError $
    "Invalid parameter type" <+> squotes (prettySimple expectedDatasetType) <+>
    "should have been caught during type-checking"