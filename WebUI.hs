
{-# LANGUAGE OverloadedStrings, LambdaCase, ScopedTypeVariables #-}

module WebUI ( webUIStart
             , LightUpdate(..)
             , LightUpdateTChan
             ) where

import Text.Printf
import Data.Monoid
import Data.List
import Data.Word
import qualified Data.Function (on)
import qualified Data.HashMap.Strict as HM
import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Lens hiding ((#), set, (<.>), element)
import Control.Monad
import Control.Exception
import Control.Monad.IO.Class
import qualified Graphics.UI.Threepenny as UI
import Graphics.UI.Threepenny.Core
import System.FilePath

import Trace
import HueJSON
import LightColor

-- Threepenny based user interface for inspecting and controlling Hue devices

-- TODO: No support for changing any light state

webUIStart :: MonadIO m => TVar Lights -> LightUpdateTChan -> m ()
webUIStart lights tchan' = do
    -- Duplicate broadcast channel
    tchan <- liftIO . atomically $ dupTChan tchan'
    -- Start server
    let port = 8001
    traceS TLInfo $ "Starting web server on all interfaces, port " <> show port
    liftIO . startGUI
        defaultConfig { jsPort       = Just port
                      , jsAddr       = Just "0.0.0.0" -- All interfaces, not just loopback
                      , jsLog        = traceB TLInfo -- \_ -> return ()
                      , jsStatic     = Just "static"
                      , jsCustomHTML = Just "dashboard.html"
                      }
        $ setup lights tchan

setup :: TVar Lights -> LightUpdateTChan -> Window -> UI ()
setup lights' tchan window = do
    -- Title
    void $ return window # set title "Hue Dashboard"

    -- TODO: Bootrap's JS features need jQuery, but the version included in threepenny
    --       is too old to be supported. It seems we can't use any of the JS features in
    --       Bootstrap until it is updated
    --
    -- Bootstrap JS, should be in the body
    -- void $ getBody window #+
    --     [mkElement "script" & set (attr "src") ("static/bootstrap/js/bootstrap.min.js")]

    -- Lights, display sorted by name
    lights <- liftIO . atomically
                   $ (sortBy (compare `Data.Function.on` (^. _2 . lgtName)) . HM.toList)
                  <$> readTVar lights'
    -- Create all light tiles
    --
    -- TODO: This of course duplicates some code from the update routines, maybe just
    --       build the skeleton here and let the updating set all actual state?
    --
    getElementByIdSafe window "lights" >>= \case
      Nothing   -> return ()
      Just root ->
        void $ element root #+
          [ UI.div #. "thumbnails" #+
              ((flip map) lights $ \(lightID, light) ->
                let opacity       = if light ^. lgtState ^. lsOn then "1.0" else "0.25"
                    brightPercent = printf "%.0f%%"
                                      ( fromIntegral (light ^. lgtState . lsBrightness . non 255)
                                        * 100 / 255 :: Float
                                      )
                    colorStr      = htmlColorFromRGB . colorFromLight $ light
                in  ( UI.div #. "thumbnail" & set style [("opacity", opacity)]
                                            & set UI.id_ (buildID lightID "tile")
                    ) #+
                    [ UI.div #. "light-caption small" #+ [string $ light ^. lgtName]
                    , UI.img #. "img-rounded" & set style [ ("background", colorStr)]
                                              & set UI.src (iconFromLM $ light ^. lgtModelID)
                                              & set UI.id_ (buildID lightID "image")
                    , UI.div #. "text-center" #+
                      [ UI.h6 #+
                        [ UI.small #+
                          [ string $ (show $ light ^. lgtModelID)
                          , UI.br
                          , string $ (show $ light ^. lgtType)
                          ]
                        ]
                      ]
                    , UI.div #. "small text-center" #+ [string "Brightness"]
                    , UI.div #. "progress" #+
                      [ ( UI.div #. "progress-bar progress-bar-info"
                                  & set style [("width", brightPercent)]
                                  & set UI.id_ (buildID lightID "brightness-bar")
                        ) #+
                        [ UI.small #+
                          [ string brightPercent & set UI.id_ (buildID lightID "brightness-text")
                          ]
                        ]
                      ]
                    ]
              )
          ]
    -- Worker thread for receiving light updates
    updateWorker <- liftIO $ async $ lightUpdateWorker window tchan
    on UI.disconnect window . const . liftIO $
        cancel updateWorker

-- Channel with light ID and update pair
type LightUpdateTChan = TChan (String, LightUpdate)

-- Different updates to the displayed light state
data LightUpdate = LU_OnOff      !Bool
                 | LU_Brightness !Word8
                 | LU_Color      !(Float, Float, Float) -- RGB
                   deriving Show

-- Update DOM elements with light update messages received
--
-- TODO: We don't handle addition / removal of lights or changes in properties like the
--       name. Need to refresh page for those to show up. Maybe that's OK?
--
lightUpdateWorker :: Window -> LightUpdateTChan -> IO ()
lightUpdateWorker window tchan = runUI window $ loop
  where
    loop = do (liftIO . atomically $ readTChan tchan) >>=
                \(lightID, update) -> case update of
                  LU_OnOff s ->
                      getElementByIdSafe window (buildID lightID "tile") >>= \case
                        Just e  ->
                          void $ return e & set style [("opacity", if s then "1.0" else "0.25")]
                        Nothing -> return ()
                  LU_Brightness brightness -> do
                      let brightPercent = printf "%.0f%%"
                                                 (fromIntegral brightness * 100 / 255 :: Float)
                      getElementByIdSafe window (buildID lightID "brightness-bar") >>= \case
                        Just e  ->
                          void $ return e & set style [("width", brightPercent)]
                        Nothing -> return ()
                      getElementByIdSafe window (buildID lightID "brightness-text") >>= \case
                        Just e  ->
                          void $ return e & set UI.text brightPercent
                        Nothing -> return ()
                  LU_Color rgb ->
                      getElementByIdSafe window (buildID lightID "image") >>= \case
                        Just e  ->
                          void $ return e & set style [("background", htmlColorFromRGB rgb)]
                        Nothing -> return ()
              loop

-- Build a string for the id field in a DOM object. Do this in one place as we need to
-- locate them later when we want to update
buildID :: String -> String -> String
buildID lightID elemName = "light-" <> lightID <> "-" <> elemName

-- The getElementById function return a Maybe, but actually just throws an exception if
-- the element is not found. The exception is unfortunately completely unhelpful in
-- tracking down the reason why the page couldn't be generated. UI is unfortunately also
-- not MonadCatch, so we have to make due with runUI for the call
getElementByIdSafe :: Window -> String -> UI (Maybe Element)
getElementByIdSafe window elementID =
    (liftIO $ try (runUI window $ getElementById window elementID)) >>= \case
        Left (e :: SomeException) -> do
            traceS TLWarn $ printf "getElementById for '%s' failed: %s" elementID (show e)
            return Nothing
        Right Nothing -> do
            traceS TLWarn $ printf "getElementById for '%s' failed" elementID
            return Nothing
        Right (Just e) ->
            return $ Just e

iconFromLM :: LightModel -> FilePath
iconFromLM lm = basePath </> fn <.> ext
  where
    basePath = "static/svg"
    ext      = "svg"
    fn       = case lm of LM_HueBulbA19                -> "white_and_color_e27"
                          LM_HueSpotBR30               -> "br30"
                          LM_HueSpotGU10               -> "gu10"
                          LM_HueLightStrips            -> "lightstrip"
                          LM_HueLivingColorsIris       -> "iris"
                          LM_HueLivingColorsBloom      -> "bloom"
                          LM_LivingColorsGen3Iris      -> "iris"
                          LM_LivingColorsGen3BloomAura -> "bloom"
                          LM_HueA19Lux                 -> "white_e27"
                          LM_ColorLightModule          -> "white_and_color_e27"
                          LM_ColorTemperatureModule    -> "white_e27"
                          LM_HueGo                     -> "go"
                          LM_HueLightStripsPlus        -> "lightstrip"
                          LM_Unknown _                 -> "white_e27"
