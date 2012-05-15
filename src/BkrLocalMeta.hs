
{-# LANGUAGE ScopedTypeVariables #-}

module BkrLocalMeta ( getLocalMeta
                    , insertBkrMeta
                    , deleteBkrMeta
                    ) where

import Database.HDBC
import Database.HDBC.Sqlite3 as SL
import Prelude hiding (catch)
import Control.Exception (catch)
--import System.Time (ClockTime(..))
import BkrLogging
--import Hasher (getHashForString)
import BkrFundare
import System.Random (getStdRandom, randomR)
import Control.Monad (filterM)
import BkrConfig (FileUpdateCheckType(..))

-- db convenience functions --

{-| Convenience function for getting a db connection. |-}
getConn :: FilePath -> IO SL.Connection
getConn path = do
     logDebug $ "getSqliteConnection: getting conn for path: " ++ path
     
     -- Try usong connectSqlite3 and connectSqlite3Raw if that fails (file system unicode support workaround for OS X)
     --SL.connectSqlite3 path `catch` \ (err :: SqlError) -> SL.connectSqlite3Raw path
     SL.connectSqlite3 path `catch` \ (_ :: SqlError) -> SL.connectSqlite3Raw path

{-| Convenience function for disconnection a db connection. |-}
doDisconnect :: IConnection conn => conn -> IO ()
doDisconnect conn = do 
     logDebug "doDisconnect called"
     disconnect conn

{-| Convenience function for commiting a ongoing transaction. |-}
doCommit :: IConnection conn => conn -> IO ()
doCommit conn = do 
     logDebug "doCommit called"
     commit conn

{-| Convenience function for rolling back a transaction. |-}
doRollback :: IConnection conn => conn -> IO ()
doRollback conn = do
     logDebug "doRollback called"
     rollback conn

{-| Convenience function for db insert. Takes file path to the db file and commits the transaction automatically.

Use as:
@
set "/path/to/db/file.db" "INSERT INTO table VALUES (?, ?)" [[toSql (1 :: Int), toSql ("text" :: String)],[toSql (2 :: Int), SqlNull]]
@
|-}
set :: FilePath -> String -> [[SqlValue]] -> IO ()
set dbFilePath query values = do 
     logDebug $ "set: called with query: " ++ query -- ++ "\nvalues: " ++ (show values)
     conn <- getConn dbFilePath
     catch (do 
               stmt <- prepare conn query
               executeMany stmt values
               doCommit conn)
               --doDisconnect conn)
           (\e -> do 
                     let err = show (e :: SqlError)
                     logCritical $ "set: got SqlError: " ++ err ++ ", will rollback the transaction"
                     doRollback conn
                     doDisconnect conn)

{-
{-| Convenience function for db insert, same as set but takes an established db connection instead. You need to create the connection and commit the query manually.

Use as:
@
conn <- getSqliteConnection "pathToDBFile.db"
set' conn "INSERT INTO table VALUES (?, ?)" [[toSql (1 :: Int), toSql ("text" :: String)],[toSql (2 :: Int), SqlNull]]
doCommit conn
doDisconnect conn
@
|-}
set' :: IConnection conn => conn -> String -> [[SqlValue]] -> IO ()
set' conn query values = do 
     logDebug $ "set': called with query: " ++ query
     catch (do 
               stmt <- prepare conn query
               executeMany stmt values)
           (\e -> do 
                     let err = show (e :: SqlError)
                     logCritical $ "set': got SqlError: " ++ err ++ ", will rollback the transaction"
                     doRollback conn)
-}

{-
setSimple :: IConnection conn => conn -> String -> [SqlValue] -> IO Integer
setSimple conn query values = do
     logDebug $ "setSimple: called with query: " ++ query
     run conn query values `catch` (\e -> do 
                                             let err = show (e :: SqlError)
                                             logCritical $ "setSimple: got SqlError: " ++ err ++ ", will rollback the transaction"
                                             doRollback conn
                                             return 0)
-}
-- End db convenience functions --

