{-# LANGUAGE DeriveDataTypeable, OverloadedStrings #-}
module Network.TLS.Handshake.Common
    ( handshakeFailed
    , errorToAlert
    , unexpected
    , newSession
    , handshakeTerminate
    -- * sending packets
    , sendChangeCipherAndFinish
    -- * receiving packets
    , recvChangeCipherAndFinish
    , RecvState(..)
    , runRecvState
    , recvPacketHandshake
    ) where

import Control.Concurrent.MVar

import Network.TLS.Context
import Network.TLS.Session
import Network.TLS.Struct
import Network.TLS.IO
import Network.TLS.State hiding (getNegotiatedProtocol)
import Network.TLS.Handshake.Process
import Network.TLS.Handshake.State
import Network.TLS.Record.State
import Network.TLS.Measurement
import Network.TLS.Types
import Network.TLS.Cipher
import Network.TLS.Util
import Data.ByteString.Char8 ()

import Control.Monad.State
import Control.Exception (throwIO)

handshakeFailed :: TLSError -> IO ()
handshakeFailed err = throwIO $ HandshakeFailed err

errorToAlert :: TLSError -> Packet
errorToAlert (Error_Protocol (_, _, ad)) = Alert [(AlertLevel_Fatal, ad)]
errorToAlert _                           = Alert [(AlertLevel_Fatal, InternalError)]

unexpected :: String -> Maybe [Char] -> IO a
unexpected msg expected = throwCore $ Error_Packet_unexpected msg (maybe "" (" expected: " ++) expected)

newSession :: Context -> IO Session
newSession ctx
    | pUseSession $ ctxParams ctx = getStateRNG ctx 32 >>= return . Session . Just
    | otherwise                   = return $ Session Nothing

-- | when a new handshake is done, wrap up & clean up.
handshakeTerminate :: Context -> IO ()
handshakeTerminate ctx = do
    session <- usingState_ ctx getSession
    -- only callback the session established if we have a session
    case session of
        Session (Just sessionId) -> do
            sessionData <- getSessionData ctx
            withSessionManager (ctxParams ctx) (\s -> liftIO $ sessionEstablish s sessionId (fromJust "session-data" sessionData))
        _ -> return ()
    -- forget all handshake data now and reset bytes counters.
    liftIO $ modifyMVar_ (ctxHandshake ctx) (return . const Nothing)
    updateMeasure ctx resetBytesCounters
    -- mark the secure connection up and running.
    setEstablished ctx True
    return ()

sendChangeCipherAndFinish :: Context -> Role -> IO ()
sendChangeCipherAndFinish ctx role = do
    sendPacket ctx ChangeCipherSpec

    when (role == ClientRole) $ do
        let cparams = getClientParams $ ctxParams ctx
        suggest <- usingState_ ctx $ getServerNextProtocolSuggest
        case (onNPNServerSuggest cparams, suggest) of
            -- client offered, server picked up. send NPN handshake.
            (Just io, Just protos) -> do proto <- liftIO $ io protos
                                         sendPacket ctx (Handshake [HsNextProtocolNegotiation proto])
                                         usingState_ ctx $ setNegotiatedProtocol proto
            -- client offered, server didn't pick up. do nothing.
            (Just _, Nothing) -> return ()
            -- client didn't offer. do nothing.
            (Nothing, _) -> return ()
    liftIO $ contextFlush ctx

    cf <- usingState_ ctx getVersion >>= \ver -> usingHState ctx $ getHandshakeDigest ver role
    sendPacket ctx (Handshake [Finished cf])
    liftIO $ contextFlush ctx

recvChangeCipherAndFinish :: Context -> IO ()
recvChangeCipherAndFinish ctx = runRecvState ctx (RecvStateNext expectChangeCipher)
  where expectChangeCipher ChangeCipherSpec = return $ RecvStateHandshake expectFinish
        expectChangeCipher p                = unexpected (show p) (Just "change cipher")
        expectFinish (Finished _) = return RecvStateDone
        expectFinish p            = unexpected (show p) (Just "Handshake Finished")

data RecvState m =
      RecvStateNext (Packet -> m (RecvState m))
    | RecvStateHandshake (Handshake -> m (RecvState m))
    | RecvStateDone

recvPacketHandshake :: Context -> IO [Handshake]
recvPacketHandshake ctx = do
    pkts <- recvPacket ctx
    case pkts of
        Right (Handshake l) -> return l
        Right x             -> fail ("unexpected type received. expecting handshake and got: " ++ show x)
        Left err            -> throwCore err

runRecvState :: Context -> RecvState IO -> IO ()
runRecvState _   (RecvStateDone)   = return ()
runRecvState ctx (RecvStateNext f) = recvPacket ctx >>= either throwCore f >>= runRecvState ctx
runRecvState ctx iniState          = recvPacketHandshake ctx >>= loop iniState >>= runRecvState ctx
  where
        loop :: RecvState IO -> [Handshake] -> IO (RecvState IO)
        loop recvState []                  = return recvState
        loop (RecvStateHandshake f) (x:xs) = do
            nstate <- f x
            processHandshake ctx x
            loop nstate xs
        loop _                         _   = unexpected "spurious handshake" Nothing

getSessionData :: Context -> IO (Maybe SessionData)
getSessionData ctx = do
    ver <- usingState_ ctx getVersion
    mms <- usingHState ctx (gets hstMasterSecret)
    tx  <- liftIO $ readMVar (ctxTxState ctx)
    case mms of
        Nothing -> return Nothing
        Just ms -> return $ Just $ SessionData
                        { sessionVersion = ver
                        , sessionCipher  = cipherID $ fromJust "cipher" $ stCipher tx
                        , sessionSecret  = ms
                        }
