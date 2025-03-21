module Vehicle.Verify
  ( VerifyOptions (..),
    VerifierID,
    verify,
  )
where

import Control.Monad.Trans (MonadIO, liftIO)
import Data.Hashable (Hashable (..))
import Data.Text.IO (hPutStrLn)
import System.Directory (doesFileExist, findExecutable)
import System.Exit (exitFailure)
import System.IO (stderr)
import System.IO.Temp (withSystemTempDirectory)
import Vehicle.Backend.Prelude (Task (..))
import Vehicle.Compile
import Vehicle.Prelude
import Vehicle.Resource
import Vehicle.Verify.Core
import Vehicle.Verify.ProofCache (ProofCache (..), writeProofCache)
import Vehicle.Verify.Specification.IO
import Vehicle.Verify.Verifier (verifiers)

data VerifyOptions = VerifyOptions
  { specification :: FilePath,
    properties :: PropertyNames,
    networkLocations :: NetworkLocations,
    datasetLocations :: DatasetLocations,
    parameterValues :: ParameterValues,
    verifierID :: VerifierID,
    verifierLocation :: Maybe VerifierExecutable,
    proofCache :: Maybe FilePath
  }
  deriving (Eq, Show)

verify :: LoggingSettings -> VerifyOptions -> IO ()
verify loggingSettings VerifyOptions {..} = do
  let verifierImpl = verifiers verifierID
  verifierExecutable <- locateVerifierExecutable verifierImpl verifierLocation
  let resources = Resources networkLocations datasetLocations parameterValues

  specificationHash <- hash <$> readSpecification specification

  status <- withSystemTempDirectory "specification" $ \tempDir -> do
    compile loggingSettings $
      CompileOptions
        { task = CompileToQueryFormat (verifierQueryFormat verifierImpl),
          specification = specification,
          declarationsToCompile = properties,
          networkLocations = networks resources,
          datasetLocations = datasets resources,
          parameterValues = parameters resources,
          outputFile = Just tempDir,
          moduleName = Nothing,
          proofCache = Nothing,
          noStdlib = False
        }

    verifySpecification verifierImpl verifierExecutable tempDir

  programOutput $ pretty status

  resourceSummaries <- liftIO $ hashResources resources
  case proofCache of
    Nothing -> return ()
    Just proofCachePath ->
      writeProofCache proofCachePath $
        ProofCache
          { proofCacheVersion = vehicleVersion,
            originalSpec = specification,
            originalSpecHash = specificationHash,
            originalProperties = properties,
            status = status,
            resourceSummaries = resourceSummaries
          }

-- | Tries to locate the executable for the verifier at the provided
-- location and falls back to the PATH variable if none provided. If not
-- found then the program will error.
locateVerifierExecutable ::
  MonadIO m =>
  Verifier ->
  Maybe VerifierExecutable ->
  m VerifierExecutable
locateVerifierExecutable Verifier {..} = \case
  Just providedLocation -> liftIO $ do
    exists <- doesFileExist providedLocation
    if exists
      then return providedLocation
      else do
        hPutStrLn stderr $
          layoutAsText $
            "No"
              <+> pretty verifierIdentifier
              <+> "executable found"
              <+> "at the provided location"
              <+> quotePretty providedLocation <> "."
        exitFailure
  Nothing -> do
    maybeLocationOnPath <- liftIO $ findExecutable verifierExecutableName
    case maybeLocationOnPath of
      Just locationOnPath -> return locationOnPath
      Nothing -> liftIO $ do
        hPutStrLn stderr $
          layoutAsText $
            "Could not locate the executable"
              <+> quotePretty verifierExecutableName
              <+> "via the PATH environment variable."
                <> line
                <> "Please either provide it using the `--verifierLocation` command line option"
              <+> "or add it to the PATH environment variable."
        liftIO exitFailure
