{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ExtendedDefaultRules #-}
{-# OPTIONS_GHC -fno-warn-type-defaults #-}

module Main where

import Shelly.Lifted
import System.Exit
import qualified Data.Text as T
import qualified Data.Text.IO as T
import Data.Text (Text)
import Data.Time.Clock
import Data.String (fromString)
import Options.Applicative as O
import Control.Monad (unless)
import Control.Monad.Trans.Reader
import Control.Monad.Trans.Maybe
import Control.Error
import System.IO (openFile, IOMode(..))
import System.Directory
import qualified Filesystem.Path.CurrentOS as Path
import Prelude hiding (FilePath)

-- * Things given to us by Harbormaster
newtype Repository = Repo Text
newtype Commit = Commit Text
newtype Revision = Rev Integer
newtype Diff = Diff Integer
newtype BuildId = BuildId Text

repo :: Repository
repo = Repo "rGHC"

sourceRepo :: Text
sourceRepo = "git://git.haskell.org/ghc"

data Options = Options { maxThreads :: Maybe Int
                       , referenceRepo :: Maybe FilePath
                       , buildId :: BuildId
                       , archivePath :: FilePath
                       }

data Task = BuildDiff { repository :: Repository
                      , revision :: Revision
                      , diff :: Diff
                      }
          | BuildCommit { repository :: Repository
                        , commit :: Commit
                        }

type BuildM = ReaderT Options Sh

getOptions :: BuildM Options
getOptions = ask

runBuildM :: BuildM a -> Options -> IO a
runBuildM action opts =
    shelly $ runReaderT action opts

cpuCount :: BuildM Int
cpuCount =
    fromMaybe 1 <$> runMaybeT (config <|> windows <|> linux <|> freebsd)
  where
    config, windows, linux, freebsd :: MaybeT BuildM Int
    config = MaybeT $ fmap maxThreads getOptions
    windows = MaybeT $ (>>= readT) <$> get_env "NUMBER_OF_PROCESSORS"
    linux = MaybeT $ readT <$> cmd "getconf" "_NPROCESSORS_ONLN"
    freebsd = MaybeT $ readT <$> cmd "getconf" "NPROCESSORS_ONLN"

    readT :: Read a => Text -> Maybe a
    readT = readZ . T.unpack

logStr :: String -> BuildM ()
logStr = liftIO . putStr

timeIt :: String -> BuildM a -> BuildM a
timeIt what action = do
    start <- liftIO getCurrentTime
    logStr $ "- "<>what
    r <- action
    end <- liftIO getCurrentTime
    let delta = end `diffUTCTime` start
    logStr $ "took "<>show delta<>"\n"
    return r

cloneGhc :: RepoDir -> BuildM ()
cloneGhc (RepoDir repoDir) = timeIt "cloning tree" $ do
    opts <- getOptions
    rm_rf repoDir
    case referenceRepo opts of
      Just refRepo -> do
        refExists <- liftIO $ doesDirectoryExist (Path.encodeString refRepo)
        unless refExists $ do
            cmd "git" "clone" "--bare" sourceRepo refRepo
        () <- cmd "git" "-C" refRepo "remote" "update"
        () <- cmd "git" "-C" refRepo "submodule" "update"

        () <- cmd "git" "clone" "--reference" refRepo sourceRepo repoDir
        chdir repoDir $ do
            cmd "git" "submodule" "update" "--init"
      Nothing ->
        cmd "git" "clone" sourceRepo repoDir

newtype RepoDir = RepoDir FilePath

inRepo :: RepoDir -> BuildM a -> BuildM a
inRepo (RepoDir dir) = chdir dir

applyDiff :: RepoDir -> Diff -> BuildM ()
applyDiff repoDir (Diff d) = inRepo repoDir $
    cmd "arc" "patch" "--nobranch" "--force" "--nocommit" "--diff" (T.pack $ show d)

checkout :: RepoDir -> Commit -> BuildM ()
checkout repoDir (Commit commit) = timeIt "checking out commit " $ inRepo repoDir $
    cmd "git" "checkout" commit

updateSubmodules :: RepoDir -> BuildM ()
updateSubmodules repoDir = timeIt "updating submodules" $ inRepo repoDir $
    cmd "git" "submodule" "update"

validate :: RepoDir -> FilePath -> BuildM ExitCode
validate repoDir log = timeIt "validating" $ inRepo repoDir $ do
    hdl <- liftIO $ openFile (Path.encodeString log) WriteMode
    let handles = [ OutHandle $ UseHandle hdl
                  , ErrorHandle $ UseHandle hdl
                  ]
    errExit False $ do
        runHandles "sh" ["validate"] handles (\_ _ _ -> return ())
        c <- lastExitCode
        case c of
          0 -> do liftIO $ putStrLn "Validate finished successfully"
                  return ExitSuccess
          _ -> do liftIO $ putStrLn $ "Validate failed with exit code "<>show c
                  return $ ExitFailure c

archiveFile :: FilePath -> BuildM ()
archiveFile path = do
    opts <- getOptions
    let compressedPath = path <.> "xz"
        BuildId buildDir = buildId opts
        finalPath = (archivePath opts </> buildDir </> compressedPath)
    cmd "xz" "-9" "-o" finalPath path

showTestsuiteSummary :: RepoDir -> BuildM ()
showTestsuiteSummary (RepoDir dir) = do
    c <- readfile (dir </> "testsuite_summary.txt")
    liftIO $ do
        putStrLn ""
        putStrLn "================== Testsuite summary =================="
        T.putStrLn c

options :: Parser Options
options = Options
    <$> option auto
               (short 't' <> long "threads" <> value Nothing)
    <*> option (Just . fromString <$> str)
               (short 'r' <> long "reference-repo" <> value Nothing)
    <*> option (BuildId . T.pack <$> str)
               (short 'B' <> long "build-id")
    <*> option (fromString <$> str)
               (short 'a' <> long "archive" <> metavar "DIR" <> value ".")

task :: Parser (BuildM ExitCode)
task = subparser $ buildDiff <> buildCommit
  where
    commit = option (Commit . T.pack <$> str) (short 'c' <> long "commit" <> metavar "COMMIT")

    buildDiff = O.command "diff" $ info
        (testDiff <$> option (Rev <$> auto) (short 'r' <> long "revision" <> metavar "REV")
                  <*> option (Diff <$> auto) (short 'd' <> long "diff" <> metavar "DIFF")
                  <*> commit
        )
        mempty

    buildCommit = O.command "commit" $ info
        (testCommit <$> commit)
        mempty

main :: IO ()
main = do
    (opts, action) <- execParser $ info (helper <*> ((,) <$> options <*> task)) mempty
    code <- flip runBuildM opts $ verbosely action
    exitWith code

testDiff :: Revision -> Diff -> Commit -> BuildM ExitCode
testDiff rev diff baseCommit = do
    let repoDir = RepoDir "ghc-test"
    cloneGhc repoDir
    checkout repoDir baseCommit
    updateSubmodules repoDir
    applyDiff repoDir diff
    updateSubmodules repoDir
    code <- validate repoDir "build.log"
    archiveFile "build.log"
    showTestsuiteSummary repoDir
    return code

testCommit :: Commit -> BuildM ExitCode
testCommit commit = do
    let repoDir = RepoDir "ghc-test"
    cloneGhc repoDir
    checkout repoDir commit
    updateSubmodules repoDir
    code <- validate repoDir "build.log"
    archiveFile "build.log"
    showTestsuiteSummary repoDir
    return code
