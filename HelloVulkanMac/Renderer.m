
#import "Renderer.h"
#import "MathUtilities.h"
#import "Cube.h"

#define VK_USE_PLATFORM_MACOS_MVK
#include <vulkan/vulkan.h>
#include <vulkan/vk_sdk_platform.h>

#define MAX_PENDING_PRESENTS 2
#define PREFERRED_SWAP_IMAGE_COUNT 3
#define TEXTURE_COUNT 1

#define APP_NAME "MoltenVK for Mac Demo"

#define GET_INSTANCE_PROC_ADDR(inst, entrypoint)                                                  \
{                                                                                                 \
    fp##entrypoint = (PFN_vk##entrypoint)vkGetInstanceProcAddr(inst, "vk" #entrypoint);           \
    if (fp##entrypoint == NULL) {                                                                 \
        NSAssert(fp##entrypoint != NULL, @"vkGetInstanceProcAddr failed to find vk" #entrypoint); \
    }                                                                                             \
}

#define GET_DEVICE_PROC_ADDR(dev, entrypoint)                                                                  \
{                                                                                                              \
    if (fpGetDeviceProcAddr == NULL) {                                                                         \
        fpGetDeviceProcAddr = (PFN_vkGetDeviceProcAddr)vkGetInstanceProcAddr(instance, "vkGetDeviceProcAddr"); \
    }                                                                                                          \
    fp##entrypoint = (PFN_vk##entrypoint)fpGetDeviceProcAddr(dev, "vk" #entrypoint);                           \
    if (fp##entrypoint == NULL) {                                                                              \
        NSAssert(fp##entrypoint != NULL, @"vkGetDeviceProcAddr failed to find vk" #entrypoint);                \
    }                                                                                                          \
}

typedef struct {
    VkImage image;
    VkCommandBuffer commandBuffer;
    VkCommandBuffer presentCommandBuffer; // more properly though of as a resource transition buffer; used when present is on a separate queue
    VkImageView imageView;
    VkBuffer uniformBuffer;
    VkDeviceMemory uniformMemory;
    VkFramebuffer framebuffer;
    VkDescriptorSet descriptorSet;
} SwapchainResources;

typedef struct {
    VkImage image;
    VkImageLayout imageLayout;
    VkImageView imageView;
    VkSampler sampler;
    VkMemoryAllocateInfo allocationInfo;
    VkDeviceMemory memory;
    uint32_t width;
    uint32_t height;
} Texture;

typedef struct {
    VkImage image;
    VkImageView imageView;
    VkFormat format;
    VkMemoryAllocateInfo allocationInfo;
    VkDeviceMemory memory;
} DepthTexture;

typedef struct {
    simd_float4x4 modelViewProjectionMatrix;
    simd_float4x4 normalMatrix;
    float positions[12 * 3 * 4];
    float normals[12 * 3 * 4];
    float texCoords[12 * 3 * 4];
} Uniforms;

@interface Renderer () <MTKViewDelegate> {
    VkInstance instance;
    
    uint32_t enabledExtensionCount;
    uint32_t enabledLayerCount;
    char *enabledExtensionNames[8];
    char *enabledLayerNames[8];
    
    VkDevice device;
    VkPhysicalDevice physDevice;
    VkPhysicalDeviceProperties physDeviceProperties;
    VkPhysicalDeviceMemoryProperties physDeviceMemProperties;
    
    VkCommandBuffer initCommandBuffer;
    
    VkQueueFamilyProperties *queueFamilyProperties;
    uint32_t queueFamilyCount;
    VkQueue renderQueue;
    VkQueue presentQueue;
    uint32_t renderQueueFamilyIndex;
    uint32_t presentQueueFamilyIndex;
    BOOL requiresSeparatePresentQueue;
    
    VkShaderModule vertexShaderModule;
    VkShaderModule fragmentShaderModule;
    
    VkPipelineLayout pipelineLayout;
    VkPipeline pipeline;
    VkPipelineCache pipelineCache;
    
    VkCommandPool commandPool;
    VkCommandPool presentCommandPool;
    
    VkDescriptorSetLayout descriptorSetLayout;
    
    VkDescriptorPool descriptorPool;
    
    VkRenderPass renderPass;
    
    VkSurfaceKHR surface;
    uint32_t width;
    uint32_t height;
    VkFormat preferredColorFormat;
    VkColorSpaceKHR colorSpace;
    
    VkSwapchainKHR swapchain;
    VkPresentModeKHR presentMode;
    SwapchainResources *swapchainResources;
    uint32_t swapchainImageCount;
    uint32_t currentBufferIndex;
    
    DepthTexture depthBuffer;
    
    Texture textures[TEXTURE_COUNT];
    
    Texture stagingTexture;
    BOOL requireStagingBuffer;
    
    VkFence fences[MAX_PENDING_PRESENTS];
    VkSemaphore imageAcquiredSemaphores[MAX_PENDING_PRESENTS];
    VkSemaphore drawCompleteSemaphores[MAX_PENDING_PRESENTS];
    VkSemaphore imageOwnershipSemaphores[MAX_PENDING_PRESENTS];
    uint32_t frameIndex;
    
    simd_float4x4 projectionMatrix;
    simd_float4x4 viewMatrix;
    simd_float4x4 modelMatrix;
    float rotationAngle;
    float rotationDelta;

    PFN_vkGetPhysicalDeviceSurfaceSupportKHR fpGetPhysicalDeviceSurfaceSupportKHR;
    PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR fpGetPhysicalDeviceSurfaceCapabilitiesKHR;
    PFN_vkGetPhysicalDeviceSurfaceFormatsKHR fpGetPhysicalDeviceSurfaceFormatsKHR;
    PFN_vkGetPhysicalDeviceSurfacePresentModesKHR fpGetPhysicalDeviceSurfacePresentModesKHR;
    PFN_vkGetDeviceProcAddr fpGetDeviceProcAddr;
    PFN_vkCreateSwapchainKHR fpCreateSwapchainKHR;
    PFN_vkDestroySwapchainKHR fpDestroySwapchainKHR;
    PFN_vkGetSwapchainImagesKHR fpGetSwapchainImagesKHR;
    PFN_vkAcquireNextImageKHR fpAcquireNextImageKHR;
    PFN_vkQueuePresentKHR fpQueuePresentKHR;
}

@property (nonatomic, readonly, copy) NSArray *textureURLs;

@end

@implementation Renderer

@synthesize textureURLs=_textureURLs;

- (instancetype)initWithMTKView:(MTKView *)mtkView {
    if ((self = [super init])) {
        _view = mtkView;
        
        _textureURLs = @[
            [[NSBundle mainBundle] URLForResource:@"uv_grid" withExtension:@"png"]
        ];
        
        presentMode = VK_PRESENT_MODE_FIFO_KHR;
        width = _view.drawableSize.width;
        height = _view.drawableSize.height;
        rotationAngle = 0;
        rotationDelta = (2 * M_PI) / 10.0;
        
        [self _ensureRequiredExtensions];
        [self _makeInstance];
        [self _makePhysicalDevice];
        [self _discoverQueueFamilies];
        [self _makeDevice];
        [self _makeSyncObjects];
        [self _makeCommandObjects];
        [self _startInitCommandBuffer];
        [self _makeTextures];
        [self _endInitCommandBuffer];

        [self _resize:_view.drawableSize];
    }
    return self;
}

- (void)_ensureRequiredExtensions {
    VkBool32 hasSurfaceExt = VK_FALSE;
    VkBool32 hasPlatformSurfaceExt = VK_FALSE;
    VkBool32 hasDebugReportExt = VK_FALSE;
    
    VkResult result = VK_SUCCESS;
    uint32_t instanceExtensionCount = 0;
    result = vkEnumerateInstanceExtensionProperties(NULL, &instanceExtensionCount, NULL);
    assert(result == VK_SUCCESS);
    
    if (instanceExtensionCount > 0) {
        VkExtensionProperties *instanceExtensions = malloc(instanceExtensionCount * sizeof(VkExtensionProperties));
        
        result = vkEnumerateInstanceExtensionProperties(NULL, &instanceExtensionCount, instanceExtensions);
        assert(result == VK_SUCCESS);

        for (int i = 0; i < instanceExtensionCount; ++i) {
            if (strcmp(instanceExtensions[i].extensionName, VK_KHR_SURFACE_EXTENSION_NAME) == 0) {
                hasSurfaceExt = YES;
                enabledExtensionNames[enabledExtensionCount++] = VK_KHR_SURFACE_EXTENSION_NAME;
            } else if (strcmp(instanceExtensions[i].extensionName, VK_MVK_MACOS_SURFACE_EXTENSION_NAME) == 0) {
                hasPlatformSurfaceExt = YES;
                enabledExtensionNames[enabledExtensionCount++] = VK_MVK_MACOS_SURFACE_EXTENSION_NAME;
            } else if (strcmp(instanceExtensions[i].extensionName, VK_EXT_DEBUG_REPORT_EXTENSION_NAME) == 0) {
                hasDebugReportExt = YES;
                enabledExtensionNames[enabledExtensionCount++] = VK_EXT_DEBUG_REPORT_EXTENSION_NAME;
            }
        }

        free(instanceExtensions);
    }
    
    NSAssert(hasSurfaceExt && hasPlatformSurfaceExt,
             @"vkEnumerateInstanceExtensionProperties failed to find required extensions; do you have the MoltenVK installable client driver installed and configured?");
}

- (void)_makeInstance {
    VkResult result= VK_SUCCESS;

    const VkApplicationInfo appInfo = {
        .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO,
        .pNext = NULL,
        .pApplicationName = APP_NAME,
        .applicationVersion = 0,
        .pEngineName = APP_NAME,
        .engineVersion = 0,
        .apiVersion = VK_API_VERSION_1_0,
    };
    
    VkInstanceCreateInfo instanceInfo = {
        .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
        .pNext = NULL,
        .pApplicationInfo = &appInfo,
        .enabledLayerCount = enabledLayerCount,
        .ppEnabledLayerNames = (const char *const *)enabledLayerNames,
        .enabledExtensionCount = enabledExtensionCount,
        .ppEnabledExtensionNames = (const char *const *)enabledExtensionNames,
    };

    result = vkCreateInstance(&instanceInfo, NULL, &instance);
    
    NSAssert(result != VK_ERROR_INCOMPATIBLE_DRIVER, @"vkCreateInstance failed: incompatible driver; do you have the MoltenVK installable client driver installed and configured?");

    NSAssert(result != VK_ERROR_EXTENSION_NOT_PRESENT, @"vkCreateInstance failed: extension not present; Make sure your layers path is set appropriately.");

    NSAssert(result == VK_SUCCESS, @"vkCreateInstance failed: unknown result; do you have the MoltenVK installable client driver installed and configured?");
    
    GET_INSTANCE_PROC_ADDR(instance, GetPhysicalDeviceSurfaceSupportKHR);
    GET_INSTANCE_PROC_ADDR(instance, GetPhysicalDeviceSurfaceCapabilitiesKHR);
    GET_INSTANCE_PROC_ADDR(instance, GetPhysicalDeviceSurfaceFormatsKHR);
    GET_INSTANCE_PROC_ADDR(instance, GetPhysicalDeviceSurfacePresentModesKHR);
    GET_INSTANCE_PROC_ADDR(instance, GetSwapchainImagesKHR);
}

- (void)_makePhysicalDevice {
    VkResult result= VK_SUCCESS;
    uint32_t deviceCount = 0;

    result = vkEnumeratePhysicalDevices(instance, &deviceCount, NULL);
    assert(result == VK_SUCCESS);
    
    if (deviceCount > 0) {
        VkPhysicalDevice *physDevices = malloc(deviceCount * sizeof(VkPhysicalDevice));
        result = vkEnumeratePhysicalDevices(instance, &deviceCount, physDevices);
        assert(result == VK_SUCCESS);
        physDevice = physDevices[0]; // Just take the first device; this wraps MTLCreateSystemDefaultDevice
        free(physDevices);
    } else {
        NSAssert(deviceCount > 0, @"vkEnumeratePhysicalDevices failed: no physical devices; do you have the MoltenVK installable client driver installed and configured?");
    }
    
    VkBool32 hasSwapchainExt = VK_FALSE;
    uint32_t deviceExtensionCount = 0;
    
    result = vkEnumerateDeviceExtensionProperties(physDevice, NULL, &deviceExtensionCount, NULL);
    assert(result == VK_SUCCESS);
    
    enabledExtensionCount = 0;
    
    if (deviceExtensionCount > 0) {
        VkExtensionProperties *deviceExtensions = malloc(deviceExtensionCount * sizeof(VkExtensionProperties));
        result = vkEnumerateDeviceExtensionProperties(physDevice, NULL, &deviceExtensionCount, deviceExtensions);
        assert(result == VK_SUCCESS);
        
        for (int i = 0; i < deviceExtensionCount; ++i) {
            if (strcmp(deviceExtensions[i].extensionName, VK_KHR_SWAPCHAIN_EXTENSION_NAME) == 0) {
                hasSwapchainExt = YES;
                enabledExtensionNames[enabledExtensionCount++] = VK_KHR_SWAPCHAIN_EXTENSION_NAME;
            }
        }

        free(deviceExtensions);
    }
    
    NSAssert(hasSwapchainExt,
             @"vkEnumerateDeviceExtensionProperties failed to find the swapchain extension; do you have the MoltenVK installable client driver installed and configured?");
    
    vkGetPhysicalDeviceProperties(physDevice, &physDeviceProperties);
    
    vkGetPhysicalDeviceQueueFamilyProperties(physDevice, &queueFamilyCount, NULL);
    assert(queueFamilyCount > 0);
    
    queueFamilyProperties = malloc(queueFamilyCount * sizeof(VkQueueFamilyProperties));
    vkGetPhysicalDeviceQueueFamilyProperties(physDevice, &queueFamilyCount, queueFamilyProperties);

    vkGetPhysicalDeviceMemoryProperties(physDevice, &physDeviceMemProperties);
}

- (void)_makeDevice {
    VkResult result= VK_SUCCESS;

    float queuePriorities[] = { 0.0f };
    VkDeviceQueueCreateInfo queueInfo[2];
    
    VkDeviceCreateInfo deviceInfo = {
        .sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
        .pNext = NULL,
        .queueCreateInfoCount = 1,
        .pQueueCreateInfos = queueInfo,
        .enabledLayerCount = 0,
        .ppEnabledLayerNames = NULL,
        .enabledExtensionCount = enabledExtensionCount,
        .ppEnabledExtensionNames = (const char *const *)enabledExtensionNames,
        .pEnabledFeatures = NULL
    };

    queueInfo[0].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queueInfo[0].pNext = NULL;
    queueInfo[0].queueFamilyIndex = renderQueueFamilyIndex;
    queueInfo[0].queueCount = 1;
    queueInfo[0].pQueuePriorities = queuePriorities;
    queueInfo[0].flags = 0;
    
    if (requiresSeparatePresentQueue) {
        deviceInfo.queueCreateInfoCount = 2;

        queueInfo[1].sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
        queueInfo[1].pNext = NULL;
        queueInfo[1].queueFamilyIndex = presentQueueFamilyIndex;
        queueInfo[1].queueCount = 1;
        queueInfo[1].pQueuePriorities = queuePriorities;
        queueInfo[1].flags = 0;
    }

    result = vkCreateDevice(physDevice, &deviceInfo, NULL, &device);
    assert(result == VK_SUCCESS);
    
    GET_DEVICE_PROC_ADDR(device, CreateSwapchainKHR);
    GET_DEVICE_PROC_ADDR(device, DestroySwapchainKHR);
    GET_DEVICE_PROC_ADDR(device, GetSwapchainImagesKHR);
    GET_DEVICE_PROC_ADDR(device, AcquireNextImageKHR);
    GET_DEVICE_PROC_ADDR(device, QueuePresentKHR);

    vkGetDeviceQueue(device, renderQueueFamilyIndex, 0, &renderQueue);
    
    if (!requiresSeparatePresentQueue) {
        presentQueue = renderQueue;
    } else {
        vkGetDeviceQueue(device, presentQueueFamilyIndex, 0, &presentQueue);
    }

    uint32_t formatCount = 0;
    fpGetPhysicalDeviceSurfaceFormatsKHR(physDevice, surface, &formatCount, NULL);
    assert(result == VK_SUCCESS);
    
    VkSurfaceFormatKHR *formats = malloc(formatCount * sizeof(VkSurfaceFormatKHR));
    result = fpGetPhysicalDeviceSurfaceFormatsKHR(physDevice, surface, &formatCount, formats);
    assert(result == VK_SUCCESS);
    
    if (formatCount == 1 && formats[0].format == VK_FORMAT_UNDEFINED) {
        preferredColorFormat = VK_FORMAT_B8G8R8A8_UNORM;
    } else {
        preferredColorFormat = formats[0].format;
    }
    
    colorSpace = formats[0].colorSpace;
}

- (void)_makeSyncObjects {
    VkResult result = VK_SUCCESS;
    
    VkSemaphoreCreateInfo semaphoreInfo = {
        .sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
        .pNext = NULL,
        .flags = 0
    };
    
    VkFenceCreateInfo fenceInfo = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = NULL,
        .flags = VK_FENCE_CREATE_SIGNALED_BIT
    };
    
    for (int i = 0; i < MAX_PENDING_PRESENTS; ++i) {
        result = vkCreateFence(device, &fenceInfo, NULL, &fences[i]);
        assert(result == VK_SUCCESS);
        result = vkCreateSemaphore(device, &semaphoreInfo, NULL, &imageAcquiredSemaphores[i]);
        assert(result == VK_SUCCESS);
        result = vkCreateSemaphore(device, &semaphoreInfo, NULL, &drawCompleteSemaphores[i]);
        assert(result == VK_SUCCESS);
        result = vkCreateSemaphore(device, &semaphoreInfo, NULL, &imageOwnershipSemaphores[i]);
        assert(result == VK_SUCCESS);
    }
}

- (void)_discoverQueueFamilies {
    VkResult result = VK_SUCCESS;
    
    VkMacOSSurfaceCreateInfoMVK surfaceInfo;
    surfaceInfo.sType = VK_STRUCTURE_TYPE_MACOS_SURFACE_CREATE_INFO_MVK;
    surfaceInfo.pNext = NULL;
    surfaceInfo.flags = 0;
    surfaceInfo.pView = (__bridge void *)_view;
    
    result = vkCreateMacOSSurfaceMVK(instance, &surfaceInfo, NULL, &surface);
    assert(result == VK_SUCCESS);
    
    VkBool32 *supportsPresent = malloc(queueFamilyCount * sizeof(VkBool32));
    for (int i = 0; i < queueFamilyCount; ++i) {
        fpGetPhysicalDeviceSurfaceSupportKHR(physDevice, i, surface, &supportsPresent[i]);
    }
    
    int32_t renderQueueFamilyIndex = -1;
    int32_t presentQueueFamilyIndex = -1;
    for (int i = 0; i < queueFamilyCount; ++i) {
        if ((queueFamilyProperties[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) != 0) {
            if (renderQueueFamilyIndex < 0) {
                renderQueueFamilyIndex = i;
            }
            if (supportsPresent[i]) {
                renderQueueFamilyIndex = i;
                presentQueueFamilyIndex = i;
                break;
            }
        }
    }
    
    if (presentQueueFamilyIndex < 0) {
        requiresSeparatePresentQueue = VK_TRUE;
        for (int i = 0; i < queueFamilyCount; ++i) {
            if (supportsPresent[i]) {
                presentQueueFamilyIndex = i;
                break;
            }
        }
    }

    free(supportsPresent);
}

- (void)_makeCommandObjects {
    VkResult result = VK_SUCCESS;
    
    const VkCommandPoolCreateInfo commandPoolInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
        .pNext = NULL,
        .queueFamilyIndex = renderQueueFamilyIndex,
        .flags = 0
    };
    result = vkCreateCommandPool(device, &commandPoolInfo, NULL, &commandPool);
    assert(result == VK_SUCCESS);
    
    const VkCommandBufferAllocateInfo commandBufferAllocInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = NULL,
        .commandPool = commandPool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1
    };
    result = vkAllocateCommandBuffers(device, &commandBufferAllocInfo, &initCommandBuffer);
    assert(result == VK_SUCCESS);
}

