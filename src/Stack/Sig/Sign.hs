{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}

{-|
Module      : Stack.Sig.Sign
Description : Signing Packages
Copyright   : (c) FPComplete.com, 2015
License     : BSD3
Maintainer  : Tim Dysinger <tim@fpcomplete.com>
Stability   : experimental
Portability : POSIX
-}

module Stack.Sig.Sign (sign, signAll) where

import           Control.Monad.Catch (MonadThrow)
import           Control.Monad.IO.Class (MonadIO, liftIO)
import           Control.Monad.Trans.Control (MonadBaseControl)
import           Control.Applicative ((<$>))
import           Data.Foldable (forM_)
import           Data.Monoid ((<>))
import           Control.Exception (throwIO)
import           Control.Monad (when)
import           Data.Version (showVersion)
import qualified Data.Text as T
import           Data.UUID (toString)
import           Data.List (isSuffixOf)
import           Data.UUID.V4 (nextRandom)
import           Distribution.Package (PackageName(PackageName),
                                       PackageIdentifier(..))
import           Network.HTTP.Conduit (Response(..), RequestBody(..),
                                       Request(..), withManager,
                                       httpLbs, parseUrl)
import           Network.HTTP.Types (status200, methodPut)
import           Stack.Sig.Cabal (cabalFetch, cabalFilePackageId,
                                  packagesFromIndex, getPackageTarballPath)
import           Stack.Sig.Doc
import qualified Stack.Sig.GPG as GPG
import           Stack.Sig.Hackage
import           Stack.Sig.Types
import           System.Directory (getTemporaryDirectory,
                                   getDirectoryContents,
                                   createDirectoryIfMissing)
import           System.FilePath ((</>))
import           System.Process (readProcessWithExitCode)

sign :: String -> FilePath -> IO ()
sign url filePath =
  do putHeader "Signing Package"
     tempDir <- getTemporaryDirectory
     uuid <- nextRandom
     let workDir = tempDir </> toString uuid
     createDirectoryIfMissing True workDir
     -- TODO USE HASKELL'S `TAR` PACKAGE FOR EXTRACTING MIGHT WORK
     -- BETTER ON SOME PLATFORMS THAN readProcessWithExitCode +
     -- TAR.EXE
     (_code,_out,_err) <-
       readProcessWithExitCode "tar"
                               ["xf",filePath,"-C",workDir,"--strip","1"]
                               []
     cabalFiles <-
       (filter (isSuffixOf ".cabal")) <$>
       (getDirectoryContents workDir)
     if length cabalFiles < 1
        then undefined
        else do pkg <-
                  cabalFilePackageId (workDir </> head cabalFiles)
                signPackage url pkg filePath
                putPkgOK pkg

signAll :: forall (m :: * -> *).
           (MonadIO m,MonadThrow m,MonadBaseControl IO m)
        => String -> String -> m ()
signAll url uname =
  do putHeader "Signing Packages"
     fromHackage <- packagesForMaintainer uname
     fromIndex <- packagesFromIndex
     forM_ (filter (\x ->
                      (pkgName x) `elem`
                      (map pkgName fromHackage))
                   fromIndex)
           (\pkg ->
              liftIO (do cabalFetch ["--no-dependencies"]
                                    pkg
                         filePath <- getPackageTarballPath pkg
                         signPackage url pkg filePath
                         putPkgOK pkg))

--------------
-- Internal --
--------------

signPackage :: String -> PackageIdentifier -> FilePath -> IO ()
signPackage url pkg filePath =
  do sig@(Signature signature) <- GPG.sign filePath
     let (PackageName name) = pkgName pkg
         version = showVersion (pkgVersion pkg)
     fingerprint <-
       GPG.verifyFile sig filePath >>=
       GPG.fullFingerprint
     req <-
       parseUrl (url <> "/upload/signature/" <> name <> "/" <> version <> "/" <>
                 T.unpack (fingerprintSample fingerprint))
     let put =
           req {method = methodPut
               ,requestBody =
                  RequestBodyBS signature}
     res <- withManager (httpLbs put)
     when (responseStatus res /= status200)
          (throwIO (GPGSignException "unable to sign & upload package"))
