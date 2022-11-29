module Vehicle.Compile
  ( CompileOptions(..)
  , compile
  , compileToAgda
  , compileToVerifier
  , typeCheck
  , typeCheckExpr
  , parseAndTypeCheckExpr
  , readSpecification
  ) where

import Control.Exception (IOException, catch)
import Control.Monad.IO.Class (MonadIO (..))
import Data.Set (Set)
import Data.Text as T (Text)
import Data.Text.IO qualified as TIO

import Control.Monad.Except (MonadError (..), runExcept)
import Vehicle.Backend.Agda
import Vehicle.Backend.LossFunction (LDecl, writeLossFunctionFiles)
import Vehicle.Backend.LossFunction qualified as LossFunction
import Vehicle.Backend.Prelude
import Vehicle.Compile.Dependency.Analysis
import Vehicle.Compile.Error
import Vehicle.Compile.Error.Message
import Vehicle.Compile.ExpandResources
import Vehicle.Compile.Prelude as CompilePrelude
import Vehicle.Compile.Queries (QueryData, compileToQueries)
import Vehicle.Compile.Resource
import Vehicle.Compile.Scope (scopeCheck, scopeCheckClosedExpr)
import Vehicle.Compile.Type (typeCheck, typeCheckExpr)
import Vehicle.Expr.Normalised
import Vehicle.Syntax.Parse
import Vehicle.Verify.Specification
import Vehicle.Verify.Specification.IO
import Vehicle.Verify.Verifier (verifiers)
import Vehicle.Verify.Verifier.Interface

data CompileOptions = CompileOptions
  { target                :: Backend
  , specification         :: FilePath
  , declarationsToCompile :: DeclarationNames
  , networkLocations      :: NetworkLocations
  , datasetLocations      :: DatasetLocations
  , parameterValues       :: ParameterValues
  , outputFile            :: Maybe FilePath
  , moduleName            :: Maybe String
  , proofCache            :: Maybe FilePath
  } deriving (Eq, Show)

compile :: LoggingSettings -> CompileOptions -> IO ()
compile loggingSettings CompileOptions{..} = do
  let resources = Resources networkLocations datasetLocations parameterValues
  spec <- readSpecification specification
  case target of
    TypeCheck -> do
      _ <- fromLoggedEitherIO loggingSettings $ typeCheckProg spec declarationsToCompile
      return ()

    ITP Agda -> do
      let agdaOptions = AgdaOptions proofCache outputFile moduleName
      agdaCode <- compileToAgda loggingSettings agdaOptions spec declarationsToCompile resources
      writeAgdaFile outputFile agdaCode

    VerifierBackend verifierIdentifier -> do
      let verifier = verifiers verifierIdentifier
      compiledSpecification <- compileToVerifier loggingSettings spec declarationsToCompile resources verifier
      case outputFile of
        Nothing     -> outputSpecification compiledSpecification
        Just folder -> writeSpecificationFiles verifier folder compiledSpecification

    LossFunction differentiableLogic -> do
      lossFunction <- compileToLossFunction loggingSettings spec declarationsToCompile resources differentiableLogic
      writeLossFunctionFiles outputFile differentiableLogic lossFunction


--------------------------------------------------------------------------------
-- Backend-specific compilation functions

compileToVerifier :: LoggingSettings
                  -> SpecificationText
                  -> PropertyNames
                  -> Resources
                  -> Verifier
                  -> IO (Specification QueryData)
compileToVerifier loggingSettings spec properties resources verifier =
  fromLoggedEitherIO loggingSettings $ do
    (prog, propertyCtx, networkCtx, _) <- typeCheckProgAndLoadResources spec properties resources
    compileToQueries verifier prog propertyCtx networkCtx


compileToLossFunction :: LoggingSettings
                      -> SpecificationText
                      -> DeclarationNames
                      -> Resources
                      -> DifferentiableLogic
                      -> IO [LDecl]
compileToLossFunction loggingSettings spec declarationsToCompile resources differentiableLogic = do
  fromLoggedEitherIO loggingSettings $ do
    (prog, propertyCtx, networkCtx, _) <- typeCheckProgAndLoadResources spec declarationsToCompile resources
    LossFunction.compile differentiableLogic prog propertyCtx networkCtx

compileToAgda :: LoggingSettings
              -> AgdaOptions
              -> SpecificationText
              -> PropertyNames
              -> Resources
              -> IO (Doc a)
compileToAgda loggingSettings agdaOptions spec properties _resources =
  fromLoggedEitherIO loggingSettings $ do
    (prog, propertyCtx, _) <- typeCheckProg spec properties
    compileProgToAgda (fmap unnormalised prog) propertyCtx agdaOptions

--------------------------------------------------------------------------------
-- Useful functions that apply multiple compiler passes

readSpecification :: MonadIO m => FilePath -> m SpecificationText
readSpecification inputFile = do
  liftIO $ TIO.readFile inputFile `catch` \ (e :: IOException) ->
    outputErrorAndQuit $ "Error occured while reading input file:" <+> line <>
      indent 2 (pretty (show e))

parseAndTypeCheckExpr :: MonadCompile m => Text -> m CheckedExpr
parseAndTypeCheckExpr expr = do
  vehicleExpr <- parseExprText expr
  scopedExpr  <- scopeCheckClosedExpr vehicleExpr
  typedExpr   <- typeCheckExpr scopedExpr
  return typedExpr

-- | Parses and type-checks the program but does
-- not load networks and datasets from disk.
typeCheckProg :: MonadCompile m
              => SpecificationText
              -> DeclarationNames
              -> m (GluedProg, PropertyContext, DependencyGraph)
typeCheckProg spec declarationsToCompile = do
  (vehicleProg, uncheckedPropertyCtx) <- parseProgText spec
  (scopedProg, dependencyGraph) <- scopeCheck vehicleProg
  prunedProg <- analyseDependenciesAndPrune scopedProg uncheckedPropertyCtx dependencyGraph declarationsToCompile
  (typedProg, propertyContext) <- typeCheck prunedProg uncheckedPropertyCtx
  return (typedProg, propertyContext, dependencyGraph)

-- | Parses, expands parameters and datasets, type-checks and then
-- checks the network types from disk. Used during compilation to
-- verification queries.
typeCheckProgAndLoadResources :: (MonadIO m, MonadCompile m)
                              => SpecificationText
                              -> DeclarationNames
                              -> Resources
                              -> m (CheckedProg, PropertyContext, NetworkContext, DependencyGraph)
typeCheckProgAndLoadResources spec declarationsToCompile resources = do
  (typedProg, propertyCtx, depGraph) <- typeCheckProg spec declarationsToCompile
  (networkCtx, finalProg) <- expandResources resources True typedProg
  return (finalProg, propertyCtx, networkCtx, depGraph)

parseExprText :: MonadCompile m => Text -> m InputExpr
parseExprText txt =
  case runExcept (parseExpr =<< readExpr txt) of
    Left  err  -> throwError $ ParseError err
    Right expr -> return expr

parseProgText :: MonadCompile m => Text -> m (InputProg, Set Identifier)
parseProgText txt = do
  case runExcept (readAndParseProg txt) of
    Left err                 -> throwError $ ParseError err
    Right (prog, properties) -> case traverse parseExpr prog of
      Left err    -> throwError $ ParseError err
      Right prog' -> return (prog', properties)