- (void)_startInitCommandBuffer {
    VkResult result = VK_SUCCESS;

    VkCommandBufferBeginInfo commandBufferBeginInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = NULL,
        .flags = 0,
        .pInheritanceInfo = NULL,
    };
    result = vkBeginCommandBuffer(initCommandBuffer, &commandBufferBeginInfo);
    assert(result == VK_SUCCESS);
}

- (void)_endInitCommandBuffer {
    if (initCommandBuffer == VK_NULL_HANDLE) {
        return;
    }
    
    VkResult result = VK_SUCCESS;
    
    result = vkEndCommandBuffer(initCommandBuffer);
    assert(result == VK_SUCCESS);
    
    VkFence completionFence;
    VkFenceCreateInfo fenceInfo = {
        .sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
        .pNext = NULL,
        .flags = 0
    };
    result = vkCreateFence(device, &fenceInfo, NULL, &completionFence);
    assert(result == VK_SUCCESS);
    
    const VkCommandBuffer commandBuffers[] = { initCommandBuffer };
    VkSubmitInfo submitInfo = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = NULL,
        .waitSemaphoreCount = 0,
        .pWaitSemaphores = NULL,
        .pWaitDstStageMask = NULL,
        .commandBufferCount = 1,
        .pCommandBuffers = commandBuffers,
        .signalSemaphoreCount = 0,
        .pSignalSemaphores = NULL
    };
    
    result = vkQueueSubmit(renderQueue, 1, &submitInfo, completionFence);
    assert(result == VK_SUCCESS);

    result = vkWaitForFences(device, 1, &completionFence, VK_TRUE, UINT64_MAX);
    assert(result == VK_SUCCESS);
    
    vkFreeCommandBuffers(device, commandPool, 1, commandBuffers);
    vkDestroyFence(device, completionFence, NULL);
    
    initCommandBuffer = VK_NULL_HANDLE;
    
    if (stagingTexture.image != VK_NULL_HANDLE) {
        [self _destroyTextureImage:&stagingTexture];
    }
}