{-| Created a .bkrmeta db file and inserts the bkrmeta table. |-}
setTable :: FilePath -> IO ()
setTable dbFilePath = do
     logDebug $ "setTable: called for path: " ++ dbFilePath
     
     let query = "CREATE TABLE IF NOT EXISTS bkrmeta (pathchecksum TEXT PRIMARY KEY, fullpath TEXT NOT NULL, filechecksum TEXT NOT NULL, filemodtimechecksum TEXT NOT NULL, filemodtime TEXT, nogets INTEGER)"
     set dbFilePath query [[]]


{-
getValuesList :: FilePath -> String -> ClockTime -> Int -> [SqlValue]
getValuesList fullPath fileChecksum fileModTime noGets = [toSql ((show $ getHashForString fullPath) :: String), toSql (fullPath :: String), toSql (fileChecksum :: String), toSql ((show $ getHashForString $ show fileModTime) :: String), toSql (fileModTime :: ClockTime), toSql (noGets :: Int)]


insertBkrMeta :: FilePath -> String -> String -> ClockTime -> IO ()
insertBkrMeta dbFilePath fullPath fileChecksum fileModTime = do
     --logDebug $ "insertBkrMeta: called for path: " ++ dbFilePath
     --conn <- getConn dbFilePath
     let query = "INSERT INTO bkrmeta (pathchecksum, fullpath, filechecksum, filemodtimechecksum, filemodtime, nogets) VALUES (?,?,?,?,?,?)"
     --set conn query [getValuesList fullPath fileChecksum fileModTime 0]
     --doCommit conn
     --doDisconnect conn
     set dbFilePath query [getValuesList fullPath fileChecksum fileModTime 0]
-}

{-| Filter function that gets a random number between 0-9 and checks if the number is larger then noGets. If larger returns IO True (object is read from the local db) and if smaller the object is deleted from the local db (insertBkrMeta will insert the object).
|-}
objUpdateFilter :: IConnection conn => conn -> [SqlValue] -> IO Bool
--objUpdateFilter conn [pathChecksum, fullPath, fileChecksum, fileModTime, fileModChecksum, noGets] = do
objUpdateFilter conn [pathChecksum_, fullPath_, _, _, _, noGets_] = do
     randomNo <- getStdRandom (randomR (0,9))
     if randomNo > noGets_'
        then return True
        else do
             print $ "objUpdateFilter: will delete obj: " ++ show fullPath_
             let query = "DELETE FROM bkrmeta WHERE pathchecksum = ?"
             _ <- quickQuery' conn query [pathChecksum_] `catch` \ (err :: SqlError) -> do
                                                               logCritical $ "objUpdateFilter: got sql error: " ++ show err
                                                               return []
             return False

     where noGets_' = fromSql noGets_ :: Int
objUpdateFilter _ _ = error "Failed to match expected pattern"

