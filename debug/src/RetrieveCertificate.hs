{-# LANGUAGE ScopedTypeVariables, DeriveDataTypeable, ViewPatterns #-}

import Network.TLS
import Network.TLS.Extra

import Data.IORef
import Data.X509
import Data.X509.Validation
import System.X509

import Control.Monad

import qualified Crypto.Random.AESCtr as RNG

import Data.PEM

import Text.Printf
import Text.Groom

import System.Console.GetOpt
import System.Environment
import System.Exit

import qualified Data.ByteString.Char8 as B

openConnection s p = do
    ref <- newIORef Nothing
    rng <- RNG.makeSystem
    let params = defaultParamsClient { pCiphers           = ciphersuite_all
                                     , onCertificatesRecv = \l -> do modifyIORef ref (const $ Just l)
                                                                     return CertificateUsageAccept
                                     }
    ctx <- connectionClient s p params rng
    _   <- handshake ctx
    bye ctx
    r <- readIORef ref
    case r of
        Nothing    -> error "cannot retrieve any certificate"
        Just certs -> return certs

data Flag = PrintChain
          | Format String
          | Verify
          | VerifyFQDN String
          | Help
          deriving (Show,Eq)

options :: [OptDescr Flag]
options =
    [ Option []     ["chain"]   (NoArg PrintChain) "output the chain of certificate used"
    , Option []     ["format"]  (ReqArg Format "format") "define the output format (full, pem, default: simple)"
    , Option []     ["verify"]  (NoArg Verify) "verify the chain received with the trusted system certificate"
    , Option []     ["verify-domain-name"]  (ReqArg VerifyFQDN "fqdn") "verify the chain against a specific FQDN"
    , Option ['h']  ["help"]    (NoArg Help) "request help"
    ]

showCert "pem" cert = B.putStrLn $ pemWriteBS pem
    where pem = PEM { pemName = "CERTIFICATE"
                    , pemHeader = []
                    , pemContent = encodeSignedObject cert
                    }
showCert "full" cert = putStrLn $ groom cert

showCert _ (signedCert)  = do
    putStrLn ("serial:   " ++ (show $ certSerial cert))
    putStrLn ("issuer:   " ++ (show $ certIssuerDN cert))
    putStrLn ("subject:  " ++ (show $ certSubjectDN cert))
    putStrLn ("validity: " ++ (show $ fst $ certValidity cert) ++ " to " ++ (show $ snd $ certValidity cert))
  where cert = getCertificate signedCert

printUsage =
    putStrLn $ usageInfo "usage: retrieve-certificate [opts] <hostname> [port]\n\n\t(port default to: 443)\noptions:\n" options

main = do
    args <- getArgs
    let (opts,other,errs) = getOpt Permute options args
    when (not $ null errs) $ do
        putStrLn $ show errs
        exitFailure

    when (Help `elem` opts) $ do
        printUsage
        exitSuccess

    case other of
        [destination,port] -> doMain destination port opts
        _                  -> printUsage >> exitFailure

  where outputFormat [] = "simple"
        outputFormat (Format s:_ ) = s
        outputFormat (_       :xs) = outputFormat xs

        doMain destination port opts = do
            _ <- printf "connecting to %s on port %s ...\n" destination port

            chain <- openConnection destination port
            let (CertificateChain certs) = chain
                format = outputFormat opts
            case PrintChain `elem` opts of
                True ->
                    forM_ (zip [0..] certs) $ \(n, cert) -> do
                        putStrLn ("###### Certificate " ++ show (n + 1 :: Int) ++ " ######")
                        showCert format cert
                False ->
                    showCert format $ head certs

            when (Verify `elem` opts) $ do
                store <- getSystemCertificateStore
                putStrLn "### certificate chain trust"
                let checks = (defaultChecks Nothing) { checkExhaustive = True }
                reasons <- validate checks store chain
                when (not $ null reasons) $ do putStrLn "fail validation:"
                                               putStrLn $ show reasons