- (void)_executeImageOwnershipCommandBufferAtIndex:(int)index {
    VkResult result = VK_SUCCESS;

    const VkCommandBufferBeginInfo commandBufferBeginInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
        .pNext = NULL,
        .flags = VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT,
        .pInheritanceInfo = NULL
    };
    
    result = vkBeginCommandBuffer(swapchainResources[index].presentCommandBuffer, &commandBufferBeginInfo);
    
    VkImageMemoryBarrier imageOwnershipBarrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = NULL,
        .srcAccessMask = 0,
        .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
        .oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        .srcQueueFamilyIndex = renderQueueFamilyIndex,
        .dstQueueFamilyIndex = presentQueueFamilyIndex,
        .image = swapchainResources[index].image,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1
        }
    };
    
    vkCmdPipelineBarrier(swapchainResources[index].presentCommandBuffer, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                         VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT, 0, 0, NULL, 0, NULL, 1, &imageOwnershipBarrier);
    
    result = vkEndCommandBuffer(swapchainResources[index].presentCommandBuffer);
    assert(result == VK_SUCCESS);
}

- (void)_makeSwapchain {
    VkResult result = VK_SUCCESS;

    VkSwapchainKHR previousSwapchain = swapchain;
    
    VkSurfaceCapabilitiesKHR capabilities;
    result = fpGetPhysicalDeviceSurfaceCapabilitiesKHR(physDevice, surface, &capabilities);
    assert(result == VK_SUCCESS);
    
    VkExtent2D swapchainExtent;
    swapchainExtent.width = width;
    swapchainExtent.height = height;
    
    // TODO: Honor min/max extents of surface capabilities
    
    VkPresentModeKHR swapchainPresentMode = presentMode;
    
    swapchainImageCount = PREFERRED_SWAP_IMAGE_COUNT;
    if (swapchainImageCount < capabilities.minImageCount) {
        swapchainImageCount = capabilities.minImageCount;
    }
    if (capabilities.maxImageCount > 0) {
        if (swapchainImageCount > capabilities.maxImageCount) {
            swapchainImageCount = capabilities.maxImageCount;
        }
    }
    
    VkSurfaceTransformFlagsKHR transformFlags;
    if ((capabilities.supportedTransforms & VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR) != 0) {
        transformFlags = VK_SURFACE_TRANSFORM_IDENTITY_BIT_KHR;
    } else {
        transformFlags = capabilities.currentTransform;
    }
    
    VkCompositeAlphaFlagBitsKHR compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    VkCompositeAlphaFlagBitsKHR compositeAlphaBits[4] = {
        VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
        VK_COMPOSITE_ALPHA_PRE_MULTIPLIED_BIT_KHR,
        VK_COMPOSITE_ALPHA_POST_MULTIPLIED_BIT_KHR,
        VK_COMPOSITE_ALPHA_INHERIT_BIT_KHR,
    };
    
    for (int i = 0; i < sizeof(compositeAlphaBits); ++i) {
        if ((capabilities.supportedCompositeAlpha & compositeAlphaBits[i]) != 0) {
            compositeAlpha = compositeAlphaBits[i];
            break;
        }
    }
    
    VkSwapchainCreateInfoKHR swapchainCreateInfo = {
        .sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
        .pNext = NULL,
        .surface = surface,
        .minImageCount = swapchainImageCount,
        .imageFormat = preferredColorFormat,
        .imageColorSpace = colorSpace,
        .imageExtent = {
            width,
            height,
        },
        .imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
        .preTransform = transformFlags,
        .compositeAlpha = compositeAlpha,
        .imageArrayLayers = 1,
        .imageSharingMode = VK_SHARING_MODE_EXCLUSIVE,
        .queueFamilyIndexCount = 0,
        .pQueueFamilyIndices = NULL,
        .presentMode = swapchainPresentMode,
        .oldSwapchain = previousSwapchain,
        .clipped = true,
    };
    
    result = fpCreateSwapchainKHR(device, &swapchainCreateInfo, NULL, &swapchain);
    assert(result == VK_SUCCESS);
    
    if (previousSwapchain != VK_NULL_HANDLE) {
        fpDestroySwapchainKHR(device, previousSwapchain, NULL);
    }
    
    result = fpGetSwapchainImagesKHR(device, swapchain, &swapchainImageCount, NULL);
    assert(result == VK_SUCCESS);
    
    VkImage *swapchainImages = malloc(swapchainImageCount * sizeof(VkImage));
    result = fpGetSwapchainImagesKHR(device, swapchain, &swapchainImageCount, swapchainImages);
    assert(result == VK_SUCCESS);
    
    const VkCommandBufferAllocateInfo commandBufferAllocInfo = {
        .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
        .pNext = NULL,
        .commandPool = commandPool,
        .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
        .commandBufferCount = 1
    };

    swapchainResources = malloc(swapchainImageCount * sizeof(SwapchainResources));
    for (int i = 0; i < swapchainImageCount; ++i) {
        VkImageViewCreateInfo imageViewCreateInfo = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = NULL,
            .format = preferredColorFormat,
            .components = {
                VK_COMPONENT_SWIZZLE_R,
                VK_COMPONENT_SWIZZLE_G,
                VK_COMPONENT_SWIZZLE_B,
                VK_COMPONENT_SWIZZLE_A
            },
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1
            },
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .flags = 0
        };
        
        swapchainResources[i].image = swapchainImages[i];
        imageViewCreateInfo.image = swapchainResources[i].image;
        
        result = vkCreateImageView(device, &imageViewCreateInfo, NULL, &swapchainResources[i].imageView);
        assert(result == VK_SUCCESS);

        result = vkAllocateCommandBuffers(device, &commandBufferAllocInfo, &swapchainResources[i].commandBuffer);
        assert(result == VK_SUCCESS);
    }
    
    if (requiresSeparatePresentQueue) {
        const VkCommandPoolCreateInfo presentCommandPoolCreateInfo = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = NULL,
            .queueFamilyIndex = presentQueueFamilyIndex,
            .flags = 0
        };
        
        result = vkCreateCommandPool(device, &presentCommandPoolCreateInfo, NULL, &presentCommandPool);
        assert(result == VK_SUCCESS);
        
        const VkCommandBufferAllocateInfo presentCommandBufferAllocateInfo = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = NULL,
            .commandPool = presentCommandPool,
            .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = 1
        };
        
        for (int i = 0; i < swapchainImageCount; ++i) {
            result = vkAllocateCommandBuffers(device, &presentCommandBufferAllocateInfo, &swapchainResources[i].presentCommandBuffer);
            assert(result == VK_SUCCESS);
            
            [self _executeImageOwnershipCommandBufferAtIndex:i];
        }
    }
}

