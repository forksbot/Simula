{-# LANGUAGE DuplicateRecordFields #-}
module Simula.ViveCompositor.ViveCompositor where

import Control.Concurrent
import Control.Lens
import Control.Monad
import qualified Data.Map as M
import Control.Concurrent.MVar
import Data.Hashable
import Data.Word
import Data.Typeable
import Data.Maybe
import Foreign
import Foreign.C
import Foreign.Ptr
import Graphics.Rendering.OpenGL hiding (scale, translate, rotate, Rect)
import Linear
import Linear.OpenGL
import System.Clock
import System.Environment
import System.Mem.StableName
import Simula.WaylandServer
import Simula.Weston
import Simula.WestonDesktop

import Simula.BaseCompositor.Compositor
import Simula.BaseCompositor.Geometry
import Simula.BaseCompositor.OpenGL
import Simula.BaseCompositor.SceneGraph
import Simula.BaseCompositor.SceneGraph.Wayland
import Simula.BaseCompositor.Wayland.Input
import Simula.BaseCompositor.Wayland.Output
import Simula.BaseCompositor.WindowManager
import Simula.BaseCompositor.Utils
import Simula.BaseCompositor.Types
import Simula.BaseCompositor.Weston hiding (moveCamera)

import OpenVR
import Graphics.Vulkan
import Data.List
import qualified Data.Vector.Storable.Sized as VF
import Data.Void

-- data family pattern
-- instance Compositor ViveCompositor where
--   data SimulaSurface ViveCompositor = ViveCompositorSurface {
--     _viveCompositorSurfaceBase :: BaseWaylandSurface,
--     _viveCompositorSurfaceSurface :: WestonDesktopSurface,
--     _viveCompositorSurfaceView :: WestonView,
--     _viveCompositorSurfaceCompositor :: MVar ViveCompositor,
--     _viveCompositorSurfaceTexture :: MVar (Maybe TextureObject),
--     _viveCompositorSurfaceStableName :: StableName (SimulaSurface ViveCompositor)
--   } deriving (Eq, Typeable)

data VulkanInfo  = VulkanInfo {
  _vulkanInstance :: VkInstance,
  _vulkanPhysicalDevice :: VkPhysicalDevice,
  _vulkanDevice :: VkDevice,
  _vulkanQueue :: VkQueue,
  _vulkanQueueFamilyIndex :: Word32,
  _vulkanCommandPool :: VkCommandPool,
  _vulkanCommandBuffer :: VkCommandBuffer
 }

data VulkanImage = VulkanImage {
  _imageStagingBuffer :: VkBuffer,
  _imageStagingMemory :: VkDeviceMemory,
  _imageBufferSize :: VkDeviceSize,
  _imageImage :: VkImage,
  _imageImageMemory :: VkDeviceMemory,
  _imageImageSize :: VkDeviceSize,
  _imageExtents :: VkExtent3D
}

data ViveCompositor = ViveCompositor {
  _viveCompositorBaseCompositor :: BaseCompositor,
  _viveCompositorVulkanInfo :: VulkanInfo,
  _viveCompositorVulkanLeftImage :: VulkanImage,
  _viveCompositorVulkanRightImage :: VulkanImage
}

makeLenses ''VulkanInfo
makeLenses ''VulkanImage
makeLenses ''ViveCompositor

newVulkanInfo :: IO VulkanInfo
newVulkanInfo = do
  iexts <- ("VK_EXT_debug_report":) <$> ivrCompositorGetVulkanInstanceExtensionsRequired
  iextPtrs <- mapM newCString iexts
  print iexts

  let valLayers = [ "VK_LAYER_LUNARG_parameter_validation"
                  , "VK_LAYER_LUNARG_core_validation"
                  , "VK_LAYER_LUNARG_object_tracker"
                  , "VK_LAYER_LUNARG_standard_validation"
                  , "VK_LAYER_GOOGLE_threading"]
  valLayerPtrs <- mapM newCString valLayers

  callbackPtr <- createDebugCallbackPtr $ \_ _ _ _ _ _ message _ -> peekCString message >>= print >> return (VkBool32 VK_FALSE)

  
  inst <- createInstance iextPtrs valLayerPtrs callbackPtr
  mapM_ free iextPtrs
  mapM_ free valLayerPtrs

  createDebugReport inst callbackPtr
  
  phys <- findPhysicalDevice inst

  Just idx <- alloca $ \numPtr -> do
    num <- vkGetPhysicalDeviceQueueFamilyProperties phys numPtr nullPtr >> peek numPtr
    props <- allocaArray (fromIntegral num) $ \arrayPtr -> vkGetPhysicalDeviceQueueFamilyProperties phys numPtr arrayPtr >> peekArray (fromIntegral num) arrayPtr
    return $ findIndex (\(VkQueueFamilyProperties flags _ _ _) -> flags .&. VK_QUEUE_GRAPHICS_BIT == VK_QUEUE_GRAPHICS_BIT) props

  let family = fromIntegral idx

  dexts <- ivrCompositorGetVulkanDeviceExtensionsRequired (castPtr phys)
  print dexts
  dextPtrs <- mapM newCString dexts
  dev <- createDevice inst phys dextPtrs family
  mapM_  free dextPtrs
  queue <- createQueue phys dev family
  pool <- createCommandPool dev family
  cmdBuffer <- createCommandBuffer dev pool
  return $ VulkanInfo inst phys dev queue family pool cmdBuffer

  where
    createInstance iexts layers callbackPtr = withCString "vive-compositor" $ \namePtr ->
      with VkApplicationInfo { vkSType = VK_STRUCTURE_TYPE_APPLICATION_INFO
                             , vkPNext = nullPtr
                             , vkPApplicationName = namePtr
                             , vkApplicationVersion = 1
                             , vkPEngineName = namePtr
                             , vkEngineVersion = 0
                             , vkApiVersion = vkMakeVersion 1 0 61
                             } $ \appInfo ->
      withArrayLen iexts $ \extCount extPtr ->
      withArrayLen layers $ \layerCount layerPtr ->
      with VkDebugReportCallbackCreateInfoEXT { vkSType = VkStructureType 1000011000
                                              , vkPNext = nullPtr
                                              , vkFlags = VK_DEBUG_REPORT_ERROR_BIT_EXT .|. VK_DEBUG_REPORT_WARNING_BIT_EXT
                                              , vkPfnCallback = callbackPtr
                                              , vkPUserData = nullPtr
                                              } $ \callbackInfo ->
      with VkInstanceCreateInfo { vkSType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO
                               , vkPNext = castPtr callbackInfo
                               , vkFlags = VkInstanceCreateFlags zeroBits
                               , vkPApplicationInfo = appInfo
                               , vkEnabledLayerCount = fromIntegral layerCount
                               , vkPpEnabledLayerNames = layerPtr
                               , vkEnabledExtensionCount = fromIntegral extCount
                               , vkPpEnabledExtensionNames = extPtr
                               } $ \instInfo ->
      alloca $ \instPtr -> vkCreateInstance instInfo nullPtr instPtr >> peek instPtr
   
    findPhysicalDevice inst = (intPtrToPtr . fromIntegral) <$> ivrSystemGetOutputDevice TextureType_Vulkan (castPtr inst)

    createDevice inst phys dexts family = with 1 $ \prioPtr ->
      with VkDeviceQueueCreateInfo { vkSType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO
                                   , vkPNext = nullPtr
                                   , vkFlags = VkDeviceQueueCreateFlags zeroBits
                                   , vkQueueFamilyIndex = family
                                   , vkQueueCount = 1
                                   , vkPQueuePriorities = prioPtr
                                   } $ \queueInfo ->
      withArrayLen dexts $ \extCount extPtr ->
      with VkDeviceCreateInfo { vkSType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO
                              , vkPNext = nullPtr
                              , vkFlags = VkDeviceCreateFlags 0
                              , vkQueueCreateInfoCount = 1
                              , vkPQueueCreateInfos = queueInfo
                              , vkEnabledLayerCount = 0
                              , vkPpEnabledLayerNames = nullPtr
                              , vkEnabledExtensionCount = fromIntegral extCount
                              , vkPpEnabledExtensionNames = extPtr
                              , vkPEnabledFeatures = nullPtr
                              } $ \deviceInfo ->
      alloca $ \devicePtr -> vkCreateDevice phys deviceInfo nullPtr devicePtr >> peek devicePtr
    createCommandPool dev family = 
      with VkCommandPoolCreateInfo { vkSType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO
                                   , vkPNext = nullPtr
                                   , vkFlags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT
                                   , vkQueueFamilyIndex = family
                                   } $ \poolInfo ->
      alloca $ \poolPtr -> vkCreateCommandPool dev poolInfo nullPtr poolPtr >> peek poolPtr

    createCommandBuffer dev pool = 
      with VkCommandBufferAllocateInfo { vkSType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO
                                       , vkPNext = nullPtr
                                       , vkCommandPool = pool
                                       , vkLevel = VK_COMMAND_BUFFER_LEVEL_PRIMARY
                                       , vkCommandBufferCount = 1
                                       } $ \allocInfo ->
      alloca $ \bufferPtr -> vkAllocateCommandBuffers dev allocInfo bufferPtr >> peek bufferPtr
    createQueue phys dev idx = do
      queue <- alloca $ \queuePtr -> vkGetDeviceQueue dev (fromIntegral idx) 0 queuePtr >> peek queuePtr
      return queue

    createDebugReport inst callbackPtr = do
      vkDebugFnPtr <- castFunPtr <$> (withCString "vkCreateDebugReportCallbackEXT" $ \ptr -> vkGetInstanceProcAddr inst ptr)
      print vkDebugFnPtr
      with VkDebugReportCallbackCreateInfoEXT { vkSType = VkStructureType 1000011000
                                              , vkPNext = nullPtr
                                              , vkFlags = VK_DEBUG_REPORT_ERROR_BIT_EXT .|. VK_DEBUG_REPORT_WARNING_BIT_EXT
                                              , vkPfnCallback = callbackPtr
                                              , vkPUserData = nullPtr
                                              } $ \callbackInfo ->
        alloca $ \cbPtr -> vkCreateDebugReportCallbackEXT' vkDebugFnPtr inst callbackInfo nullPtr cbPtr >> peek cbPtr
      


foreign import ccall "wrapper" createDebugCallbackPtr :: (VkDebugReportFlagsEXT -> VkDebugReportObjectTypeEXT -> Word64 -> CSize -> Int32 -> Ptr CChar -> Ptr CChar -> Ptr Void -> IO VkBool32) -> IO PFN_vkDebugReportCallbackEXT

foreign import ccall "dynamic" vkCreateDebugReportCallbackEXT' :: FunPtr (VkInstance ->  Ptr VkDebugReportCallbackCreateInfoEXT -> Ptr VkAllocationCallbacks -> Ptr VkDebugReportCallbackEXT -> IO VkResult) -> VkInstance ->  Ptr VkDebugReportCallbackCreateInfoEXT ->  Ptr VkAllocationCallbacks -> Ptr VkDebugReportCallbackEXT -> IO VkResult
      

-- creates an RGB image, 8bit/channel, no alpha
newVulkanImage :: VulkanInfo -> V2 Int -> IO VulkanImage
newVulkanImage info size = do
  (buffer, stagingMemory, bufferSize) <- createBuffer 
  (image, imageMemory, imageSize) <- createImage 
  transitionImage image
  return $ VulkanImage buffer stagingMemory bufferSize image imageMemory imageSize (VkExtent3D (fromIntegral $ size ^. _x) (fromIntegral $ size ^. _y) 1)
  
  where
    realSize = (size ^. _x) * (size ^. _y) * 4
    findMemory flags bits = do
      props <- alloca $ \propsPtr -> vkGetPhysicalDeviceMemoryProperties (info^.vulkanPhysicalDevice) propsPtr >> peek propsPtr
      -- TODO: make this non-partial
      Just idx <- return $ VF.ifoldr (\idx elem st -> case st of
        Nothing -> if vkPropertyFlags elem .&. flags == flags && ((bits `shiftR` (fromIntegral idx)) .&. 1 == 1)  then Just idx else Nothing
        rem -> rem) Nothing (vkMemoryTypes props)
      return idx
    allocateMemory flags size bits = do
      memoryTypeIndex <- findMemory flags bits
      with VkMemoryAllocateInfo { vkSType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO
                                , vkPNext = nullPtr
                                , vkAllocationSize = size
                                , vkMemoryTypeIndex = fromIntegral memoryTypeIndex
                                } $ \allocInfo ->
        alloca $ \memoryPtr -> vkAllocateMemory (info^.vulkanDevice) allocInfo nullPtr memoryPtr >> peek memoryPtr
    createBuffer = do
      buffer <- with VkBufferCreateInfo { vkSType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO
                              , vkPNext = nullPtr
                              , vkFlags = VkBufferCreateFlagBits zeroBits
                              , vkSize = VkDeviceSize $ fromIntegral realSize
                              , vkUsage = VK_BUFFER_USAGE_TRANSFER_SRC_BIT
                              , vkSharingMode = VK_SHARING_MODE_EXCLUSIVE
                              , vkQueueFamilyIndexCount = 0
                              , vkPQueueFamilyIndices = nullPtr
                              } $ \bufferInfo ->
        alloca $ \bufferPtr -> vkCreateBuffer (info^.vulkanDevice) bufferInfo nullPtr bufferPtr >> peek bufferPtr
      (VkMemoryRequirements size _ bits) <- alloca $ \memReqsPtr -> vkGetBufferMemoryRequirements (info^.vulkanDevice) buffer memReqsPtr >> peek memReqsPtr
      memory <- allocateMemory (VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT .|. VK_MEMORY_PROPERTY_HOST_COHERENT_BIT) size bits

      vkBindBufferMemory (info^.vulkanDevice) buffer memory (VkDeviceSize 0)
      return (buffer, memory, size)

    createImage = do
      image <- with VkImageCreateInfo { vkSType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO
                                      , vkPNext = nullPtr
                                      , vkFlags = zeroBits
                                      , vkImageType = VK_IMAGE_TYPE_2D
                                      , vkFormat = VK_FORMAT_R8G8B8A8_UNORM
                                      , vkExtent = VkExtent3D (fromIntegral $ size ^. _x) (fromIntegral $ size ^. _y) 1
                                      , vkMipLevels = 1
                                      , vkArrayLayers = 1
                                      , vkTiling = VK_IMAGE_TILING_OPTIMAL
                                      , vkSamples = VK_SAMPLE_COUNT_1_BIT
                                      , vkUsage = VK_IMAGE_USAGE_TRANSFER_DST_BIT .|. VK_IMAGE_USAGE_TRANSFER_SRC_BIT .|. VK_IMAGE_USAGE_SAMPLED_BIT
                                      , vkSharingMode = VK_SHARING_MODE_EXCLUSIVE
                                      , vkQueueFamilyIndexCount = 0
                                      , vkPQueueFamilyIndices = nullPtr
                                      , vkInitialLayout = VK_IMAGE_LAYOUT_UNDEFINED
                                      } $ \imageInfo ->
        alloca $ \imagePtr -> vkCreateImage (info^.vulkanDevice) imageInfo nullPtr imagePtr >>= print >> peek imagePtr
      (VkMemoryRequirements size _ bits) <- alloca $ \memReqsPtr -> vkGetImageMemoryRequirements (info^.vulkanDevice) image memReqsPtr >> peek memReqsPtr
      memory <- allocateMemory VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT size bits
      vkBindImageMemory (info^.vulkanDevice) image memory (VkDeviceSize 0)
      return (image, memory, size)
      
    transitionImage image = do
      beginCommand info
      with VkImageMemoryBarrier { vkSType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
                                , vkPNext = nullPtr
                                , vkSrcAccessMask = zeroBits
                                , vkDstAccessMask = VK_ACCESS_TRANSFER_READ_BIT
                                , vkOldLayout = VK_IMAGE_LAYOUT_UNDEFINED
                                , vkNewLayout = VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
                                , vkSrcQueueFamilyIndex = info ^. vulkanQueueFamilyIndex
                                , vkDstQueueFamilyIndex = info ^. vulkanQueueFamilyIndex
                                , vkImage = image 
                                , vkSubresourceRange = VkImageSubresourceRange VK_IMAGE_ASPECT_COLOR_BIT 0 1 0 1
                                } $ \barrier ->
        vkCmdPipelineBarrier (info^.vulkanCommandBuffer) VK_PIPELINE_STAGE_TRANSFER_BIT VK_PIPELINE_STAGE_TRANSFER_BIT zeroBits 0 nullPtr 0 nullPtr 1 barrier
      endCommand info

beginCommand :: VulkanInfo -> IO VkResult
beginCommand info = with VkCommandBufferBeginInfo { vkSType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO
                                             , vkPNext = nullPtr
                                             , vkFlags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT
                                             , vkPInheritanceInfo = nullPtr
                                             } $ \beginInfo -> vkBeginCommandBuffer (info ^. vulkanCommandBuffer) beginInfo

endCommand :: VulkanInfo -> IO VkResult
endCommand info = do
      vkEndCommandBuffer (info ^. vulkanCommandBuffer)

      with (info ^. vulkanCommandBuffer) $ \cmdBufferPtr ->
        with VkSubmitInfo { vkSType = VK_STRUCTURE_TYPE_SUBMIT_INFO
                          , vkPNext = nullPtr
                          , vkCommandBufferCount = 1
                          , vkPCommandBuffers = cmdBufferPtr
                          , vkWaitSemaphoreCount = 0
                          , vkPWaitSemaphores = nullPtr
                          , vkPWaitDstStageMask = nullPtr
                          , vkSignalSemaphoreCount = 0
                          , vkPSignalSemaphores = nullPtr
                          } $ \submitInfo ->
        vkQueueSubmit (info^.vulkanQueue) 1 submitInfo (VkFence 0)
      vkQueueWaitIdle (info^.vulkanQueue)
      vkResetCommandBuffer (info^.vulkanCommandBuffer) zeroBits

updateVulkanImage :: VulkanInfo -> VulkanImage -> TextureObject -> IO ()
updateVulkanImage info image tex = do
  transitionImage VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL VK_ACCESS_TRANSFER_READ_BIT VK_ACCESS_TRANSFER_WRITE_BIT
  copyToBuffer
  copyBufferToImage
  transitionImage VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL VK_ACCESS_TRANSFER_WRITE_BIT VK_ACCESS_TRANSFER_READ_BIT
  return ()

  where
    copyToBuffer = alloca $ \dataPtr -> do
      vkMapMemory (info^.vulkanDevice) (image^.imageStagingMemory) (VkDeviceSize 0) (image^.imageBufferSize) (VkMemoryMapFlags zeroBits) dataPtr
      dat <- peek dataPtr
      textureBinding Texture2D $= Just tex
      getTexImage Texture2D 0 (PixelData RGBA UnsignedByte dat)
      textureBinding Texture2D $= Nothing
      vkUnmapMemory (info^.vulkanDevice) (image^.imageStagingMemory)
                        
    copyBufferToImage = do
      beginCommand info
      with VkBufferImageCopy { vkBufferOffset = VkDeviceSize 0
                             , vkBufferRowLength = 0
                             , vkBufferImageHeight = 0
                             , vkImageSubresource = VkImageSubresourceLayers VK_IMAGE_ASPECT_COLOR_BIT 0 0 1
                             , vkImageOffset = VkOffset3D 0 0 0
                             , vkImageExtent = image^.imageExtents
                             } $ \region -> vkCmdCopyBufferToImage (info^.vulkanCommandBuffer) (image^.imageStagingBuffer) (image^.imageImage) VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL 1 region
      endCommand info

    transitionImage src dst srcMask dstMask = do
      beginCommand info
      with VkImageMemoryBarrier { vkSType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER
                                , vkPNext = nullPtr
                                , vkSrcAccessMask = srcMask
                                , vkDstAccessMask = dstMask
                                , vkOldLayout = src
                                , vkNewLayout = dst
                                , vkSrcQueueFamilyIndex = info ^. vulkanQueueFamilyIndex
                                , vkDstQueueFamilyIndex = info ^. vulkanQueueFamilyIndex
                                , vkImage = image^.imageImage
                                , vkSubresourceRange = VkImageSubresourceRange VK_IMAGE_ASPECT_COLOR_BIT 0 1 0 1
                                } $ \barrier ->
        vkCmdPipelineBarrier (info^.vulkanCommandBuffer) VK_PIPELINE_STAGE_TRANSFER_BIT VK_PIPELINE_STAGE_TRANSFER_BIT zeroBits 0 nullPtr 0 nullPtr 1 barrier
      endCommand info


       

newViveCompositor :: Scene -> Display -> IO ViveCompositor
newViveCompositor scene display = do
  wldp <- wl_display_create
  wcomp <- weston_compositor_create wldp nullPtr

  setup_weston_log_handler
  westonCompositorSetEmptyRuleNames wcomp

  --todo hack; make this into a proper withXXX function
  res <- with (WestonX11BackendConfig (WestonBackendConfig westonX11BackendConfigVersion (sizeOf (undefined :: WestonX11BackendConfig)))
           False
           False
           False) $ weston_compositor_load_backend wcomp WestonBackendX11 . castPtr

  when (res > 0) $ ioError $ userError "Error when loading backend"

  (_, initErr) <- vrInit VRApplication_Scene 

  case initErr of
    VRInitError_None -> return ()
    _ -> error $ show initErr


  blend $= Disabled
  
  socketName <- wl_display_add_socket_auto wldp
  putStrLn $ "Socket: " ++ socketName
  setEnv "WAYLAND_DISPLAY" socketName

  mainLayer <- newWestonLayer wcomp
  weston_layer_set_position mainLayer WestonLayerPositionNormal
  bgLayer <- newWestonLayer wcomp
  weston_layer_set_position mainLayer WestonLayerPositionBackground

  baseCompositor <- BaseCompositor scene display wldp wcomp
                <$> newMVar M.empty <*> newOpenGlData
                <*> newMVar Nothing <*> newMVar Nothing
                <*> pure mainLayer

  windowedApi <- weston_windowed_output_get_api wcomp

  let outputPendingSignal = westonCompositorOutputPendingSignal wcomp
  outputPendingPtr <- createNotifyFuncPtr (onOutputPending windowedApi baseCompositor)
  addListenerToSignal outputPendingSignal outputPendingPtr

  let outputCreatedSignal = westonCompositorOutputCreatedSignal wcomp
  outputCreatedPtr <- createNotifyFuncPtr (onOutputCreated baseCompositor)
  addListenerToSignal outputCreatedSignal outputCreatedPtr
 
  westonWindowedOutputCreate windowedApi wcomp "X"


  let api = defaultWestonDesktopApi {
        apiSurfaceAdded = onSurfaceCreated baseCompositor,
        apiSurfaceRemoved = onSurfaceDestroyed baseCompositor,
        apiCommitted = onSurfaceCommit baseCompositor
        }

  
  westonDesktopCreate wcomp api nullPtr

  let interface = defaultWestonPointerGrabInterface {
        grabPointerFocus = onPointerFocus baseCompositor,
        grabPointerButton = onPointerButton baseCompositor
        }

  interfacePtr <- new interface
  weston_compositor_set_default_pointer_grab wcomp interfacePtr

  putStrLn "Creating vulkan"

  info <- newVulkanInfo
  putStrLn "Created vulkan"
  -- hackhack
  recSize@(width, height) <- ivrSystemGetRecommendedRenderTargetSize
  print recSize
  let recVSize = V2 (fromIntegral width) (fromIntegral height)
  ViveCompositor baseCompositor info <$> newVulkanImage info recVSize <*> newVulkanImage info recVSize

  where
    onSurfaceCreated compositor surface  _ = do
      putStrLn "surface created"
      createSurface compositor surface
      return ()


    onSurfaceDestroyed compositor surface _ = do
      --TODO destroy surface in wm
      ws <- weston_desktop_surface_get_surface surface
      simulaSurface <- M.lookup ws <$> readMVar (compositor ^. baseCompositorSurfaceMap) 
      case simulaSurface of
        Just simulaSurface -> do
          modifyMVar' (compositor ^. baseCompositorSurfaceMap) (M.delete ws)
          let wm = compositor ^. baseCompositorScene.sceneWindowManager
          setSurfaceMapped simulaSurface False
          wmDestroySurface wm simulaSurface
        _ -> return ()
  
    onSurfaceCommit compositor surface x y _ = do
      ws <- weston_desktop_surface_get_surface surface
      simulaSurface <- M.lookup ws <$> readMVar (compositor ^. baseCompositorSurfaceMap)
      case simulaSurface of
        Just simulaSurface -> do
          setSurfaceMapped simulaSurface True
          -- need to figure out surface type
          return ()
        _ -> return ()

    onOutputPending windowedApi compositor _ outputPtr = do
      putStrLn "output pending"
      let output = WestonOutput $ castPtr outputPtr
      --TODO hack
      weston_output_set_scale output 1
      weston_output_set_transform output 0
      westonWindowedOutputSetSize windowedApi output 1512 1680

      weston_output_enable output
      return ()


    onOutputCreated compositor _ outputPtr = do
      putStrLn "output created"
      let output = WestonOutput $ castPtr outputPtr
      writeMVar (compositor ^. baseCompositorOutput) $ Just output
      let wc = compositor ^. baseCompositorWestonCompositor
      renderer <- westonCompositorGlRenderer wc
      eglctx <- westonGlRendererContext renderer
      egldp <- westonGlRendererDisplay renderer
      eglsurf <- westonOutputRendererSurface output
      let glctx = SimulaOpenGLContext eglctx egldp eglsurf

      writeMVar (compositor ^. baseCompositorGlContext) (Just $ SimulaOpenGLContext eglctx egldp eglsurf)
      return ()


    onPointerFocus compositor grab = do
      pointer <- westonPointerFromGrab grab
      pos' <- westonPointerPosition pointer
      let pos = (`div` 256) <$> pos'
      setFocusForPointer compositor pointer pos
                     
      
    onPointerButton compositor grab time button state = do
      pointer <- westonPointerFromGrab grab
      pos' <- westonPointerPosition pointer
      let pos = (`div` 256) <$> pos'
      setFocusForPointer compositor pointer pos
      weston_pointer_send_button pointer time button state

viveCompositorRender :: ViveCompositor -> IO ()
viveCompositorRender viveComp = do


  let comp = viveComp ^. viveCompositorBaseCompositor

  surfaceMap <- readMVar (comp ^. baseCompositorSurfaceMap)
  Just glctx <- readMVar (comp ^. baseCompositorGlContext)
  Just output <- readMVar (comp ^. baseCompositorOutput)

  glCtxMakeCurrent glctx
  bindVertexArrayObject $= Just (comp ^. baseCompositorOpenGlData.openGlVAO)

  -- set up context

  let surfaces = M.keys surfaceMap
  let scene  = comp ^. baseCompositorScene
  let simDisplay = comp ^. baseCompositorDisplay

  checkForErrors
  time <- getTime Realtime
  scenePrepareForFrame scene time
  checkForErrors
  weston_output_schedule_repaint output

  sceneDrawFrame scene
  checkForErrors
  Some seat <- compositorSeat comp
  pointer <- seatPointer seat
  pos <- readMVar (pointer ^. pointerGlobalPosition)
  drawMousePointer (comp ^. baseCompositorDisplay) (comp ^. baseCompositorOpenGlData.openGlDataMousePointer) pos

  emitOutputFrameSignal output
  eglSwapBuffers (glctx ^. simulaOpenGlContextEglDisplay) (glctx ^. simulaOpenGlContextEglSurface)
  sceneFinishFrame scene
  checkForErrors

  let tex = comp ^. baseCompositorDisplay.displayScratchColorBufferTexture
  let info = viveComp^.viveCompositorVulkanInfo
  let leftImage = viveComp^.viveCompositorVulkanLeftImage
  let rightImage = viveComp^.viveCompositorVulkanRightImage
  let (VkImage leftHandle) = leftImage^.imageImage
  let (VkImage rightHandle) = rightImage^.imageImage

  let (VkFormat format) = VK_FORMAT_R8G8B8A8_UNORM
  updateVulkanImage info leftImage tex
  updateVulkanImage info rightImage tex

  let (VkExtent3D width height _) = leftImage^.imageExtents --identical

  with (VRTextureBounds 0 0 1 1) $ \boundsPtr -> do
    with (VRVulkanTextureData leftHandle (castPtr $ info^.vulkanDevice) (castPtr $ info^.vulkanPhysicalDevice)
           (castPtr $ info^.vulkanInstance) (castPtr $ info^.vulkanQueue) (info^.vulkanQueueFamilyIndex) width height
           (fromIntegral format) 1) $ \texDataPtr' -> do
      let texDataPtr = castPtr texDataPtr'
      err <- with (OVRTexture texDataPtr TextureType_Vulkan ColorSpace_Auto) $ \txPtr ->
        ivrCompositorSubmit Eye_Left txPtr boundsPtr Submit_Default

      when (err /= VRCompositorError_None) $ print err

    with (VRVulkanTextureData rightHandle (castPtr $ info^.vulkanDevice) (castPtr $ info^.vulkanPhysicalDevice)
           (castPtr $ info^.vulkanInstance) (castPtr $ info^.vulkanQueue) (info^.vulkanQueueFamilyIndex) width height
           (fromIntegral format) 1) $ \texDataPtr' -> do
      let texDataPtr = castPtr texDataPtr'

      err <- with (OVRTexture texDataPtr TextureType_Vulkan ColorSpace_Auto) $ \txPtr ->
        ivrCompositorSubmit Eye_Right txPtr boundsPtr Submit_Default

      when (err /= VRCompositorError_None) $ print err

  ivrCompositorWaitGetPoses
  bindVertexArrayObject $= Nothing

  return ()

instance Compositor ViveCompositor where
  startCompositor viveComp = do
    debugOutput $= Enabled
    debugMessageCallback $= Just (\msg -> do
      print msg)
--      fbStatus <- get $ framebufferStatus Framebuffer
--      dfbStatus <- get $ framebufferStatus DrawFramebuffer
--      rfbStatus <- get $ framebufferStatus ReadFramebuffer
--      putStrLn $ "Framebuffer status: " ++ show fbStatus
--      putStrLn $ "Draw framebuffer status: " ++ show dfbStatus
--      putStrLn $ "Read framebuffer status: " ++ show rfbStatus)
    let comp = viveComp ^. viveCompositorBaseCompositor
    let wc = comp ^. baseCompositorWestonCompositor
    oldFunc <- getRepaintOutput wc
    newFunc <- createRendererRepaintOutputFunc (onRender viveComp oldFunc)
    setRepaintOutput wc newFunc
    weston_compositor_wake wc
    putStrLn "Compositor start"

    Just output <- readMVar (comp ^. baseCompositorOutput)
    forkOS $ forever $ weston_output_schedule_repaint output >> threadDelay 1000
    forkIO $ forever $ do
        let scene = comp ^. baseCompositorScene
        diffTime <- liftM2 diffTimeSpec (readMVar $ scene ^. sceneLastTimestamp) (readMVar $ scene ^. sceneCurrentTimestamp)
        let diff = fromIntegral $ toNanoSecs diffTime
        let fps = floor (10^9/diff)
        putStrLn $ "FPS: " ++ show fps
        threadDelay 1000000


    wl_display_run $ comp ^. baseCompositorWlDisplay

    where
      onRender viveComp oldFunc output damage = viveCompositorRender viveComp

  compositorDisplay viveComp = do
    return (viveComp ^. viveCompositorBaseCompositor . baseCompositorDisplay)

  compositorWlDisplay viveComp =
    viveComp ^. viveCompositorBaseCompositor . baseCompositorWlDisplay

  compositorOpenGLContext viveComp = do
    let baseComp = viveComp ^. viveCompositorBaseCompositor
    Just glctx <- readMVar (baseComp ^. baseCompositorGlContext)
    return (Some glctx)

  compositorSeat viveComp = return (viveComp ^. viveCompositorBaseCompositor . baseCompositorScene.sceneWindowManager.windowManagerDefaultSeat)
    
  compositorGetSurfaceFromResource viveComp resource = do
    let comp = (viveComp ^. viveCompositorBaseCompositor)
    ptr <- wlResourceData resource    
    let ws = WestonSurface (castPtr ptr)
    surface <- weston_surface_get_desktop_surface ws
    putStr "resource ptr: "
    print ptr
    simulaSurface <- M.lookup ws <$> readMVar (comp ^. baseCompositorSurfaceMap)
    case simulaSurface of
      Just simulaSurface -> return (Some simulaSurface)
      _ -> do
        simulaSurface <- createSurface comp surface
        return (Some simulaSurface)
