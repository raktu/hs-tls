module Connection
    ( newPairContext
    , arbitraryPairParams
    , setPairParamsSessionManager
    , setPairParamsSessionResuming
    , establishDataPipe
    , blockCipher
    , streamCipher
    ) where

import Test.QuickCheck
import Certificate
import PubKey
import PipeChan
import Network.TLS
import Data.X509
import Control.Concurrent.Chan
import Control.Concurrent
import qualified Control.Exception as E

import qualified Crypto.Random.AESCtr as RNG
import qualified Data.ByteString as B

debug = False

blockCipher :: Cipher
blockCipher = Cipher
    { cipherID   = 0xff12
    , cipherName = "rsa-id-const"
    , cipherBulk = Bulk
        { bulkName      = "id"
        , bulkKeySize   = 16
        , bulkIVSize    = 16
        , bulkBlockSize = 16
        , bulkF         = BulkBlockF (\_ _ m -> m) (\_ _ m -> m)
        }
    , cipherHash = Hash
        { hashName = "const-hash"
        , hashSize = 16
        , hashF    = (\_ -> B.replicate 16 1)
        }
    , cipherKeyExchange = CipherKeyExchange_RSA
    , cipherMinVer      = Nothing
    }

streamCipher = blockCipher
    { cipherID   = 0xff13
    , cipherBulk = Bulk
        { bulkName      = "stream"
        , bulkKeySize   = 16
        , bulkIVSize    = 0
        , bulkBlockSize = 0
        , bulkF         = BulkStreamF (\k -> k) (\i m -> (m,i)) (\i m -> (m,i))
        }
    }

supportedCiphers :: [Cipher]
supportedCiphers = [blockCipher,streamCipher]

supportedVersions :: [Version]
supportedVersions = [SSL3,TLS10,TLS11,TLS12]

arbitraryPairParams = do
    let (pubKey, privKey) = getGlobalRSAPair
    servCert          <- arbitraryX509WithPublicKey pubKey
    allowedVersions   <- arbitraryVersions
    connectVersion    <- elements supportedVersions `suchThat` (\c -> c `elem` allowedVersions)
    serverCiphers     <- arbitraryCiphers
    clientCiphers     <- oneof [arbitraryCiphers] `suchThat` (\cs -> or [x `elem` serverCiphers | x <- cs])
    secNeg            <- arbitrary

    let serverState = defaultParamsServer
            { pAllowedVersions        = allowedVersions
            , pCiphers                = serverCiphers
            , pCertificates           = Just (CertificateChain [servCert], Just $ PrivKeyRSA privKey)
            , pUseSecureRenegotiation = secNeg
            , pLogging                = logging "server: "
            }
    let clientState = defaultParamsClient
            { pConnectVersion         = connectVersion
            , pAllowedVersions        = allowedVersions
            , pCiphers                = clientCiphers
            , pUseSecureRenegotiation = secNeg
            , pLogging                = logging "client: "
            }
    return (clientState, serverState)
  where
        logging pre =
            if debug
                then defaultLogging { loggingPacketSent = putStrLn . ((pre ++ ">> ") ++)
                                    , loggingPacketRecv = putStrLn . ((pre ++ "<< ") ++) }
                else defaultLogging
        arbitraryVersions :: Gen [Version]
        arbitraryVersions = resize (length supportedVersions + 1) $ listOf1 (elements supportedVersions)
        arbitraryCiphers  = resize (length supportedCiphers + 1) $ listOf1 (elements supportedCiphers)

setPairParamsSessionManager :: SessionManager -> (Params, Params) -> (Params, Params)
setPairParamsSessionManager manager (clientState, serverState) = (nc,ns)
  where nc = setSessionManager manager clientState
        ns = setSessionManager manager serverState

setPairParamsSessionResuming sessionStuff (clientState, serverState) = (nc,serverState)
  where nc = updateClientParams (\cparams -> cparams { clientWantSessionResume = Just sessionStuff }) clientState

newPairContext pipe (cParams, sParams) = do
    let noFlush = return ()
    let noClose = return ()

    cRNG <- RNG.makeSystem
    sRNG <- RNG.makeSystem

    let cBackend = Backend noFlush noClose (writePipeA pipe) (readPipeA pipe)
    let sBackend = Backend noFlush noClose (writePipeB pipe) (readPipeB pipe)
    cCtx' <- contextNew cBackend cParams cRNG
    sCtx' <- contextNew sBackend sParams sRNG

    return (cCtx', sCtx')

establishDataPipe params tlsServer tlsClient = do
    -- initial setup
    pipe        <- newPipe
    _           <- (runPipe pipe)
    startQueue  <- newChan
    resultQueue <- newChan

    (cCtx, sCtx) <- newPairContext pipe params

    _ <- forkIO $ E.catch (tlsServer sCtx resultQueue) (printAndRaise "server")
    _ <- forkIO $ E.catch (tlsClient startQueue cCtx) (printAndRaise "client")

    return (startQueue, resultQueue)
  where
        printAndRaise :: String -> E.SomeException -> IO ()
        printAndRaise s e = putStrLn (s ++ " exception: " ++ show e) >> E.throw e
