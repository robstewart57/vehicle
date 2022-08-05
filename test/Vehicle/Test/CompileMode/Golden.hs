module Vehicle.Test.CompileMode.Golden
  ( functionalityTests
  , performanceTests
  , goldenTestSpecifications
  , goldenTestDirectory
  , goldenFilepathSuffix
  ) where

import Control.Exception ( catch, throwIO )
import Data.Text (Text)
import Data.Text qualified as T
import Data.Text.IO qualified as T
import Data.Bifunctor (first)
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (mapMaybe)
import System.Exit (exitFailure)
import System.FilePath (takeFileName, splitPath, (<.>), (</>))
import System.Directory (removeFile, removeDirectory)
import System.IO.Error (isDoesNotExistError)

import Vehicle
import Vehicle.Prelude
import Vehicle.Compile
import Vehicle.Backend.Prelude

import Test.Tasty
import Test.Tasty.Golden.Advanced (goldenTest)
import Test.Tasty.Bench (Benchmark, bench, nfIO)

import Vehicle.Test.Utils

--------------------------------------------------------------------------------
-- Tests

functionalityTests :: MonadTest m => m TestTree
functionalityTests = testGroup "GoldenTests" <$>
  traverse makeFunctionalityTests goldenTestSpecifications

performanceTests :: TestTree
performanceTests = testGroup "GoldenTests" $
  fmap makePerformanceTests goldenTestSpecifications

--------------------------------------------------------------------------------
-- Specifications

goldenTestSpecifications :: [TestSpec]
goldenTestSpecifications =
  -- Worked examples
  [ testSpec
      { testName       = "windController"
      , testLocation   = Examples
      , testTargets    = [AgdaBackend, MarabouBackend]
      }

  , testSpec
      { testName       = "acasXu"
      , testLocation   = Examples
      , testTargets    = [AgdaBackend, MarabouBackend]
      }

  , testSpec
      { testName       = "mnist-robustness"
      , testLocation   = Examples
      , testTargets    = [AgdaBackend]
      , testDatasets   = [ ("trainingImages", "test-images-5.idx")
                         , ("trainingLabels", "test-labels-5.idx")
                         ]
      , testParameters = [ ("epsilon", "0.1") ]
      }

  -- Realistic tests
  , testSpec
      { testName       = "andGate"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend, MarabouBackend]
      }

  , testSpec
      { testName       = "autoencoderError"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend, MarabouBackend]
      }

  , testSpec
      { testName       = "increasing"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend, MarabouBackend]
      }

  , testSpec
      { testName       = "monotonicity"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend, MarabouBackend]
      }

  , testSpec
      { testName       = "reachability"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend, MarabouBackend]
      }
  {-
  , testSpec
      { testName       = "bounded"
      , testLocation   = Tests
      , testTargets    = [LossFunction]
      }
  -}
  -- Simple tests of Vehicle syntax
  , testSpec
      { testName       = "simple-quantifier"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend, MarabouBackend]
      }

  , testSpec
      { testName       = "simple-quantifierIn"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend]
      }

  , testSpec
      { testName       = "simple-let"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend]
      }

  , testSpec
      { testName       = "simple-if"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend, MarabouBackend]
      }

  , testSpec
      { testName       = "simple-untypedDecls"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend]
      }

  , testSpec
      { testName       = "simple-constantInput"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend, MarabouBackend]
      }

  , testSpec
      { testName       = "simple-arithmetic"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend]
      }

  , testSpec
      { testName       = "simple-tensor"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend, MarabouBackend]
      }

  , testSpec
      { testName       = "simple-index"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend]
      }
  {-
  , testSpec
      { testName       = "simple-implicitParam"
      , testLocation   = Tests
      , testTargets    = [MarabouBackend]
      , testDatasets   = [("d", "dataset-rat-4.idx")]
      }
  -}
  , testSpec
      { testName       = "simple-gaussianElim"
      , testLocation   = Tests
      , testTargets    = [MarabouBackend]
      }

  , testSpec
      { testName       = "simple-fourierMotzkin"
      , testLocation   = Tests
      , testTargets    = [MarabouBackend]
      }

  , testSpec
      { testName       = "simple-foreach"
      , testLocation   = Tests
      , testTargets    = [MarabouBackend]
      }

  , testSpec
      { testName       = "simple-generalisedVariables"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend]
      }
  {-
  , testSpec
      { testName       = "simple-vectorType"
      , testLocation   = Tests
      , testTargets    = [AgdaBackend]
      }
  -}
  ]