- (void)_makeDepthBuffer {
    VkResult result = VK_SUCCESS;
    const VkFormat depthFormat = VK_FORMAT_D16_UNORM;
    
    const VkImageCreateInfo imageCreateInfo = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = NULL,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = depthFormat,
        .extent = {
            width,
            height,
            1
        },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = VK_IMAGE_TILING_OPTIMAL,
        .usage = VK_IMAGE_USAGE_DEPTH_STENCIL_ATTACHMENT_BIT,
        .flags = 0
    };
    
    VkImageViewCreateInfo imageViewCreateInfo = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
        .pNext = NULL,
        .image = VK_NULL_HANDLE,
        .format = depthFormat,
        .subresourceRange = {
            .aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1
        },
        .flags = 0,
        .viewType = VK_IMAGE_VIEW_TYPE_2D
    };

    depthBuffer.format = depthFormat;
    
    result = vkCreateImage(device, &imageCreateInfo, NULL, &depthBuffer.image);
    assert(result == VK_SUCCESS);
    
    VkMemoryRequirements memoryRequirements;
    vkGetImageMemoryRequirements(device, depthBuffer.image, &memoryRequirements);
    
    depthBuffer.allocationInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    depthBuffer.allocationInfo.pNext = NULL;
    depthBuffer.allocationInfo.allocationSize = memoryRequirements.size;
    depthBuffer.allocationInfo.memoryTypeIndex = 0;
    
    BOOL success = [self _memoryTypeIndexFromProperties:&physDeviceMemProperties
                                               typeBits:memoryRequirements.memoryTypeBits
                                       requirementsMask:VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
                                           outTypeIndex:&depthBuffer.allocationInfo.memoryTypeIndex];
    assert(success);
    
    result = vkAllocateMemory(device, &depthBuffer.allocationInfo, NULL, &depthBuffer.memory);
    assert(result == VK_SUCCESS);
    
    result = vkBindImageMemory(device, depthBuffer.image, depthBuffer.memory, 0);
    assert(result == VK_SUCCESS);

    imageViewCreateInfo.image = depthBuffer.image;
    result = vkCreateImageView(device, &imageViewCreateInfo, NULL, &depthBuffer.imageView);
    assert(result == VK_SUCCESS);
}

- (BOOL)_makeTextureWithWidth:(uint32_t)width
                       height:(uint32_t)height
                  bytesPerRow:(uint32_t)bytesPerRow
                         data:(NSData * _Nullable)data
                       tiling:(VkImageTiling)tiling
                        usage:(VkImageUsageFlags)usageFlags
           requiredProperties:(VkFlags)requiredProperties
                      texture:(Texture *)texture
{
    const VkFormat textureFormat = VK_FORMAT_R8G8B8A8_UNORM;
    
    VkResult result = VK_SUCCESS;

    texture->width = width;
    texture->height = height;
    
    const VkImageCreateInfo imageCreateInfo = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
        .pNext = NULL,
        .imageType = VK_IMAGE_TYPE_2D,
        .format = textureFormat,
        .extent = {
            width,
            height,
            1
        },
        .mipLevels = 1,
        .arrayLayers = 1,
        .samples = VK_SAMPLE_COUNT_1_BIT,
        .tiling = tiling,
        .usage = usageFlags,
        .flags = 0,
        .initialLayout = VK_IMAGE_LAYOUT_PREINITIALIZED
    };
    
    result = vkCreateImage(device, &imageCreateInfo, NULL, &texture->image);
    assert(result == VK_SUCCESS);
    
    VkMemoryRequirements memoryRequirements = { 0 };
    vkGetImageMemoryRequirements(device, texture->image, &memoryRequirements);
    
    texture->allocationInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    texture->allocationInfo.pNext = NULL;
    texture->allocationInfo.allocationSize = memoryRequirements.size;
    texture->allocationInfo.memoryTypeIndex = 0;
    
    BOOL success = [self _memoryTypeIndexFromProperties:&physDeviceMemProperties
                                               typeBits:memoryRequirements.memoryTypeBits
                                       requirementsMask:requiredProperties
                                           outTypeIndex:&texture->allocationInfo.memoryTypeIndex];
    assert(success);
    
    result = vkAllocateMemory(device, &texture->allocationInfo, NULL, &texture->memory);
    assert(result == VK_SUCCESS);
    
    result = vkBindImageMemory(device, texture->image, texture->memory, 0);
    assert(result == VK_SUCCESS);
    
    if ((requiredProperties & VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT) != 0) {
        const VkImageSubresource subresource = {
            .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
            .mipLevel = 0,
            .arrayLayer = 0
        };
        
        VkSubresourceLayout layout;
        vkGetImageSubresourceLayout(device, texture->image, &subresource, &layout);
        
        if (data != nil) {
            void *textureMemory = NULL;
            result = vkMapMemory(device, texture->memory, 0, texture->allocationInfo.allocationSize, 0, &textureMemory);
            assert(result == VK_SUCCESS);
            
            // TODO: Account for image layout pitch instead of just forcing it
            assert(layout.rowPitch == bytesPerRow || bytesPerRow == 0);
            
            memcpy(textureMemory, data.bytes, data.length);
            
            vkUnmapMemory(device, texture->memory);
        }
    }

    texture->imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    
    return YES;
}

- (BOOL)_makeTextureWithContentsOfURL:(NSURL *)url
                               tiling:(VkImageTiling)tiling
                                usage:(VkImageUsageFlags)usageFlags
                   requiredProperties:(VkFlags)requiredProperties
                              texture:(Texture *)texture
{
    CGImageSourceRef imageSource = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    CGImageRef image = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
    CGDataProviderRef dataProvider = CGImageGetDataProvider(image);
    
    uint32_t width = (uint32_t)CGImageGetWidth(image);
    uint32_t height = (uint32_t)CGImageGetHeight(image);
    uint32_t bytesPerRow = (uint32_t)CGImageGetBytesPerRow(image);
    NSData *imageData = (__bridge NSData *)CGDataProviderCopyData(dataProvider);
    
    CFRelease(image);
    CFRelease(imageSource);

    BOOL success = [self _makeTextureWithWidth:width height:height bytesPerRow:bytesPerRow
                                          data:imageData tiling:tiling usage:usageFlags
                            requiredProperties:requiredProperties texture:texture];
    
    CFRelease((__bridge CFDataRef)imageData);
    
    return success;
}

- (BOOL)_memoryTypeIndexFromProperties:(VkPhysicalDeviceMemoryProperties *)memoryProperties
                              typeBits:(uint32_t)typeBits
                      requirementsMask:(VkFlags)requirementsMask
                          outTypeIndex:(uint32_t *)typeIndex
{
    for (int i = 0; i < VK_MAX_MEMORY_TYPES; ++i) {
        if ((typeBits & 1) != 0) {
            if ((memoryProperties->memoryTypes[i].propertyFlags & requirementsMask) != 0) {
                *typeIndex = i;
                return YES;
            }
        }
        typeBits >>= 1;
    }
    return NO;
}