{-| Gets BkrMeta objects from a .bkrmeta db file. getLocalMeta increments nogets every time it's called and it filters objects with objUpdateFilter.
|-}
getLocalMeta :: FileUpdateCheckType -> FilePath -> IO [BkrMeta]
getLocalMeta fileUpdateCheckType dbFilePath = do
     logDebug $ "getLocalMeta: called for path: " ++ dbFilePath
     
     conn <- getConn dbFilePath
     let query = "SELECT pathchecksum, fullpath, filechecksum, filemodtime, filemodtimechecksum, nogets FROM bkrmeta"
     result <- quickQuery' conn query [] `catch` \ (err :: SqlError) -> do
                                                                         logCritical $ "getLocalMeta: got sql error: " ++ show err ++ ", will disconnect conn"
                                                                         doDisconnect conn
                                                                         return []
     -- Increment nogets
     let query_ = "UPDATE bkrmeta SET nogets = nogets + 1"
     _ <- quickQuery' conn query_ [] `catch` \ (err :: SqlError) -> do
                                                               logCritical $ "getLocalMeta: got sql error when incrementing nogets: " ++ show err ++ ", will disconnect conn"
                                                               doDisconnect conn
                                                               return []
     -- Use smart update or check by date only
     if fileUpdateCheckType == FUCSmart
        then do
           --filteredObjects <- filterM (\x -> objUpdateFilter conn x) result
           filteredObjects <- filterM (objUpdateFilter conn) result
           doCommit conn
           doDisconnect conn
           return $ map convRow filteredObjects
        else do
           doCommit conn
           doDisconnect conn
           return $ map convRow result

     where convRow :: [SqlValue] -> BkrMeta
           --convRow [pathChecksum, fullPath, fileChecksum, fileModTime, fileModChecksum, noGets] = 
           convRow [pathChecksum_, fullPath_, fileChecksum_, fileModTime_, fileModChecksum_, _] = 
                   BkrMeta path fileHash pathHash fileMod fileModHash
                   where path        = fromSql fullPath_ :: String
                         fileHash    = fromSql fileChecksum_ :: String
                         pathHash    = fromSql pathChecksum_ :: String
                         fileMod     = fromSql fileModTime_ :: String
                         fileModHash = fromSql fileModChecksum_ :: String
           convRow _ = error "Failed to match expected pattern"

{-| Checks if bkrmeta table exists and inserts it if it doesn't. |-}
setTableIfNeeded :: FilePath -> IO ()
setTableIfNeeded dbFilePath = do
     logDebug $ "setTableIfNeeded: called for path: " ++ dbFilePath
     conn <- getConn dbFilePath
     catch (do
             --result <- quickQuery' conn "SELECT * FROM bkrmeta LIMIT 1" []
             _ <- quickQuery' conn "SELECT * FROM bkrmeta LIMIT 1" []
             doDisconnect conn
             logDebug "setTableIfNeeded: table exists"
             return ())
           (\e -> do 
                   let err = show (e :: SqlError)
                   logDebug $ "setTableIfNeeded: got sql error: " ++ err ++ ", will set table"
                   doDisconnect conn
                   setTable dbFilePath)

{-| Inserts BkrMeta objects into a .bkrmeta db file. |-}
insertBkrMeta :: FilePath -> [BkrMeta] -> IO ()
insertBkrMeta dbFilePath bkrMetaList = do
     logDebug $ "insertBkrMeta: called for path: " ++ dbFilePath
     
     let valuesList = map getValList bkrMetaList
     let query = "INSERT INTO bkrmeta (pathchecksum, fullpath, filechecksum, filemodtimechecksum, filemodtime, nogets) VALUES (?,?,?,?,?,?)"

     setTableIfNeeded dbFilePath
     set dbFilePath query valuesList

     where getValList :: BkrMeta -> [SqlValue]
           getValList bkrMeta = [toSql (pathChecksum bkrMeta :: String),
                                 toSql (fullPath bkrMeta :: String),
                                 toSql (fileChecksum bkrMeta :: String),
                                 toSql (modificationTimeChecksum bkrMeta :: String),
                                 toSql (modificationTime bkrMeta :: String), 
                                 toSql (0 :: Int)]

{-| Delete BkrMeta objects from a .bkrmeta file. |-}
deleteBkrMeta :: FilePath -> [BkrMeta] -> IO ()
deleteBkrMeta dbFilePath bkrMetaList = do
     logDebug $ "deleteBkrMeta: called for path: " ++ show dbFilePath
     
     let valuesList = map getValList bkrMetaList
     let query = "DELETE FROM bkrmeta WHERE pathchecksum = ?"
     
     setTableIfNeeded dbFilePath
     
     set dbFilePath query valuesList

     where  getValList :: BkrMeta -> [SqlValue]
            getValList bkrMeta = [toSql (pathChecksum bkrMeta :: String)]