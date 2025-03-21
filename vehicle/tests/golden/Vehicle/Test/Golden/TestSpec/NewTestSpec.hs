{-# LANGUAGE NamedFieldPuns #-}

module Vehicle.Test.Golden.TestSpec.NewTestSpec where

import Control.Applicative (optional, (<**>))
import Control.Exception (assert)
import Control.Monad (forM_, join, unless)
import Data.List.NonEmpty (NonEmpty ((:|)))
import Data.Map qualified as Map
import Data.Maybe (fromMaybe, isNothing, maybeToList)
import Data.Tagged (Tagged (unTagged))
import Data.Text.IO qualified as Text
import Options.Applicative
  ( Parser,
    ParserInfo,
    ParserPrefs (..),
    command,
    defaultPrefs,
    execParserPure,
    flag,
    fullDesc,
    handleParseResult,
    header,
    help,
    helper,
    hsubparser,
    info,
    long,
    maybeReader,
    metavar,
    option,
    strOption,
  )
import Options.Applicative.Types
  ( Backtracking (..),
  )
import System.Directory (canonicalizePath, copyFile, doesFileExist)
import System.FilePath
  ( equalFilePath,
    isRelative,
    normalise,
    takeDirectory,
    (</>),
  )
import Test.Tasty (Timeout)
import Test.Tasty.Options (IsOption (optionHelp, parseValue))
import Text.Printf (printf)
import Vehicle qualified (ModeOptions, Options (..))
import Vehicle qualified as ModeOptions (ModeOptions (..))
import Vehicle.Backend.Prelude (Task (TypeCheck), TypingSystem (..), pattern CompileToMarabouQueries)
import Vehicle.Backend.Prelude qualified as Backend
import Vehicle.Check qualified as CheckOptions (proofCache)
import Vehicle.Check qualified as Vehicle (CheckOptions)
import Vehicle.CommandLine (commandLineOptionsParserInfo)
import Vehicle.Compile qualified as CompileOptions
  ( datasetLocations,
    networkLocations,
    outputFile,
    specification,
    task,
  )
import Vehicle.Compile qualified as Vehicle (CompileOptions)
import Vehicle.Export qualified as ExportOptions
  ( outputFile,
    proofCacheLocation,
    target,
  )
import Vehicle.Export qualified as Vehicle (ExportOptions)
import Vehicle.Prelude (Pretty (pretty), layoutAsString)
import Vehicle.Test.Golden.Extra (createDirectoryRecursive)
import Vehicle.Test.Golden.TestSpec
  ( FilePattern,
    TestSpec (..),
    TestSpecs (TestSpecs),
    addOrReplaceTestSpec,
    encodeTestSpecsPretty,
    filePatternString,
    parseFilePattern,
    readTestSpecsFile,
    writeTestSpecsFile,
  )
import Vehicle.Verify qualified as Vehicle (VerifyOptions)
import Vehicle.Verify qualified as VerifyOptions
  ( datasetLocations,
    networkLocations,
    proofCache,
    specification,
    verifierID,
  )

data NewTestSpecOptions = NewTestSpecOptions
  { newTestSpecDryRun :: Bool,
    newTestSpecTestPath :: Maybe FilePath,
    newTestSpecTestTimeout :: Maybe Timeout,
    newTestSpecVehicleOptions :: Vehicle.Options
  }

newTestSpecParserInfo :: ParserInfo NewTestSpecOptions
newTestSpecParserInfo =
  info
    (newTestSpecOptionsParser <**> helper)
    ( fullDesc
        <> header "add-vehicle-test - a utility for adding tests for Vehicle"
    )

newTestSpecOptionsParser :: Parser NewTestSpecOptions
newTestSpecOptionsParser =
  NewTestSpecOptions
    <$> dryRunParser
    <*> testPathParser
    <*> testTimeoutParser
    <*> hsubparser (command "vehicle" commandLineOptionsParserInfo)
  where
    dryRunParser :: Parser Bool
    dryRunParser = flag False True $ long "dry-run"

    testPathParser :: Parser (Maybe FilePath)
    testPathParser =
      optional . strOption $
        long "test-path"
          <> metavar "FILE"
          <> help "If specified, create the path & copy all needed files."

    testTimeoutParser :: Parser (Maybe Timeout)
    testTimeoutParser =
      optional . option (maybeReader parseValue) $
        long "test-timeout"
          <> metavar "TIME"
          <> help (unTagged $ optionHelp @Timeout)

newTestSpec :: [String] -> IO ()
newTestSpec args = do
  -- Parse the command line options:
  NewTestSpecOptions {..} <-
    handleParseResult $
      execParserPure defaultPrefs {prefBacktrack = NoBacktrack} newTestSpecParserInfo args

  -- Get the vehicle arguments:
  let testSpecRun = unwords $ dropWhile (/= "vehicle") args

  -- Get the target, needs, and produces:
  let TestSpecData
        { testSpecDataTarget,
          testSpecDataNeeds,
          testSpecDataProduces
        } = testSpecData newTestSpecVehicleOptions
  testSpecProduces <- either fail return testSpecDataProduces

  -- Validate the 'needs' and 'produces':
  forM_ testSpecDataNeeds $ \testSpecNeed ->
    unless (isRelative testSpecNeed) $
      fail $
        printf "Test needs files at an absolute path: %s\n" testSpecNeed
  forM_ testSpecProduces $ \testSpecProducePattern ->
    let testSpecProduce = filePatternString testSpecProducePattern
     in unless (isRelative testSpecProduce) $
          fail $
            printf "Test produces files at an absolute path: %s\n" testSpecProduce

  -- Construct the test specification:
  let theNewTestSpec =
        TestSpec
          { testSpecName = testSpecDataTarget,
            testSpecRun = testSpecRun,
            testSpecEnabled = Nothing,
            testSpecNeeds = testSpecDataNeeds,
            testSpecProduces = testSpecProduces,
            testSpecTimeout = newTestSpecTestTimeout,
            testSpecDiffSpec = Nothing
          }

  -- Write the test:
  let testDirectory = fromMaybe "." newTestSpecTestPath
  let testSpecsFile = testDirectory </> "test.json"

  -- Copy over the needed files:
  let targetExistsError targetPath =
        fail $ printf "Refusing to overwrite %s\n" targetPath
  forM_ testSpecDataNeeds $ \testSpecNeed -> do
    let testSpecNeedSource = normalise testSpecNeed
    let testSpecNeedTarget = normalise $ testDirectory </> testSpecNeed
    canonicalSource <- canonicalizePath testSpecNeedSource
    canonicalTarget <- canonicalizePath testSpecNeedTarget
    unless (equalFilePath canonicalSource canonicalTarget) $ do
      printf "Copy %s to %s\n" canonicalSource canonicalTarget
      canonicalTargetExists <- doesFileExist canonicalTarget
      if canonicalTargetExists
        then targetExistsError canonicalTarget
        else do
          unless newTestSpecDryRun $ do
            createDirectoryRecursive (takeDirectory canonicalTarget)
            copyFile canonicalSource canonicalTarget

  -- Write or update the test specification:
  testSpecsFileExists <- doesFileExist testSpecsFile
  testSpecs <-
    if not testSpecsFileExists
      then return $ TestSpecs (theNewTestSpec :| [])
      else addOrReplaceTestSpec theNewTestSpec <$> readTestSpecsFile testSpecsFile

  printf "Writing %s:\n" testSpecsFile
  Text.putStrLn $ encodeTestSpecsPretty testSpecs
  writeTestSpecsFile testSpecsFile testSpecs

-- Inferred 'needs' and 'produces':

data TestSpecData = TestSpecData
  { testSpecDataTarget :: String,
    testSpecDataNeeds :: [FilePath],
    testSpecDataProduces :: Either String [FilePattern]
  }
  deriving (Show)

class TestSpecLike a where
  targetName :: a -> String
  targetName = testSpecDataTarget . testSpecData

  needs :: a -> [FilePath]
  needs = testSpecDataNeeds . testSpecData

  produces :: a -> Either String [FilePattern]
  produces = testSpecDataProduces . testSpecData

  testSpecData :: a -> TestSpecData
  testSpecData a = TestSpecData (targetName a) (needs a) (produces a)

instance TestSpecLike NewTestSpecOptions where
  testSpecData :: NewTestSpecOptions -> TestSpecData
  testSpecData = testSpecData . newTestSpecVehicleOptions

instance TestSpecLike Vehicle.Options where
  testSpecData :: Vehicle.Options -> TestSpecData
  testSpecData = maybe emptyTestSpecData testSpecData . Vehicle.modeOptions
    where
      emptyTestSpecData = TestSpecData "NoMode" [] (return [])

instance TestSpecLike Vehicle.ModeOptions where
  testSpecData :: Vehicle.ModeOptions -> TestSpecData
  testSpecData = \case
    ModeOptions.Compile opts -> testSpecData opts
    ModeOptions.Verify opts -> testSpecData opts
    ModeOptions.Export opts -> testSpecData opts
    ModeOptions.Check opts -> testSpecData opts

instance TestSpecLike Vehicle.CompileOptions where
  targetName :: Vehicle.CompileOptions -> String
  targetName = layoutAsString . pretty . CompileOptions.task

  needs :: Vehicle.CompileOptions -> [FilePath]
  needs opts =
    join
      [ [CompileOptions.specification opts],
        Map.elems (CompileOptions.networkLocations opts),
        Map.elems (CompileOptions.datasetLocations opts)
      ]

  produces :: Vehicle.CompileOptions -> Either String [FilePattern]
  produces opts = traverse parseFilePattern filePatternStrings
    where
      outputFile = CompileOptions.outputFile opts
      filePatternStrings =
        case CompileOptions.task opts of
          TypeCheck Standard -> assert (isNothing outputFile) []
          CompileToMarabouQueries -> [outputDir </> "*.txt" | outputDir <- maybeToList outputFile]
          _ -> maybeToList outputFile

instance TestSpecLike Vehicle.ExportOptions where
  targetName :: Vehicle.ExportOptions -> String
  targetName = layoutAsString . pretty . Backend.CompileToITP . ExportOptions.target

  needs :: Vehicle.ExportOptions -> [FilePath]
  needs = (: []) . ExportOptions.proofCacheLocation

  produces :: Vehicle.ExportOptions -> Either String [FilePattern]
  produces = traverse parseFilePattern . maybeToList . ExportOptions.outputFile

instance TestSpecLike Vehicle.VerifyOptions where
  targetName :: Vehicle.VerifyOptions -> String
  targetName = layoutAsString . pretty . VerifyOptions.verifierID

  needs :: Vehicle.VerifyOptions -> [FilePath]
  needs opts =
    join
      [ [VerifyOptions.specification opts],
        Map.elems (VerifyOptions.networkLocations opts),
        Map.elems (VerifyOptions.datasetLocations opts)
      ]

  produces :: Vehicle.VerifyOptions -> Either String [FilePattern]
  produces = traverse parseFilePattern . maybeToList . VerifyOptions.proofCache

instance TestSpecLike Vehicle.CheckOptions where
  targetName :: Vehicle.CheckOptions -> String
  targetName = const "Check"

  needs :: Vehicle.CheckOptions -> [FilePath]
  needs = (: []) . CheckOptions.proofCache

  produces :: Vehicle.CheckOptions -> Either String [FilePattern]
  produces = const (return [])
