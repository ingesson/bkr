{-# LANGUAGE OverloadedStrings, ScopedTypeVariables #-}

module System.Bkr.TargetServices.S3.BkrS3Bucket ( getBkrObjects
                                         , putBackupFile
                                         , putBkrMetaFile
                                         ) where

import System.Bkr.BkrConfig
import System.Bkr.BkrFundare
import System.Bkr.Hasher
import System.Bkr.BkrLogging
import System.Bkr.TargetServices.S3.BkrAwsConfig

import System.IO
import Network.HTTP.Conduit
import Data.IORef (newIORef, readIORef)
import Data.Monoid (mempty)
import System.FilePath.Posix (takeFileName)
import Prelude hiding (catch)
import Control.Concurrent (threadDelay)

import qualified Aws
import qualified Aws.S3 as S3
import qualified Data.Text as T
import qualified Data.ByteString as B
import qualified Control.Exception as C

--import System.IO.Error (ioError, userError)
--import Data.Conduit (($$))
--import Data.Conduit.Binary (sinkIOHandle)
--import Maybe (fromJust)
--import Control.Monad (forM)
--import System.Directory (getTemporaryDirectory, removeFile)
--import Data.ByteString (pack)
--import qualified Data.Knob as K
--import qualified Data.ByteString.Lazy.UTF8 as B
--import qualified Data.ByteString.UTF8 as BUTF8
--import qualified Data.ByteString.Lazy as LB

getBkrObjectKeys :: T.Text -> [T.Text] -> IO [T.Text]
getBkrObjectKeys gbMarker objList = do

     -- Get AWS credentials
     cfg <- getS3Config
     
     -- Create an IORef to store the response Metadata (so it is also available in case of an error).
     metadataRef <- newIORef mempty
     
     -- Get bucket info with simpleAwsRef. S3.getBucket returns a GetBucketResponse object.
     bucketName <- getS3BucketName
     -- add catch S3Error and print check aws settings. 
     s3BkrBucket <- Aws.simpleAwsRef cfg metadataRef S3.GetBucket { S3.gbBucket    = bucketName
                                                                  , S3.gbDelimiter = Nothing
                                                                  , S3.gbMarker    = Just gbMarker
                                                                  , S3.gbMaxKeys   = Nothing
                                                                  , S3.gbPrefix    = Just $ T.pack "bkrm"
                                                                  } `C.catch` \ (ex :: C.SomeException) -> do
                                                                  logCritical "Failed to get objects from S3 bucket, please check that your S3 credentials in the bkr configuration file are set correctly. The error was:"
                                                                  C.throwIO ex
     
     -- Print the response metadata.
     --print =<< readIORef metadataRef
     -- Log the response metadata.
     ioResponseMetaData <- readIORef metadataRef
     logDebug $ "getBkrObjectKeys: response metadata: " ++ show ioResponseMetaData

     -- Get bucket contents with gbrContents. gbrContents gets [ObjectInfo]
     let bkrBucketContents = S3.gbrContents s3BkrBucket
     
     -- Get object keys (the bkr object filenames)
     let objects = map S3.objectKey bkrBucketContents

     -- S3 is limited to fetch 1000 objects so make sure that we get all objects
     if length objects > 999
        then getBkrObjectKeys (last objects) (objList ++ objects)
        else return $ objList ++ objects

getBkrObjects :: IO [BkrMeta]
getBkrObjects = do
          
     objectKeys <- getBkrObjectKeys (T.pack "") []
     logNotice $ "Got " ++ show (length objectKeys) ++ " objects from S3"

     return $ map getMetaKeys objectKeys

getMetaKeys :: T.Text -> BkrMeta
getMetaKeys key = BkrMeta { fullPath                 = "" 
                          , pathChecksum             = T.unpack $ kSplit !! 1
                          , fileChecksum             = T.unpack $ kSplit !! 2
                          , modificationTime         = ""
                          , modificationTimeChecksum = ""
                          }
                          where kSplit = T.split (=='.') key

putBackupFile :: FilePath -> IO ()
putBackupFile filePath = do
        
     let uploadName = T.pack $ show (getHashForString filePath) ++ "::" ++ takeFileName filePath
     -- Get MD5 hash for file
     --contentMD5 <- getFileHash path
     --putFile path uploadName (Just $ BUTF8.fromString $ show contentMD5)
     putFile filePath uploadName Nothing 0

putBkrMetaFile :: FilePath -> IO ()
putBkrMetaFile filePath = do

     let uploadName = T.pack $ "bkrm." ++ takeFileName filePath
     -- Get MD5 hash for file
     --contentMD5 <- getFileHash path
     --putFile path uploadName (Just $ BUTF8.fromString $ show contentMD5)
     putFile filePath uploadName Nothing 0

{-| Upload file to S3. putFile will handle a failed attempt to upload the file by waiting 60 seconds and then retrying. If this fails five times it will raise an IO Error. -}
putFile :: FilePath -> T.Text -> Maybe B.ByteString -> Int -> IO ()
putFile filePath uploadName contentMD5 noOfRetries =
     putFile' filePath uploadName contentMD5 `C.catch` \ (ex :: C.SomeException) ->
              if noOfRetries > 5
                 then ioError $ userError $ "Failed to upload file " ++ filePath
                 else do
                      logCritical $ "putFile: got exception: " ++ show ex
                      logCritical "Wait 60 sec then try again"
                      threadDelay $ 60 * 1000000
                      putFile filePath uploadName contentMD5 (noOfRetries + 1)

putFile' :: FilePath -> T.Text -> Maybe B.ByteString -> IO ()
putFile' filePath uploadName contentMD5 = do
     
     -- Get S3 config
     cfg <- getS3Config

     -- Create an IORef to store the response Metadata (so it is also available in case of an error).
     metadataRef <- newIORef mempty
     
     -- TODO: change to read the file lazy and upload using RequestBodyLBS ...or maybe no, we probably don't gain anything from doing this lazy
     --hndl <- openBinaryFile path ReadMode
     --fileContents <- LB.hGetContents hndl
     --Aws.simpleAwsRef cfg metadataRef $ S3.putObject uploadName getS3BucketName (RequestBodyLBS $ fileContents)
     fileContents <- B.readFile filePath

     -- Get bucket name
     bucketName <- getS3BucketName
     
     -- Check if we should use reduced redundancy
     useReducedRedundancy <- getUseS3ReducedRedundancy
     
     -- Replace space with underscore in the upload name (S3 does not handle blanks in object names). Doing this is safe since the whole original path is stored in the meta file.
     logDebug ("putFile: will upload file " ++ filePath)
     _ <- Aws.simpleAwsRef cfg metadataRef S3.PutObject { S3.poObjectName          = T.replace " " "_" uploadName 
                                                   , S3.poBucket              = bucketName
                                                   , S3.poContentType         = Nothing
                                                   , S3.poCacheControl        = Nothing
                                                   , S3.poContentDisposition  = Nothing
                                                   , S3.poContentEncoding     = Nothing
                                                   , S3.poContentMD5          = contentMD5
                                                   , S3.poExpires             = Nothing
                                                   , S3.poAcl                 = Nothing
                                                   , S3.poStorageClass        = useReducedRedundancy
                                                   , S3.poRequestBody         = RequestBodyBS fileContents 
                                                   , S3.poMetadata            = []
                                                   }
     logDebug "putFile: upload done"

     -- If lazy upload, close the handle
     --logDebug "putFile: close file handle"
     --hClose hndl
     
     -- Log the response metadata.
     --ioResponseMetaData <- readIORef metadataRef
     --logDebug $ "putFile: response metadata: " ++ (show ioResponseMetaData)
     readIORef metadataRef >>= logDebug . ("putFile: response metadata: " ++) . show

{-
getBkrObjectsOld :: IO [BkrMeta]
getBkrObjectsOld = do

     -- Get AWS credentials
     cfg <- getS3Config
     
     -- Create an IORef to store the response Metadata (so it is also available in case of an error).
     metadataRef <- newIORef mempty
     
     -- Get bucket info with simpleAwsRef. S3.getBucket returns a GetBucketResponse object.
     bucketName <- getS3BucketName
     s3BkrBucket <- Aws.simpleAwsRef cfg metadataRef $ S3.getBucket bucketName
     --print $ show bucket
     --print $ show $ S3.gbrContents bucket
     
     -- Print the response metadata.
     --print =<< readIORef metadataRef

     -- Get bucket contents with gbrContents. gbrContents gets [ObjectInfo]
     let bkrBucketContents = S3.gbrContents s3BkrBucket
     --print $ show $ length bkrBucketContents
     --print $ show contents
     --print $ show $ S3.objectKey $ contents !! 0
     
     -- Get object keys (the bkr object filenames)
     let objectKeys = map S3.objectKey bkrBucketContents
     --let t0 = Prelude.head t
     --print t0
     --let t1 = Prelude.last $ T.split (=='.') t0
     --print t1
     
     -- Filter the object keys for Bkr meta (.bkrm) objects (files)
     --let bkrObjectFiles = filter (\x -> hasBkrExtension x) objectKeys
     --print "bkrObjectFiles: "
     --print bkrObjectFiles
     --print $ show $ length bkrObjectFiles
     
     bkrObjects <- getBkrObject objectKeys
     return bkrObjects
-}
{-
hasBkrExtension :: T.Text -> Bool
hasBkrExtension t = do
     if (Prelude.last $ T.split (=='.') t) == "bkrm"
        then True
        else False
-}

{-
{-| A small function to save the object's data into a file handle. -}
saveObject :: IO Handle -> Aws.HTTPResponseConsumer ()
--saveObject hndl status headers source = source $$ sinkIOHandle hndl
saveObject hndl _ _ source = source $$ sinkIOHandle hndl
-}

{-
{-| Takes a list of bkr objects, gets them one by one from S3, parses content creating and returning a list of BkrObject's. This function uses the Knob package for in-memory temporary storage of the downloaded bkr object. -}
getBkrObject :: [T.Text] -> IO [BkrMeta]
getBkrObject objNames = do

     -- Get S3 config
     cfg <- getS3Config

     -- Create an IORef to store the response Metadata (so it is also available in case of an error).
     metadataRef <- newIORef mempty

     -- Get tmp dir
     --tmpDir <- getTemporaryDirectory

     objects <- forM objNames $ \fileName -> do   
        -- Get knob object and knob handle (knob is a in-memory virtual file) 
        knob <- K.newKnob (pack [])
        knobHndl <- K.newFileHandle knob "test.txt" WriteMode
        -- Get the object (.bkrm sfile)
        bucketName <- getS3BucketName
        Aws.simpleAwsRef cfg metadataRef $ S3.getObject bucketName fileName (saveObject $ return knobHndl)
        -- Get data (text) from the knob virtual file        
        knobDataContents <- K.getContents knob
        -- Close knob
        hClose knobHndl
        -- Get the config pair and get path and checksum from the pair
        pairS <- getConfPairsFromByteString' knobDataContents
        let path_                     = fromJust $ lookup "fullpath" pairS
        let checksum_                 = fromJust $ lookup "checksum" pairS
        let modificationTime_         = fromJust $ lookup "modificationtime" pairS
        let modificationTimeChecksum_ = fromJust $ lookup "modificationtimechecksum" pairS

        return [BkrMeta path_ checksum_ (show $ getHashForString path_) modificationTime_ modificationTimeChecksum_]
     return (concat objects)
-}
{-
{-| Like getBkrObject but uses a temporary file instead of a virtual file when fetching and reading the bkr object files. -}
getBkrObject' :: [T.Text] -> IO [BkrMeta]
getBkrObject' fileNames = do

     -- Get S3 config
     cfg <- getS3Config

     -- Create an IORef to store the response Metadata (so it is also available in case of an error).
     metadataRef <- newIORef mempty

     -- Get tmp dir
     tmpDir <- getTemporaryDirectory

     objects <- forM fileNames $ \fileName -> do
        -- Get tmp file path and handle
        (tmpPath, hndl) <- openBinaryTempFileWithDefaultPermissions tmpDir "tmp.bkrm"
        -- Get the object (.bkrm sfile)
        bucketName <- getS3BucketName
        Aws.simpleAwsRef cfg metadataRef $ S3.getObject bucketName fileName (saveObject $ return hndl)
        -- Get a new handle to the tmp file, read it and get the path and checksum
        hndl_ <- openBinaryFile tmpPath ReadMode
        -- Get the conf pair from the tmp file and get path and checksum from the pair
        pairsS <- getConfPairsFromFileS' tmpPath
        let path_                     = fromJust $ lookup "fullpath" pairsS
        let checksum_                 = fromJust $ lookup "checksum" pairsS
        let modificationTime_         = fromJust $ lookup "modificationtime" pairsS
        let modificationTimeChecksum_ = fromJust $ lookup "modificationtimechecksum" pairsS
        -- Close the handle and delete the tmp file
        hClose hndl_
        removeFile tmpPath

        return [BkrMeta path_ checksum_ (show $ getHashForString path_) modificationTime_ modificationTimeChecksum_]
     return (concat objects)
-}
{-
splitObject :: String -> [T.Text]
splitObject s = T.split (=='.') (T.pack s)
-}