--------------------------------------------------------------------------------
-- Functionality tests

makeFunctionalityTests :: MonadTest m => TestSpec -> m TestTree
makeFunctionalityTests spec@TestSpec{..} = do
  let resources = testResources spec
  let makeTest = makeIndividualTest testLocation testName resources
  testGroup testName <$> traverse makeTest testTargets

makeIndividualTest :: MonadTest m
                   => TestLocation
                   -> String
                   -> Resources
                   -> Backend
                   -> m TestTree
makeIndividualTest location name datasets backend = do
  loggingSettings <- getTestLoggingSettings

  let testName       = name <> "-" <> layoutAsString (pretty backend)
  let filePathSuffix = goldenFilepathSuffix backend
  let moduleName     = name <> "-output"
  let inputFile      = locationDir location name </> name <.> ".vcl"
  let outputFile     = goldenTestDirectory </> name </> name <> "-temp-output" <> filePathSuffix
  let goldenFile     = goldenTestDirectory </> name </> name <> "-output"      <> filePathSuffix
  let isFolderOutput = backend == MarabouBackend

  let run = runVehicle loggingSettings inputFile outputFile moduleName backend datasets
  let testFn = if isFolderOutput then goldenDirectoryTest else goldenFileTest
  return $ testFn testName run omitFilePaths goldenFile outputFile

--------------------------------------------------------------------------------
-- Performance tests

makePerformanceTests :: TestSpec -> TestTree
makePerformanceTests spec@TestSpec{..} = do
  let resources = testResources spec
  let makeTest = makePerformanceTest testLocation testName resources
  testGroup testName $ fmap makeTest testTargets

makePerformanceTest :: TestLocation
                    -> String
                    -> Resources
                    -> Backend
                    -> TestTree
makePerformanceTest location name datasets backend = do
  let loggingSettings = (Nothing, 0)

  let testName       = name <> "-" <> layoutAsString (pretty backend)
  let filePathSuffix = goldenFilepathSuffix backend
  let moduleName     = name <> "-output"
  let inputFile      = locationDir location name </> name <.> ".vcl"
  let outputFile     = goldenTestDirectory </> name </> name <> "-temp-output" <> filePathSuffix

  let run = runVehicle loggingSettings inputFile outputFile moduleName backend datasets
  let runAndClean = do run; cleanupOutput (backend /= MarabouBackend) outputFile
  bench testName (nfIO runAndClean)

--------------------------------------------------------------------------------
-- Utils

goldenTestDirectory :: FilePath
goldenTestDirectory = baseTestDir </> "CompileMode" </> "Golden"

goldenFilepathSuffix :: Backend -> String
goldenFilepathSuffix = \case
  Verifier Marabou -> "-marabou"
  ITP Agda         -> ".agda"
  LossFunction     -> ".json"
  TypeCheck        -> ""

runVehicle :: TestLoggingSettings
           -> FilePath
           -> FilePath
           -> String
           -> Backend
           -> Resources
           -> IO ()
runVehicle (logFile, debugLevel) inputFile outputFile moduleName backend Resources{..} = do
  run $ Options
    { version     = False
    , outFile     = Nothing
    , errFile     = Nothing
    , logFile     = logFile
    , debugLevel  = debugLevel
    , modeOptions = Compile $ CompileOptions
      { target            = backend
      , specificationFile = inputFile
      , outputFile        = Just outputFile
      , networkLocations  = networks
      , datasetLocations  = datasets
      , parameterValues   = parameters
      , moduleName        = Just moduleName
      , proofCache        = Just "proofcache.vclp"
      }
    }