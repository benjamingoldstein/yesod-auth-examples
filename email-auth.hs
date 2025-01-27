{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE QuasiQuotes           #-}
{-# LANGUAGE TemplateHaskell       #-}
{-# LANGUAGE TypeFamilies          #-}
import           Control.Monad            (join)
import           Control.Monad.Logger (runNoLoggingT)
import           Data.Maybe               (isJust)
import qualified Data.Text.Lazy.Encoding
import           Data.Typeable            (Typeable)
import           Database.Persist.Sqlite
import           Database.Persist.TH
import           Network.Mail.Mime
import           Network.Mail.Mime.SES
import           Text.Blaze.Html.Renderer.Utf8 (renderHtml)
import           Text.Hamlet              (shamlet)
import           Text.Shakespeare.Text    (stext)
import           Yesod
import           Yesod.Auth
import           Yesod.Auth.Email
import           SESCreds (access, secret)
import           Data.Text (Text, pack, unpack)
import           Data.Text.Encoding (encodeUtf8)
import qualified Data.ByteString.Lazy.UTF8 as LU
import Network.HTTP.Conduit (newManager, conduitManagerSettings)
import Network.HTTP.Conduit (Manager)
import Text.Blaze.Html.Renderer.Utf8 (renderHtml)
share [mkPersist sqlSettings { mpsGeneric = False }, mkMigrate "migrateAll"] [persistLowerCase|
User
    email Text
    password Text Maybe -- Password may not be set yet
    verkey Text Maybe -- Used for resetting passwords
    verified Bool
    UniqueUser email
    deriving Typeable
|]

data App = App 
            { httpManager :: Manager,
			  connPool :: Connection
            }

mkYesod "App" [parseRoutes|
/ HomeR GET
/auth AuthR Auth getAuth
|]

instance Yesod App where
    -- Emails will include links, so be sure to include an approot so that
    -- the links are valid!
    approot = ApprootStatic "http://localhost:3000"

instance RenderMessage App FormMessage where
    renderMessage _ _ = defaultFormMessage

-- Set up Persistent
instance YesodPersist App where
    type YesodPersistBackend App = SqlPersistT
    runDB f = do
        h <- getYesod
        runSqlConn f $ connPool h

instance YesodAuth App where
    type AuthId App = UserId

    loginDest _ = HomeR
    logoutDest _ = HomeR
    authPlugins _ = [authEmail]

    -- Need to find the UserId for the given email address.
    getAuthId creds = runDB $ do
        x <- insertBy $ User (credsIdent creds) Nothing Nothing False
        return $ Just $
            case x of
                Left (Entity userid _) -> userid -- newly added user
                Right userid -> userid -- existing user

    authHttpManager = error "Email doesn't need an HTTP manager"

-- Here's all of the email-specific code
instance YesodAuthEmail App where
    type AuthEmailId App = UserId

    afterPasswordRoute _ = HomeR

    addUnverified email verkey =
        runDB $ insert $ User email Nothing (Just verkey) False

    sendVerifyEmail email _ verurl = sendEmail email verurl
      where
        textPart = Part
            { partType = "text/plain; charset=utf-8"
            , partEncoding = None
            , partFilename = Nothing
            , partContent = Data.Text.Lazy.Encoding.encodeUtf8
                [stext|
                    Please confirm your email address by clicking on the link below.

                    #{verurl}

                    Thank you
                |]
            , partHeaders = []
            }
        htmlPart = Part
            { partType = "text/html; charset=utf-8"
            , partEncoding = None
            , partFilename = Nothing
            , partContent = renderHtml
                [shamlet|
                    <p>Please confirm your email address by clicking on the link below.
                    <p>
                        <a href=#{verurl}>#{verurl}
                    <p>Thank you
                |]
            , partHeaders = []
            }
    getVerifyKey = runDB . fmap (join . fmap userVerkey) . get
    setVerifyKey uid key = runDB $ update uid [UserVerkey =. Just key]
    verifyAccount uid = runDB $ do
        mu <- get uid
        case mu of
            Nothing -> return Nothing
            Just u -> do
                update uid [UserVerified =. True]
                return $ Just uid
    getPassword = runDB . fmap (join . fmap userPassword) . get
    setPassword uid pass = runDB $ update uid [UserPassword =. Just pass]
    getEmailCreds email = runDB $ do
        mu <- getBy $ UniqueUser email
        case mu of
            Nothing -> return Nothing
            Just (Entity uid u) -> return $ Just EmailCreds
                { emailCredsId = uid
                , emailCredsAuthId = Just uid
                , emailCredsStatus = isJust $ userPassword u
                , emailCredsVerkey = userVerkey u
                , emailCredsEmail = email
                }
    getEmail = runDB . fmap (fmap userEmail) . get

------------



sendEmail email url = do

    let ses = SES
              { sesFrom = "gtk@gtk.am"
                    , sesTo = [encodeUtf8 email]
                    , sesAccessKey = encodeUtf8 $ pack access
                    , sesSecretKey = encodeUtf8 $ pack secret
              }
    h <- getYesod
    lift $ renderSendMailSES ( httpManager h) ses Mail
                { mailHeaders =
                    [ ("Subject", "Verify your email address")
                    ]
                , mailFrom = Address Nothing "gtk@gtk.am"
                , mailTo = [Address Nothing email]
                , mailCc = []
                , mailBcc = []
                , mailParts = return
                    [ Part "text/plain" None Nothing [] $ LU.fromString $ unlines
                        [ "Please go to the URL below to verify your email address."
                        , ""
                        , unpack url
                        ]
                    , Part "text/html" None Nothing [] $ renderHtml [shamlet|\
<img src="" alt="Haskellers">
<p>Please go to the URL below to verify your email address.
<p>
    <a href="#{url}">#{url}
|]
                    ]
                }



----------------------	
	
	
getHomeR :: Handler Html
getHomeR = do
    maid <- maybeAuthId
    defaultLayout
        [whamlet|
            <p>Your current auth ID: #{show maid}
            $maybe _ <- maid
                <p>
                    <a href=@{AuthR LogoutR}>Logout
            $nothing
                <p>
                    <a href=@{AuthR LoginR}>Go to the login page
        |]

main :: IO ()
main = do
        manager <- newManager conduitManagerSettings
        withSqliteConn "email.db3" $ \conn -> do
        runNoLoggingT $ runSqlConn (runMigration migrateAll) conn
        warp 3000 $ App manager conn