- (void)_setImageLayout:(VkImageLayout)layout
               forImage:(VkImage)image
         previousLayout:(VkImageLayout)previousLayout
            aspectFlags:(VkImageAspectFlags)aspectFlags
            accessFlags:(VkAccessFlagBits)accessFlags
       sourceStageFlags:(VkPipelineStageFlags)sourceStageFlags
         destStageFlags:(VkPipelineStageFlags)destStageFlags
          commandBuffer:(VkCommandBuffer)commandBuffer
{
    VkImageMemoryBarrier imageMemoryBarrier = {
        .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
        .pNext = NULL,
        .srcAccessMask = accessFlags,
        .dstAccessMask = 0,
        .oldLayout = previousLayout,
        .newLayout = layout,
        .image = image,
        .subresourceRange = {
            .aspectMask = aspectFlags,
            .baseMipLevel = 0,
            .levelCount = 1,
            .baseArrayLayer = 0,
            .layerCount = 1
        }
    };
    
    switch (layout) {
        case VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL:
            imageMemoryBarrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
            break;
        case VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL:
            imageMemoryBarrier.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;
            break;
        case VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL:
            imageMemoryBarrier.dstAccessMask = VK_ACCESS_DEPTH_STENCIL_ATTACHMENT_WRITE_BIT;
            break;
        case VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL:
            imageMemoryBarrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT | VK_ACCESS_INPUT_ATTACHMENT_READ_BIT;
            break;
        case VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL:
            imageMemoryBarrier.dstAccessMask = VK_ACCESS_TRANSFER_READ_BIT;
            break;
        case VK_IMAGE_LAYOUT_PRESENT_SRC_KHR:
            imageMemoryBarrier.dstAccessMask = VK_ACCESS_MEMORY_READ_BIT;
            break;
        default:
            imageMemoryBarrier.dstAccessMask = 0;
            break;
    }

    vkCmdPipelineBarrier(commandBuffer, sourceStageFlags, destStageFlags, 0, 0, NULL, 0, NULL, 1, &imageMemoryBarrier);
}


- (void)_makeTextures {
    VkResult result = VK_SUCCESS;

    const VkFormat textureFormat = VK_FORMAT_R8G8B8A8_UNORM;
    
    VkFormatProperties formatProperties;
    vkGetPhysicalDeviceFormatProperties(physDevice, textureFormat, &formatProperties);
    
    for (int i = 0; i< TEXTURE_COUNT; ++i) {
        if (((formatProperties.linearTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) != 0) && !requireStagingBuffer) {
            [self _makeTextureWithContentsOfURL:_textureURLs[i]
                                         tiling:VK_IMAGE_TILING_LINEAR
                                          usage:VK_IMAGE_USAGE_SAMPLED_BIT
                             requiredProperties:VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
                                        texture:&textures[i]];

            [self _setImageLayout:VK_IMAGE_LAYOUT_PREINITIALIZED
                         forImage:textures[i].image
                   previousLayout:textures[i].imageLayout
                      aspectFlags:VK_IMAGE_ASPECT_COLOR_BIT
                      accessFlags:VK_ACCESS_HOST_WRITE_BIT
                 sourceStageFlags:VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
                   destStageFlags:VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
                    commandBuffer:initCommandBuffer];
            
            stagingTexture.image = VK_NULL_HANDLE;
        } else if (formatProperties.optimalTilingFeatures & VK_FORMAT_FEATURE_SAMPLED_IMAGE_BIT) {
            [self _makeTextureWithContentsOfURL:_textureURLs[i]
                                         tiling:VK_IMAGE_TILING_OPTIMAL
                                          usage:VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT
                             requiredProperties:VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT
                                        texture:&textures[i]];
            
            
            [self _setImageLayout:VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
                         forImage:textures[i].image
                   previousLayout:VK_IMAGE_LAYOUT_PREINITIALIZED
                      aspectFlags:VK_IMAGE_ASPECT_COLOR_BIT
                      accessFlags:VK_ACCESS_HOST_WRITE_BIT
                 sourceStageFlags:VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
                   destStageFlags:VK_PIPELINE_STAGE_TRANSFER_BIT
                    commandBuffer:initCommandBuffer];
            
            [self _makeTextureWithWidth:textures[i].width
                                 height:textures[i].height
                            bytesPerRow:0
                                   data:nil
                                 tiling:VK_IMAGE_TILING_LINEAR
                                  usage:VK_IMAGE_USAGE_TRANSFER_SRC_BIT
                     requiredProperties:VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
                                texture:&stagingTexture];
            
            [self _setImageLayout:VK_IMAGE_LAYOUT_PREINITIALIZED
                         forImage:stagingTexture.image
                   previousLayout:VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL
                      aspectFlags:VK_IMAGE_ASPECT_COLOR_BIT
                      accessFlags:VK_ACCESS_HOST_WRITE_BIT
                 sourceStageFlags:VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT
                   destStageFlags:VK_PIPELINE_STAGE_TRANSFER_BIT
                    commandBuffer:initCommandBuffer];

            VkImageCopy imageCopy = {
                .srcSubresource = {
                    .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = 0,
                    .layerCount = 1
                },
                .srcOffset = { 0, 0, 0 },
                .dstSubresource = {
                    .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                    .mipLevel = 0,
                    .baseArrayLayer = 0,
                    .layerCount = 1
                },
                .dstOffset = { 0, 0, 0 },
                .extent = { stagingTexture.width, stagingTexture.height, 1 }
            };
            
            vkCmdCopyImage(initCommandBuffer, stagingTexture.image, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,
                           textures[i].image, VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &imageCopy);
            
            [self _setImageLayout:VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL
                         forImage:textures[i].image
                   previousLayout:textures[i].imageLayout
                      aspectFlags:VK_IMAGE_ASPECT_COLOR_BIT
                      accessFlags:VK_ACCESS_TRANSFER_WRITE_BIT
                 sourceStageFlags:VK_PIPELINE_STAGE_TRANSFER_BIT
                   destStageFlags:VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT
                    commandBuffer:initCommandBuffer];

            // TODO: What happens to the previous staging texture here? Aren't we leaking it?
        } else {
            NSAssert(NO, @"No support for R8G8B8A8_UNORM as texture image format");
        }
        
        const VkSamplerCreateInfo samplerCreateInfo = {
            .sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO,
            .pNext = NULL,
            .magFilter = VK_FILTER_NEAREST,
            .minFilter = VK_FILTER_NEAREST,
            .mipmapMode = VK_SAMPLER_MIPMAP_MODE_NEAREST,
            .addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE,
            .mipLodBias = 0.0,
            .anisotropyEnable = VK_FALSE,
            .maxAnisotropy = 1,
            .compareOp = VK_COMPARE_OP_NEVER,
            .minLod = 0.0,
            .maxLod = 0.0,
            .borderColor = VK_BORDER_COLOR_FLOAT_OPAQUE_WHITE,
            .unnormalizedCoordinates = VK_FALSE
        };
        
        result = vkCreateSampler(device, &samplerCreateInfo, NULL, &textures[i].sampler);
        assert(result == VK_SUCCESS);
        
        VkImageViewCreateInfo viewCreateInfo = {
            .sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
            .pNext = NULL,
            .image = textures[i].image,
            .viewType = VK_IMAGE_VIEW_TYPE_2D,
            .format = textureFormat,
            .components = {
                VK_COMPONENT_SWIZZLE_R,
                VK_COMPONENT_SWIZZLE_G,
                VK_COMPONENT_SWIZZLE_B,
                VK_COMPONENT_SWIZZLE_A,
            },
            .subresourceRange = {
                .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                .baseMipLevel = 0,
                .levelCount = 1,
                .baseArrayLayer = 0,
                .layerCount = 1
            },
            .flags = 0
        };

        result = vkCreateImageView(device, &viewCreateInfo, NULL, &textures[i].imageView);
        assert(result == VK_SUCCESS);
    }
}

- (void)_destroyTextureImage:(Texture *)texture {
    vkFreeMemory(device, texture->memory, NULL);
    vkDestroyImage(device, texture->image, NULL);
}

