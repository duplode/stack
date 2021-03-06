{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE RankNTypes #-}
-- |

module Stack.Types.Package where

import           Control.DeepSeq
import           Control.Exception hiding (try,catch)
import           Control.Monad.Catch
import           Control.Monad.IO.Class
import           Control.Monad.Logger (MonadLogger)
import           Control.Monad.Reader
import           Data.Binary
import           Data.Binary.VersionTagged
import qualified Data.ByteString as S
import           Data.Data
import           Data.Function
import           Data.List
import           Data.Map.Strict (Map)
import           Data.Maybe
import           Data.Monoid
import           Data.Set (Set)
import           Data.Text (Text)
import           Distribution.InstalledPackageInfo (PError)
import           Distribution.ModuleName (ModuleName)
import           Distribution.Package hiding (Package,PackageName,packageName,packageVersion,PackageIdentifier)
import           Distribution.System (Platform (..))
import           GHC.Generics
import           Path as FL
import           Prelude
import           Stack.Types.Config
import           Stack.Types.FlagName
import           Stack.Types.PackageName
import           Stack.Types.Version

-- | All exceptions thrown by the library.
data PackageException
  = PackageInvalidCabalFile (Maybe (Path Abs File)) PError
  | PackageNoCabalFileFound (Path Abs Dir)
  | PackageMultipleCabalFilesFound (Path Abs Dir) [Path Abs File]
  | MismatchedCabalName (Path Abs File) PackageName
  deriving Typeable
instance Exception PackageException
instance Show PackageException where
    show (PackageInvalidCabalFile mfile err) =
        "Unable to parse cabal file" ++
        (case mfile of
            Nothing -> ""
            Just file -> ' ' : toFilePath file) ++
        ": " ++
        show err
    show (PackageNoCabalFileFound dir) =
        "No .cabal file found in directory " ++
        toFilePath dir
    show (PackageMultipleCabalFilesFound dir files) =
        "Multiple .cabal files found in directory " ++
        toFilePath dir ++
        ": " ++
        intercalate ", " (map (toFilePath . filename) files)
    show (MismatchedCabalName fp name) = concat
        [ "cabal file "
        , toFilePath fp
        , " has a mismatched package name: "
        , packageNameString name
        ]

-- | Some package info.
data Package =
  Package {packageName :: !PackageName                    -- ^ Name of the package.
          ,packageVersion :: !Version                     -- ^ Version of the package
          ,packageFiles :: !GetPackageFiles               -- ^ Get all files of the package.
          ,packageModules :: !GetPackageModules           -- ^ Get the modules of the package.
          ,packageDeps :: !(Map PackageName VersionRange) -- ^ Packages that the package depends on.
          ,packageTools :: ![Dependency]                  -- ^ A build tool name.
          ,packageAllDeps :: !(Set PackageName)           -- ^ Original dependencies (not sieved).
          ,packageFlags :: !(Map FlagName Bool)           -- ^ Flags used on package.
          ,packageHasLibrary :: !Bool                     -- ^ does the package have a buildable library stanza?
          ,packageTests :: !(Set Text)                    -- ^ names of test suites
          ,packageBenchmarks :: !(Set Text)               -- ^ names of benchmarks
          ,packageExes :: !(Set Text)                     -- ^ names of executables
          ,packageOpts :: !GetPackageOpts                 -- ^ Args to pass to GHC.
          ,packageHasExposedModules :: !Bool              -- ^ Does the package have exposed modules?
          ,packageSimpleType :: !Bool                     -- ^ Does the package of build-type: Simple
          ,packageDefinedFlags :: !(Set FlagName)         -- ^ All flags defined in the .cabal file
          }
 deriving (Show,Typeable)

-- | Files that the package depends on, relative to package directory.
-- Argument is the location of the .cabal file
newtype GetPackageOpts = GetPackageOpts
    { getPackageOpts :: forall env m. (MonadIO m,HasEnvConfig env, HasPlatform env, MonadThrow m, MonadReader env m)
                     => SourceMap
                     -> [PackageName]
                     -> Path Abs File
                     -> m [String]
    }
instance Show GetPackageOpts where
    show _ = "<GetPackageOpts>"

-- | Files that the package depends on, relative to package directory.
-- Argument is the location of the .cabal file
newtype GetPackageFiles = GetPackageFiles
    { getPackageFiles :: forall m env. (MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m, MonadReader env m, HasPlatform env, HasEnvConfig env)
                      => Path Abs File
                      -> m (Set (Path Abs File))
    }
instance Show GetPackageFiles where
    show _ = "<GetPackageFiles>"

-- | Modules in the package.
newtype GetPackageModules = GetPackageModules
    { getPackageModules :: forall m env. (MonadIO m, MonadLogger m, MonadThrow m, MonadCatch m, MonadReader env m, HasPlatform env, HasEnvConfig env)
                             => Path Abs File
                             -> m (Set ModuleName)
    }
instance Show GetPackageModules where
    show _ = "<GetPackageModules>"

-- | Package build configuration
data PackageConfig =
  PackageConfig {packageConfigEnableTests :: !Bool        -- ^ Are tests enabled?
                ,packageConfigEnableBenchmarks :: !Bool   -- ^ Are benchmarks enabled?
                ,packageConfigFlags :: !(Map FlagName Bool)   -- ^ Package config flags.
                ,packageConfigGhcVersion :: !Version      -- ^ GHC version
                ,packageConfigPlatform :: !Platform       -- ^ host platform
                }
 deriving (Show,Typeable)

-- | Compares the package name.
instance Ord Package where
  compare = on compare packageName

-- | Compares the package name.
instance Eq Package where
  (==) = on (==) packageName

type SourceMap = Map PackageName PackageSource

-- | Where the package's source is located: local directory or package index
data PackageSource
    = PSLocal LocalPackage
    | PSUpstream Version InstallLocation (Map FlagName Bool)
    -- ^ Upstream packages could be installed in either local or snapshot
    -- databases; this is what 'InstallLocation' specifies.
    deriving Show

instance PackageInstallInfo PackageSource where
    piiVersion (PSLocal lp) = packageVersion $ lpPackage lp
    piiVersion (PSUpstream v _ _) = v

    piiLocation (PSLocal _) = Local
    piiLocation (PSUpstream _ loc _) = loc

-- | Datatype which tells how which version of a package to install and where
-- to install it into
class PackageInstallInfo a where
    piiVersion :: a -> Version
    piiLocation :: a -> InstallLocation

-- | Information on a locally available package of source code
data LocalPackage = LocalPackage
    { lpPackage        :: !Package         -- ^ The @Package@ info itself, after resolution with package flags, not including any final actions
    , lpPackageFinal   :: !Package         -- ^ Same as lpPackage, but with any test suites or benchmarks enabled as necessary
    , lpWanted         :: !Bool            -- ^ Is this package a \"wanted\" target based on command line input
    , lpDir            :: !(Path Abs Dir)  -- ^ Directory of the package.
    , lpCabalFile      :: !(Path Abs File) -- ^ The .cabal file
    , lpDirtyFiles     :: !Bool            -- ^ are there files that have changed since the last build?
    , lpNewBuildCache  :: !(Map FilePath FileCacheInfo) -- ^ current state of the files
    , lpFiles          :: !(Set (Path Abs File)) -- ^ all files used by this package
    , lpComponents     :: !(Set Text)      -- ^ components to build, passed directly to Setup.hs build
    }
    deriving Show

-- | A location to install a package into, either snapshot or local
data InstallLocation = Snap | Local
    deriving (Show, Eq)
instance Monoid InstallLocation where
    mempty = Snap
    mappend Local _ = Local
    mappend _ Local = Local
    mappend Snap Snap = Snap

data FileCacheInfo = FileCacheInfo
    { fciModTime :: !ModTime
    , fciSize :: !Word64
    , fciHash :: !S.ByteString
    }
    deriving (Generic, Show)
instance Binary FileCacheInfo
instance NFData FileCacheInfo where
    rnf = genericRnf

-- | Used for storage and comparison.
newtype ModTime = ModTime (Integer,Rational)
  deriving (Ord,Show,Generic,Eq,NFData,Binary)
