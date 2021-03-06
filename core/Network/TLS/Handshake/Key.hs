-- |
-- Module      : Network.TLS.Handshake.Key
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- functions for RSA operations
--
module Network.TLS.Handshake.Key
    ( encryptRSA
    , signRSA
    , decryptRSA
    , verifyRSA
    ) where

import Control.Monad.State

import Data.ByteString (ByteString)
import qualified Data.ByteString as B

import Network.TLS.Util
import Network.TLS.Handshake.State
import Network.TLS.State (withRNG, getVersion)
import Network.TLS.Crypto
import Network.TLS.Types
import Network.TLS.Context

{- if the RSA encryption fails we just return an empty bytestring, and let the protocol
 - fail by itself; however it would be probably better to just report it since it's an internal problem.
 -}
encryptRSA :: Context -> ByteString -> IO ByteString
encryptRSA ctx content = do
    rsakey <- return . fromJust "rsa public key" =<< handshakeGet ctx hstRSAPublicKey
    usingState_ ctx $ do
        v      <- withRNG (\g -> kxEncrypt g rsakey content)
        case v of
            Left err       -> fail ("rsa encrypt failed: " ++ show err)
            Right econtent -> return econtent

signRSA :: Context -> HashDescr -> ByteString -> IO ByteString
signRSA ctx hsh content = do
    rsakey <- return . fromJust "rsa client private key" =<< handshakeGet ctx hstRSAClientPrivateKey
    usingState_ ctx $ do
        r      <- withRNG (\g -> kxSign g rsakey hsh content)
        case r of
            Left err       -> fail ("rsa sign failed: " ++ show err)
            Right econtent -> return econtent

decryptRSA :: Context -> ByteString -> IO (Either KxError ByteString)
decryptRSA ctx econtent = do
    rsapriv <- return . fromJust "rsa private key" =<< handshakeGet ctx hstRSAPrivateKey
    usingState_ ctx $ do
        ver     <- getVersion
        let cipher = if ver < TLS10 then econtent else B.drop 2 econtent
        withRNG (\g -> kxDecrypt g rsapriv cipher)

verifyRSA :: Context -> HashDescr -> ByteString -> ByteString -> IO Bool
verifyRSA ctx hsh econtent sign = do
    rsapriv <- return . fromJust "rsa client public key" =<< handshakeGet ctx hstRSAClientPublicKey
    return $ kxVerify rsapriv hsh econtent sign

handshakeGet :: Context -> (HandshakeState -> a) -> IO a
handshakeGet ctx f = usingHState ctx (gets f)