- (void)_makeVertexBuffers {
    VkResult result = VK_SUCCESS;
    
    VkBufferCreateInfo bufferCreateInfo = { 0 };
    VkMemoryRequirements memoryRequirements;
    VkMemoryAllocateInfo allocInfo = { 0 };
    
    bufferCreateInfo.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    bufferCreateInfo.usage = VK_BUFFER_USAGE_UNIFORM_BUFFER_BIT;
    bufferCreateInfo.size = sizeof(Uniforms);
    
    Uniforms uniforms;
    for (int i = 0; i < 12 * 3; ++i) {
        uniforms.positions[i * 4 + 0] = CubePositions[i * 3 + 0];
        uniforms.positions[i * 4 + 1] = CubePositions[i * 3 + 1];
        uniforms.positions[i * 4 + 2] = CubePositions[i * 3 + 2];
        uniforms.positions[i * 4 + 3] = 1;
        uniforms.normals[i * 4 + 0] = CubeNormals[i * 3 + 0];
        uniforms.normals[i * 4 + 1] = CubeNormals[i * 3 + 1];
        uniforms.normals[i * 4 + 2] = CubeNormals[i * 3 + 2];
        uniforms.normals[i * 4 + 3] = 0;
        uniforms.texCoords[i * 4 + 0] = CubeTexCoords[i * 2 + 0];
        uniforms.texCoords[i * 4 + 1] = CubeTexCoords[i * 2 + 1];
        uniforms.texCoords[i * 4 + 2] = 0;
        uniforms.texCoords[i * 4 + 3] = 0;
    };

    for (int i = 0; i < swapchainImageCount; ++i) {
        result = vkCreateBuffer(device, &bufferCreateInfo, NULL, &swapchainResources[i].uniformBuffer);
        assert(result == VK_SUCCESS);
        
        vkGetBufferMemoryRequirements(device, swapchainResources[i].uniformBuffer, &memoryRequirements);
        
        allocInfo.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
        allocInfo.allocationSize = memoryRequirements.size;
        allocInfo.memoryTypeIndex = 0;
        
        BOOL success = [self _memoryTypeIndexFromProperties:&physDeviceMemProperties
                                                   typeBits:memoryRequirements.memoryTypeBits
                                           requirementsMask:VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT
                                               outTypeIndex:&allocInfo.memoryTypeIndex];
        assert(success);
        
        result = vkAllocateMemory(device, &allocInfo, NULL, &swapchainResources[i].uniformMemory);
        assert(result == VK_SUCCESS);
        
        void *bufferData = NULL;
        result = vkMapMemory(device, swapchainResources[i].uniformMemory, 0, VK_WHOLE_SIZE, 0, &bufferData);
        assert(result == VK_SUCCESS);

        memcpy(bufferData, &uniforms, sizeof(uniforms));
        
        vkUnmapMemory(device, swapchainResources[i].uniformMemory);
        
        result = vkBindBufferMemory(device, swapchainResources[i].uniformBuffer, swapchainResources[i].uniformMemory, 0);
        assert(result == VK_SUCCESS);
    }
}

- (void)_makeDescriptorSetLayout {
    VkResult result = VK_SUCCESS;
    VkDescriptorSetLayoutBinding layoutBindings[2];

    layoutBindings[0].binding = 0;
    layoutBindings[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    layoutBindings[0].descriptorCount = 1;
    layoutBindings[0].stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    layoutBindings[0].pImmutableSamplers = NULL;

    layoutBindings[1].binding = 1;
    layoutBindings[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    layoutBindings[1].descriptorCount = TEXTURE_COUNT;
    layoutBindings[1].stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;
    layoutBindings[1].pImmutableSamplers = NULL;
    
    const VkDescriptorSetLayoutCreateInfo descriptorSetLayoutCreateInfo = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO,
        .pNext = NULL,
        .bindingCount = 2,
        .pBindings = layoutBindings
    };
    
    result = vkCreateDescriptorSetLayout(device, &descriptorSetLayoutCreateInfo, NULL, &descriptorSetLayout);
    assert(result == VK_SUCCESS);
}

- (void)_makeRenderPass {
    VkResult result = VK_SUCCESS;
    VkAttachmentDescription attachmentDescriptions[2];

    attachmentDescriptions[0].format = preferredColorFormat;
    attachmentDescriptions[0].flags = 0;
    attachmentDescriptions[0].samples = VK_SAMPLE_COUNT_1_BIT;
    attachmentDescriptions[0].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachmentDescriptions[0].storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    attachmentDescriptions[0].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachmentDescriptions[0].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachmentDescriptions[0].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    attachmentDescriptions[0].finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    attachmentDescriptions[1].format = depthBuffer.format;
    attachmentDescriptions[1].flags = 0;
    attachmentDescriptions[1].samples = VK_SAMPLE_COUNT_1_BIT;
    attachmentDescriptions[1].loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    attachmentDescriptions[1].storeOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachmentDescriptions[1].stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    attachmentDescriptions[1].stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    attachmentDescriptions[1].initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    attachmentDescriptions[1].finalLayout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL;
    
    const VkAttachmentReference colorReference = {
        .attachment = 0,
        .layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL
    };
    
    const VkAttachmentReference depthReference = {
        .attachment = 1,
        .layout = VK_IMAGE_LAYOUT_DEPTH_STENCIL_ATTACHMENT_OPTIMAL
    };
    
    const VkSubpassDescription subpassDescription = {
        .pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS,
        .flags = 0,
        .inputAttachmentCount = 0,
        .pInputAttachments = NULL,
        .colorAttachmentCount = 1,
        .pColorAttachments = &colorReference,
        .pResolveAttachments = NULL,
        .pDepthStencilAttachment = &depthReference,
        .preserveAttachmentCount = 0,
        .pPreserveAttachments = NULL,
    };
    
    const VkRenderPassCreateInfo renderPassCreateInfo = {
        .sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
        .pNext = NULL,
        .flags = 0,
        .attachmentCount = 2,
        .pAttachments = attachmentDescriptions,
        .subpassCount = 1,
        .pSubpasses = &subpassDescription,
        .dependencyCount = 0,
        .pDependencies = NULL,
    };
    
    result = vkCreateRenderPass(device, &renderPassCreateInfo, NULL, &renderPass);
    assert(result == VK_SUCCESS);
}

- (VkShaderModule)_makeShaderModuleWithData:(NSData *)data {
    VkResult result = VK_SUCCESS;
    VkShaderModule module = VK_NULL_HANDLE;
    VkShaderModuleCreateInfo moduleCreateInfo = {
        .sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO,
        .pNext = NULL,
        .codeSize = (uint32_t)data.length,
        .pCode = data.bytes,
        .flags = 0
    };
    
    result = vkCreateShaderModule(device, &moduleCreateInfo, NULL, &module);
    assert(result == VK_SUCCESS);

    return module;
}

- (VkShaderModule)_makeVertexShaderModule {
    NSURL *shaderURL = [[NSBundle mainBundle] URLForResource:@"cube-vert" withExtension:@"spv"];
    NSData *shaderData = [NSData dataWithContentsOfURL:shaderURL];
    vertexShaderModule = [self _makeShaderModuleWithData:shaderData];
    return vertexShaderModule;
}

- (VkShaderModule)_makeFragmentShaderModule {
    NSURL *shaderURL = [[NSBundle mainBundle] URLForResource:@"cube-frag" withExtension:@"spv"];
    NSData *shaderData = [NSData dataWithContentsOfURL:shaderURL];
    fragmentShaderModule = [self _makeShaderModuleWithData:shaderData];
    return fragmentShaderModule;
}

- (void)_makePipeline {
    VkResult result = VK_SUCCESS;

    const VkPipelineLayoutCreateInfo pipelineLayoutCreateInfo = {
        .sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
        .pNext = NULL,
        .setLayoutCount = 1,
        .pSetLayouts = &descriptorSetLayout,
    };
    
    result = vkCreatePipelineLayout(device, &pipelineLayoutCreateInfo, NULL, &pipelineLayout);
    assert(result == VK_SUCCESS);
    
    VkDynamicState dynamicStates[VK_DYNAMIC_STATE_RANGE_SIZE];
    memset(dynamicStates, 0, sizeof(VkDynamicState) * VK_DYNAMIC_STATE_RANGE_SIZE);
    
    VkPipelineDynamicStateCreateInfo dynamicStateCreateInfo = { 0 };
    dynamicStateCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamicStateCreateInfo.pDynamicStates = dynamicStates;
    
    VkGraphicsPipelineCreateInfo pipelineCreateInfo = { 0 };
    pipelineCreateInfo.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipelineCreateInfo.layout = pipelineLayout;
    
    VkPipelineVertexInputStateCreateInfo vertexInputStateCreateInfo = { 0 };
    vertexInputStateCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    
    VkPipelineInputAssemblyStateCreateInfo inputAssemblyStateCreateInfo = { 0 };
    inputAssemblyStateCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    inputAssemblyStateCreateInfo.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;
    
    VkPipelineRasterizationStateCreateInfo rasterizationStateCreateInfo = { 0 };
    rasterizationStateCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizationStateCreateInfo.polygonMode = VK_POLYGON_MODE_FILL;
    rasterizationStateCreateInfo.cullMode = VK_CULL_MODE_BACK_BIT;
    rasterizationStateCreateInfo.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;
    rasterizationStateCreateInfo.depthClampEnable = VK_FALSE;
    rasterizationStateCreateInfo.rasterizerDiscardEnable = VK_FALSE;
    rasterizationStateCreateInfo.depthBiasEnable = VK_FALSE;
    rasterizationStateCreateInfo.lineWidth = 1.0;
    
    VkPipelineColorBlendStateCreateInfo colorBlendStateCreateInfo = { 0 };
    colorBlendStateCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    VkPipelineColorBlendAttachmentState colorBlendAttachmentState = { 0 };
    colorBlendAttachmentState.colorWriteMask = 0x0F;
    colorBlendAttachmentState.blendEnable = VK_FALSE;
    colorBlendStateCreateInfo.attachmentCount = 1;
    colorBlendStateCreateInfo.pAttachments = &colorBlendAttachmentState;
    
    VkPipelineViewportStateCreateInfo viewportStateCreateInfo = { 0 };
    viewportStateCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewportStateCreateInfo.viewportCount = 1;
    viewportStateCreateInfo.scissorCount = 1;
    
    dynamicStates[dynamicStateCreateInfo.dynamicStateCount++] = VK_DYNAMIC_STATE_VIEWPORT;
    dynamicStates[dynamicStateCreateInfo.dynamicStateCount++] = VK_DYNAMIC_STATE_SCISSOR;

    VkPipelineDepthStencilStateCreateInfo depthStencilStateCreateInfo = { 0 };
    depthStencilStateCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_DEPTH_STENCIL_STATE_CREATE_INFO;
    depthStencilStateCreateInfo.depthTestEnable = VK_TRUE;
    depthStencilStateCreateInfo.depthWriteEnable = VK_TRUE;
    depthStencilStateCreateInfo.depthCompareOp = VK_COMPARE_OP_LESS_OR_EQUAL;
    depthStencilStateCreateInfo.depthBoundsTestEnable = VK_FALSE;
    depthStencilStateCreateInfo.back.failOp = VK_STENCIL_OP_KEEP;
    depthStencilStateCreateInfo.back.passOp = VK_STENCIL_OP_KEEP;
    depthStencilStateCreateInfo.back.compareOp = VK_COMPARE_OP_ALWAYS;
    depthStencilStateCreateInfo.front.failOp = VK_STENCIL_OP_KEEP;
    depthStencilStateCreateInfo.front.passOp = VK_STENCIL_OP_KEEP;
    depthStencilStateCreateInfo.front.compareOp = VK_COMPARE_OP_ALWAYS;
    depthStencilStateCreateInfo.stencilTestEnable = VK_FALSE;
    
    VkPipelineMultisampleStateCreateInfo multisampleStateCreateInfo = { 0 };
    multisampleStateCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampleStateCreateInfo.pSampleMask = NULL;
    multisampleStateCreateInfo.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;
    
    pipelineCreateInfo.stageCount = 2;
    
    VkPipelineShaderStageCreateInfo shaderStageCreateInfo[2];
    memset(shaderStageCreateInfo, 0, sizeof(VkPipelineShaderStageCreateInfo) * 2);
    
    shaderStageCreateInfo[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStageCreateInfo[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    shaderStageCreateInfo[0].module = [self _makeVertexShaderModule];
    shaderStageCreateInfo[0].pName = "main";
    
    shaderStageCreateInfo[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    shaderStageCreateInfo[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    shaderStageCreateInfo[1].module = [self _makeFragmentShaderModule];
    shaderStageCreateInfo[1].pName = "main";
    
    VkPipelineCacheCreateInfo pipelineCacheCreateInfo = { 0 };
    pipelineCacheCreateInfo.sType = VK_STRUCTURE_TYPE_PIPELINE_CACHE_CREATE_INFO;
    
    result = vkCreatePipelineCache(device, &pipelineCacheCreateInfo, NULL, &pipelineCache);
    assert(result == VK_SUCCESS);
    
    pipelineCreateInfo.pVertexInputState = &vertexInputStateCreateInfo;
    pipelineCreateInfo.pInputAssemblyState = &inputAssemblyStateCreateInfo;
    pipelineCreateInfo.pRasterizationState = &rasterizationStateCreateInfo;
    pipelineCreateInfo.pColorBlendState = &colorBlendStateCreateInfo;
    pipelineCreateInfo.pMultisampleState = &multisampleStateCreateInfo;
    pipelineCreateInfo.pViewportState = &viewportStateCreateInfo;
    pipelineCreateInfo.pDepthStencilState = &depthStencilStateCreateInfo;
    pipelineCreateInfo.pDynamicState = &dynamicStateCreateInfo;
    pipelineCreateInfo.pStages = shaderStageCreateInfo;
    pipelineCreateInfo.renderPass = renderPass;
    
    result = vkCreateGraphicsPipelines(device, pipelineCache, 1, &pipelineCreateInfo, NULL, &pipeline);
    assert(result == VK_SUCCESS);

    // TODO: Store these in auto variables, since we never reference them outside the scope of this method
    vkDestroyShaderModule(device, vertexShaderModule, NULL);
    vkDestroyShaderModule(device, fragmentShaderModule, NULL);
}

- (void)_makeDescriptorPool {
    VkResult result = VK_SUCCESS;
    VkDescriptorPoolSize poolSizes[2];
    
    poolSizes[0].type = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    poolSizes[0].descriptorCount = swapchainImageCount;

    poolSizes[1].type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    poolSizes[1].descriptorCount = swapchainImageCount * TEXTURE_COUNT;
    
    const VkDescriptorPoolCreateInfo descriptorPoolCreateInfo = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO,
        .pNext = NULL,
        .maxSets = swapchainImageCount,
        .poolSizeCount = 2,
        .pPoolSizes = poolSizes
    };
    
    result = vkCreateDescriptorPool(device, &descriptorPoolCreateInfo, NULL, &descriptorPool);
    assert(result == VK_SUCCESS);
}

- (void)_makeDescriptorSet {
    VkResult result = VK_SUCCESS;

    VkDescriptorImageInfo descriptorImageInfo[TEXTURE_COUNT];
    
    for (int i = 0; i < TEXTURE_COUNT; ++i) {
        descriptorImageInfo[i].sampler = textures[i].sampler;
        descriptorImageInfo[i].imageView = textures[i].imageView;
        descriptorImageInfo[i].imageLayout = VK_IMAGE_LAYOUT_GENERAL;
    }

    VkWriteDescriptorSet writeDescriptorSets[2];
    memset(writeDescriptorSets, 0, sizeof(VkWriteDescriptorSet) * 2);
    
    VkDescriptorBufferInfo descriptorBufferInfo = { 0 };
    writeDescriptorSets[0].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writeDescriptorSets[0].descriptorCount = 1;
    writeDescriptorSets[0].descriptorType = VK_DESCRIPTOR_TYPE_UNIFORM_BUFFER;
    writeDescriptorSets[0].pBufferInfo = &descriptorBufferInfo;
    
    writeDescriptorSets[1].sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    writeDescriptorSets[1].dstBinding = 1;
    writeDescriptorSets[1].descriptorCount = TEXTURE_COUNT;
    writeDescriptorSets[1].descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    writeDescriptorSets[1].pImageInfo = descriptorImageInfo;
    
    VkDescriptorSetAllocateInfo descriptorSetAllocateInfo = {
        .sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO,
        .pNext = NULL,
        .descriptorPool = descriptorPool,
        .descriptorSetCount = 1,
        .pSetLayouts = &descriptorSetLayout
    };
    
    for (int i = 0; i < swapchainImageCount; ++i) {
        result = vkAllocateDescriptorSets(device, &descriptorSetAllocateInfo, &swapchainResources[i].descriptorSet);
        assert(result == VK_SUCCESS);
        descriptorBufferInfo.buffer = swapchainResources[i].uniformBuffer;
        writeDescriptorSets[0].dstSet = swapchainResources[i].descriptorSet;
        writeDescriptorSets[1].dstSet = swapchainResources[i].descriptorSet;
        vkUpdateDescriptorSets(device, 2, writeDescriptorSets, 0, NULL);
    }
}

- (void)_makeFramebuffers {
    VkResult result = VK_SUCCESS;
    VkImageView attachments[2];
    
    const VkFramebufferCreateInfo framebufferCreateInfo = {
        .sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
        .pNext = NULL,
        .renderPass = renderPass,
        .attachmentCount = 2,
        .pAttachments = attachments,
        .width = width,
        .height = height,
        .layers = 1
    };
    
    for (int i = 0; i < swapchainImageCount; ++i) {
        attachments[0] = swapchainResources[i].imageView;
        attachments[1] = depthBuffer.imageView;
        result = vkCreateFramebuffer(device, &framebufferCreateInfo, NULL, &swapchainResources[i].framebuffer);
        assert(result == VK_SUCCESS);
    }
}

- (void)_makeCommandBuffers {
    VkResult result = VK_SUCCESS;
    
    for (int i = 0; i < swapchainImageCount; ++i) {
        const VkCommandBufferBeginInfo commandBufferBeginInfo = {
            .sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = NULL,
            .flags = VK_COMMAND_BUFFER_USAGE_SIMULTANEOUS_USE_BIT,
            .pInheritanceInfo = NULL,
        };
        
        VkClearValue clearValues[2] = {
            [0] = {
                .color = {
                    .float32 = { 0.2, 0.2, 0.2, 0.2 }
                }
            },
            [1] = {
                .depthStencil = { 1, 0 }
            }
        };
        
        const VkRenderPassBeginInfo renderPassBeginInfo = {
            .sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = NULL,
            .renderPass = renderPass,
            .framebuffer = swapchainResources[i].framebuffer,
            .renderArea = {
                .offset = {
                    .x = 0,
                    .y = 0,
                },
                .extent = {
                    .width = width,
                    .height = height
                }
            },
            .clearValueCount = 2,
            .pClearValues = clearValues
        };

        result = vkBeginCommandBuffer(swapchainResources[i].commandBuffer, &commandBufferBeginInfo);
        assert (result == VK_SUCCESS);

        vkCmdBeginRenderPass(swapchainResources[i].commandBuffer, &renderPassBeginInfo, VK_SUBPASS_CONTENTS_INLINE);

        vkCmdBindPipeline(swapchainResources[i].commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS, pipeline);
        vkCmdBindDescriptorSets(swapchainResources[i].commandBuffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
                                pipelineLayout, 0, 1, &swapchainResources[i].descriptorSet, 0, NULL);
        
        VkViewport viewport = {
            .x = 0,
            .y = 0,
            .width = width,
            .height = height,
            .minDepth = 0,
            .maxDepth = 1
        };
        
        vkCmdSetViewport(swapchainResources[i].commandBuffer, 0, 1, &viewport);
        
        VkRect2D scissor = {
            .offset = {
                .x = 0,
                .y = 0
            },
            .extent = {
                .width = width,
                .height = height
            }
        };
        
        vkCmdSetScissor(swapchainResources[i].commandBuffer, 0, 1, &scissor);
        
        vkCmdDraw(swapchainResources[i].commandBuffer, 12 * 3, 1, 0, 0);
        
        vkCmdEndRenderPass(swapchainResources[i].commandBuffer);
        
        if (requiresSeparatePresentQueue) {
            VkImageMemoryBarrier imageOwnershipBarrier = {
                .sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,
                .pNext = NULL,
                .srcAccessMask = 0,
                .dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
                .oldLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                .newLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
                .srcQueueFamilyIndex = renderQueueFamilyIndex,
                .dstQueueFamilyIndex = presentQueueFamilyIndex,
                .image = swapchainResources[i].image,
                .subresourceRange = {
                    .aspectMask = VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1
                }
            };
            
            vkCmdPipelineBarrier(swapchainResources[i].commandBuffer, VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
                                 VK_PIPELINE_STAGE_BOTTOM_OF_PIPE_BIT, 0, 0, NULL, 0, NULL, 1, &imageOwnershipBarrier);
        }
        
        result = vkEndCommandBuffer(swapchainResources[i].commandBuffer);
        assert (result == VK_SUCCESS);
    }
}

- (void)_destroyFramebuffers {
    for (int i = 0; i < swapchainImageCount; ++i) {
        vkDestroyFramebuffer(device, swapchainResources[i].framebuffer, NULL);
    }

    vkDestroyImageView(device, depthBuffer.imageView, NULL);
    vkDestroyImage(device, depthBuffer.image, NULL);
    vkFreeMemory(device, depthBuffer.memory, NULL);
}

- (void)_destroySwapchains {
    for (int i = 0; i < swapchainImageCount; ++i) {
        vkDestroyImageView(device, swapchainResources[i].imageView, NULL);
        vkFreeCommandBuffers(device, commandPool, 1, &swapchainResources[i].commandBuffer);
        vkDestroyBuffer(device, swapchainResources[i].uniformBuffer, NULL);
        vkFreeMemory(device, swapchainResources[i].uniformMemory, NULL);
    }
    
    free(swapchainResources);
}

- (void)_destroyDescriptorObjects {
    vkDestroyDescriptorPool(device, descriptorPool, NULL);
    vkDestroyDescriptorSetLayout(device, descriptorSetLayout, NULL);
}

- (void)_destroyPipelines {
    vkDestroyPipeline(device, pipeline, NULL);
    vkDestroyPipelineCache(device, pipelineCache, NULL);
    vkDestroyPipelineLayout(device, pipelineLayout, NULL);
}

- (void)_destroyRenderPass {
    vkDestroyRenderPass(device, renderPass, NULL);
}

- (void)_destroyCommandPool {
    vkDestroyCommandPool(device, commandPool, NULL);
}

- (void)_resize:(CGSize)size {
    vkDeviceWaitIdle(device);
    
    width = size.width;
    height = size.height;

    [self _destroyFramebuffers];
    [self _destroySwapchains];
    [self _destroyDescriptorObjects];
    [self _destroyPipelines];
    [self _destroyRenderPass];
    [self _destroyCommandPool];
    
    [self _makeCommandObjects];
    [self _startInitCommandBuffer];
    [self _makeSwapchain];
    [self _makeDepthBuffer];
    [self _makeVertexBuffers];
    [self _makeDescriptorSetLayout];
    [self _makeRenderPass];
    [self _makePipeline];
    [self _makeDescriptorPool];
    [self _makeDescriptorSet];
    [self _makeFramebuffers];
    [self _makeCommandBuffers];
    [self _endInitCommandBuffer];
}

- (void)_updateWithTimestep:(NSTimeInterval)timestep {
    VkResult result = VK_SUCCESS;
    
    float fov = M_PI / 3;
    CGSize size = self.view.drawableSize;
    float aspect = size.width / size.height;
    float near = 0.1;
    float far = 100.0;
    projectionMatrix = matrix_perspective_projection(fov, aspect, near, far);

    simd_float3 at = (simd_float3){ 0, 0, 0 };
    simd_float3 from = (simd_float3){ 3, 3, 3 };
    simd_float3 up = (simd_float3){ 0, 1, 0 };
    viewMatrix = matrix_lookat(at, from, up);

    simd_float3 axis = (simd_float3){ 0, 1, 0 };
    modelMatrix = matrix_rotation_axis_angle(axis, rotationAngle);
    
    Uniforms uniforms;
    uniforms.modelViewProjectionMatrix = simd_mul(simd_mul(projectionMatrix, viewMatrix), modelMatrix);
    uniforms.normalMatrix = modelMatrix;
    
    void *dataPtr = NULL;
    result = vkMapMemory(device, swapchainResources[currentBufferIndex].uniformMemory, 0, VK_WHOLE_SIZE, 0, &dataPtr);
    assert(result == VK_SUCCESS);
    
    memcpy(dataPtr, &uniforms, sizeof(simd_float4x4) * 2);
    
    vkUnmapMemory(device, swapchainResources[currentBufferIndex].uniformMemory);
    
    rotationAngle += rotationDelta * timestep;
}

- (void)_drawFrame {
    VkResult result = VK_SUCCESS;
    
    vkWaitForFences(device, 1, &fences[frameIndex], VK_TRUE, UINT64_MAX);
    vkResetFences(device, 1, &fences[frameIndex]);
    
    do {
        result = fpAcquireNextImageKHR(device, swapchain, UINT64_MAX, imageAcquiredSemaphores[frameIndex],
                                       VK_NULL_HANDLE, &currentBufferIndex);
        
        if (result == VK_ERROR_OUT_OF_DATE_KHR) {
            [self _resize:self.view.drawableSize];
        } else if (result == VK_SUBOPTIMAL_KHR) {
            break;
        } else {
            assert(result == VK_SUCCESS);
            break;
        }
    } while (result != VK_SUCCESS);
    
    [self _updateWithTimestep:(1/60.0f)];
    
    VkPipelineStageFlags pipelineStageFlags = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submitInfo = {
        .sType = VK_STRUCTURE_TYPE_SUBMIT_INFO,
        .pNext = NULL,
        .pWaitDstStageMask = &pipelineStageFlags,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = &imageAcquiredSemaphores[frameIndex],
        .commandBufferCount = 1,
        .pCommandBuffers = &swapchainResources[currentBufferIndex].commandBuffer,
        .signalSemaphoreCount = 1,
        .pSignalSemaphores = &drawCompleteSemaphores[frameIndex]
    };
    
    result = vkQueueSubmit(renderQueue, 1, &submitInfo, fences[frameIndex]);
    assert(result == VK_SUCCESS);
    
    if (requiresSeparatePresentQueue) {
        VkFence nullFence = VK_NULL_HANDLE;
        submitInfo.pWaitDstStageMask = &pipelineStageFlags;
        submitInfo.waitSemaphoreCount = 1;
        submitInfo.pWaitSemaphores = &drawCompleteSemaphores[frameIndex];
        submitInfo.commandBufferCount = 1;
        submitInfo.pCommandBuffers = &swapchainResources[currentBufferIndex].presentCommandBuffer;
        submitInfo.signalSemaphoreCount = 1;
        submitInfo.pSignalSemaphores = &imageOwnershipSemaphores[frameIndex];
        result = vkQueueSubmit(presentQueue, 1, &submitInfo, nullFence);
        assert(result == VK_SUCCESS);
    }
    
    VkPresentInfoKHR presentInfo = {
        .sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
        .pNext = NULL,
        .waitSemaphoreCount = 1,
        .pWaitSemaphores = requiresSeparatePresentQueue ? &imageOwnershipSemaphores[frameIndex] : &drawCompleteSemaphores[frameIndex],
        .swapchainCount = 1,
        .pSwapchains = &swapchain,
        .pImageIndices = &currentBufferIndex
    };
    
    result = fpQueuePresentKHR(presentQueue, &presentInfo);
    
    frameIndex = (frameIndex + 1) % MAX_PENDING_PRESENTS;
    
    if (result == VK_ERROR_OUT_OF_DATE_KHR) {
        [self _resize:_view.drawableSize];
    } else if (result == VK_SUBOPTIMAL_KHR) {
    } else {
        assert(result == VK_SUCCESS);
    }
}

- (void)drawInMTKView:(MTKView *)view {
    [self _drawFrame];
}

- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    [self _resize:size];
}

@end
