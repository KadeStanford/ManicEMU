// Disposable headless Vulkan frontend using the official libretro interface.
// Serialized queue completion favors diagnostic correctness over performance.
#include "vendor/libretro_vulkan.h"
#include <pthread.h>
static struct retro_hw_render_callback hardware;
static struct retro_hw_render_context_negotiation_interface_vulkan negotiation;
static struct retro_hw_render_interface_vulkan vkInterface;
static struct retro_vulkan_image currentImage;
static bool imageSet,vulkanReady;
static PFN_vkGetInstanceProcAddr vkGet;
static VkSemaphore waitSemaphores[32],signalSemaphore;
static uint32_t waitCount,commandCount;
static VkCommandBuffer commands[64];
static pthread_mutex_t queueMutex;
#define VPROC(name) PFN_##name name=(void *)vkGet(vkInterface.instance,#name)
static void queueLock(void *handle){pthread_mutex_lock(&queueMutex);}
static void queueUnlock(void *handle){pthread_mutex_unlock(&queueMutex);}
static void waitSync(void *handle){queueLock(handle);VPROC(vkQueueWaitIdle);vkQueueWaitIdle(vkInterface.queue);queueUnlock(handle);}
static uint32_t syncIndex(void *handle){return 0;}
static uint32_t syncMask(void *handle){return 1;}
static void setSignal(void *handle,VkSemaphore semaphore){signalSemaphore=semaphore;}
static void setCommands(void *handle,uint32_t count,const VkCommandBuffer *buffers){
    if(count>64){logger(3,"Too many diagnostic command buffers\n");abort();}
    commandCount=count;memcpy(commands,buffers,count*sizeof(*buffers));
}
static void setImage(void *handle,const struct retro_vulkan_image *image,uint32_t count,const VkSemaphore *semaphores,uint32_t family){
    if(count>32||(family!=VK_QUEUE_FAMILY_IGNORED&&family!=vkInterface.queue_index)){logger(3,"Unsupported diagnostic queue transfer\n");abort();}
    currentImage=*image;imageSet=true;waitCount=count;memcpy(waitSemaphores,semaphores,count*sizeof(*semaphores));
}
static retro_proc_address_t getProc(const char *name){return (retro_proc_address_t)vkGet(vkInterface.instance,name);}
static uintptr_t framebuffer(void){return 0;}
static bool vkEnvironment(unsigned cmd,void *data){
    switch(cmd){
        case 14:{struct retro_hw_render_callback *h=data;if(h->context_type!=RETRO_HW_CONTEXT_VULKAN)return false;
            h->get_proc_address=getProc;h->get_current_framebuffer=framebuffer;hardware=*h;return true;}
        case 41:if(!vulkanReady)return false;*(const void **)data=&vkInterface;return true;
        case 43:{const struct retro_hw_render_context_negotiation_interface_vulkan *n=data;
            if(n->interface_type!=RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN||n->interface_version!=1)return false;
            // v1 layout ends after destroy_device; avoid reading later ABI fields.
            memcpy(&negotiation,n,offsetof(struct retro_hw_render_context_negotiation_interface_vulkan,create_instance));return true;}
        case 56:*(enum retro_hw_context_type *)data=RETRO_HW_CONTEXT_VULKAN;return true;
        case 73:{struct retro_hw_render_context_negotiation_interface *n=data;
            if(n->interface_type!=RETRO_HW_RENDER_CONTEXT_NEGOTIATION_INTERFACE_VULKAN)return false;n->interface_version=1;return true;}
        default:return false;
    }
}
static bool initializeVulkan(void){
    checkpoint(@"vulkan_driver_load");
    void *h=dlopen([[NSBundle.mainBundle pathForResource:@"moltenvk-probe" ofType:@"dylib"] fileSystemRepresentation],RTLD_NOW|RTLD_LOCAL);
    if(!h){logger(3,"Driver load failed: %s\n",dlerror());return false;}
    vkGet=(void *)dlsym(h,"vkGetInstanceProcAddr");if(!vkGet)return false;
    pthread_mutexattr_t attributes;pthread_mutexattr_init(&attributes);pthread_mutexattr_settype(&attributes,PTHREAD_MUTEX_RECURSIVE);
    pthread_mutex_init(&queueMutex,&attributes);pthread_mutexattr_destroy(&attributes);
    VkApplicationInfo fallback={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="Private Manic runtime",.apiVersion=VK_API_VERSION_1_1};
    const VkApplicationInfo *application=negotiation.get_application_info?negotiation.get_application_info():&fallback;
    const char *extensions[]={"VK_KHR_portability_enumeration","VK_KHR_get_physical_device_properties2"};
    VkInstanceCreateInfo info={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,.flags=VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR,
        .pApplicationInfo=application,.enabledExtensionCount=2,.ppEnabledExtensionNames=extensions};
    PFN_vkCreateInstance create=(void *)vkGet(NULL,"vkCreateInstance");checkpoint(@"vulkan_create_instance");
    if(create(&info,NULL,&vkInterface.instance)!=VK_SUCCESS)return false;
    VPROC(vkEnumeratePhysicalDevices);uint32_t count=0;vkEnumeratePhysicalDevices(vkInterface.instance,&count,NULL);
    if(!count)return false;VkPhysicalDevice devices[16];count=MIN(count,16U);vkEnumeratePhysicalDevices(vkInterface.instance,&count,devices);
    vkInterface.gpu=devices[0];struct retro_vulkan_context context={0};
    VkPhysicalDeviceFeatures required={0};const char *deviceExtensions[]={"VK_KHR_portability_subset"};
    checkpoint(@"vulkan_negotiate_device");
    if(negotiation.create_device){
        if(!negotiation.create_device(&context,vkInterface.instance,vkInterface.gpu,VK_NULL_HANDLE,vkGet,deviceExtensions,1,NULL,0,&required))return false;
    }else{
        VPROC(vkGetPhysicalDeviceQueueFamilyProperties);VPROC(vkGetPhysicalDeviceFeatures);VPROC(vkCreateDevice);VPROC(vkGetDeviceQueue);
        count=0;vkGetPhysicalDeviceQueueFamilyProperties(vkInterface.gpu,&count,NULL);VkQueueFamilyProperties *families=calloc(count,sizeof(*families));
        vkGetPhysicalDeviceQueueFamilyProperties(vkInterface.gpu,&count,families);uint32_t family=UINT32_MAX;
        for(uint32_t i=0;i<count;i++)if(families[i].queueFlags&VK_QUEUE_GRAPHICS_BIT){family=i;break;}free(families);if(family==UINT32_MAX)return false;
        float priority=1;VkDeviceQueueCreateInfo queue={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};
        vkGetPhysicalDeviceFeatures(vkInterface.gpu,&required);
        VkDeviceCreateInfo device={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,.queueCreateInfoCount=1,.pQueueCreateInfos=&queue,
            .enabledExtensionCount=1,.ppEnabledExtensionNames=deviceExtensions,.pEnabledFeatures=&required};
        if(vkCreateDevice(vkInterface.gpu,&device,NULL,&context.device)!=VK_SUCCESS)return false;
        context.gpu=vkInterface.gpu;context.queue_family_index=family;vkGetDeviceQueue(context.device,family,0,&context.queue);
    }
    vkInterface.interface_type=RETRO_HW_RENDER_INTERFACE_VULKAN;vkInterface.interface_version=5;vkInterface.handle=&vkInterface;
    vkInterface.gpu=context.gpu;vkInterface.device=context.device;vkInterface.queue=context.queue;vkInterface.queue_index=context.queue_family_index;
    vkInterface.get_instance_proc_addr=vkGet;vkInterface.get_device_proc_addr=(void *)vkGet(vkInterface.instance,"vkGetDeviceProcAddr");
    vkInterface.set_image=setImage;vkInterface.get_sync_index=syncIndex;vkInterface.get_sync_index_mask=syncMask;
    vkInterface.wait_sync_index=waitSync;vkInterface.lock_queue=queueLock;vkInterface.unlock_queue=queueUnlock;
    vkInterface.set_command_buffers=setCommands;vkInterface.set_signal_semaphore=setSignal;
    vulkanReady=true;report[@"real_vulkan_device_created"]=@YES;return true;
}
static void vulkanVideo(unsigned width,unsigned height){
    queueLock(NULL);VPROC(vkQueueSubmit);VPROC(vkQueueWaitIdle);
    VkPipelineStageFlags stages[32];for(unsigned i=0;i<32;i++)stages[i]=VK_PIPELINE_STAGE_ALL_COMMANDS_BIT;
    VkSubmitInfo submit={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.waitSemaphoreCount=commandCount?0:waitCount,
        .pWaitSemaphores=waitSemaphores,.pWaitDstStageMask=stages,.commandBufferCount=commandCount,.pCommandBuffers=commands};
    if(waitCount||commandCount)vkQueueSubmit(vkInterface.queue,1,&submit,VK_NULL_HANDLE);
    waitCount=commandCount=0;vkQueueWaitIdle(vkInterface.queue);
    if(imageSet){frames++;report[@"last_frame_dimensions"]=@[@(width),@(height)];}
    bool snapshot=runCalls==600||runCalls==1800||runCalls==2050||runCalls==3000;
    if(snapshot&&imageSet&&width&&height&&width<=2048&&height<=2048){
        VPROC(vkCreateBuffer);VPROC(vkGetBufferMemoryRequirements);VPROC(vkGetPhysicalDeviceMemoryProperties);VPROC(vkAllocateMemory);
        VPROC(vkBindBufferMemory);VPROC(vkCreateCommandPool);VPROC(vkAllocateCommandBuffers);VPROC(vkBeginCommandBuffer);
        VPROC(vkCmdPipelineBarrier);VPROC(vkCmdCopyImageToBuffer);VPROC(vkEndCommandBuffer);VPROC(vkMapMemory);
        VPROC(vkInvalidateMappedMemoryRanges);VPROC(vkUnmapMemory);VPROC(vkDestroyBuffer);VPROC(vkFreeMemory);VPROC(vkDestroyCommandPool);
        VkBufferCreateInfo bufferInfo={.sType=VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,.size=(VkDeviceSize)width*height*4,.usage=VK_BUFFER_USAGE_TRANSFER_DST_BIT};
        VkBuffer buffer;VkDeviceMemory memory;VkCommandPool pool;VkCommandBuffer cmd;
        if(vkCreateBuffer(vkInterface.device,&bufferInfo,NULL,&buffer)!=VK_SUCCESS)abort();
        VkMemoryRequirements requirements;vkGetBufferMemoryRequirements(vkInterface.device,buffer,&requirements);
        VkPhysicalDeviceMemoryProperties properties;vkGetPhysicalDeviceMemoryProperties(vkInterface.gpu,&properties);uint32_t type=UINT32_MAX;
        for(uint32_t i=0;i<properties.memoryTypeCount;i++)if((requirements.memoryTypeBits&(1U<<i))&&(properties.memoryTypes[i].propertyFlags&VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT)){type=i;break;}
        if(type==UINT32_MAX)abort();VkMemoryAllocateInfo allocation={.sType=VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,.allocationSize=requirements.size,.memoryTypeIndex=type};
        if(vkAllocateMemory(vkInterface.device,&allocation,NULL,&memory)!=VK_SUCCESS)abort();vkBindBufferMemory(vkInterface.device,buffer,memory,0);
        VkCommandPoolCreateInfo poolInfo={.sType=VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,.queueFamilyIndex=vkInterface.queue_index};
        vkCreateCommandPool(vkInterface.device,&poolInfo,NULL,&pool);VkCommandBufferAllocateInfo commandInfo={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,.commandPool=pool,.level=VK_COMMAND_BUFFER_LEVEL_PRIMARY,.commandBufferCount=1};
        vkAllocateCommandBuffers(vkInterface.device,&commandInfo,&cmd);VkCommandBufferBeginInfo begin={.sType=VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO};vkBeginCommandBuffer(cmd,&begin);
        VkImageMemoryBarrier barrier={.sType=VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER,.srcAccessMask=VK_ACCESS_MEMORY_WRITE_BIT,.dstAccessMask=VK_ACCESS_TRANSFER_READ_BIT,
            .oldLayout=currentImage.image_layout,.newLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,.srcQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,.dstQueueFamilyIndex=VK_QUEUE_FAMILY_IGNORED,
            .image=currentImage.create_info.image,.subresourceRange={VK_IMAGE_ASPECT_COLOR_BIT,0,1,0,1}};
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,VK_PIPELINE_STAGE_TRANSFER_BIT,0,0,NULL,0,NULL,1,&barrier);
        VkBufferImageCopy copy={.imageSubresource={VK_IMAGE_ASPECT_COLOR_BIT,0,0,1},.imageExtent={width,height,1}};
        vkCmdCopyImageToBuffer(cmd,currentImage.create_info.image,VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL,buffer,1,&copy);
        barrier.oldLayout=VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;barrier.newLayout=currentImage.image_layout;barrier.srcAccessMask=VK_ACCESS_TRANSFER_READ_BIT;barrier.dstAccessMask=VK_ACCESS_MEMORY_READ_BIT|VK_ACCESS_MEMORY_WRITE_BIT;
        vkCmdPipelineBarrier(cmd,VK_PIPELINE_STAGE_TRANSFER_BIT,VK_PIPELINE_STAGE_ALL_COMMANDS_BIT,0,0,NULL,0,NULL,1,&barrier);vkEndCommandBuffer(cmd);
        VkSubmitInfo transfer={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.commandBufferCount=1,.pCommandBuffers=&cmd};vkQueueSubmit(vkInterface.queue,1,&transfer,VK_NULL_HANDLE);vkQueueWaitIdle(vkInterface.queue);
        void *pixels;vkMapMemory(vkInterface.device,memory,0,VK_WHOLE_SIZE,0,&pixels);
        VkMappedMemoryRange range={.sType=VK_STRUCTURE_TYPE_MAPPED_MEMORY_RANGE,.memory=memory,.size=VK_WHOLE_SIZE};vkInvalidateMappedMemoryRanges(vkInterface.device,1,&range);
        for(size_t i=0;i<(size_t)width*height;i++)if(((uint32_t *)pixels)[i]&0xffffff){nonblackFrames++;break;}
        CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();bool bgra=currentImage.create_info.format==VK_FORMAT_B8G8R8A8_UNORM||currentImage.create_info.format==VK_FORMAT_B8G8R8A8_SRGB;
        CGBitmapInfo flags=bgra?(kCGBitmapByteOrder32Little|kCGImageAlphaNoneSkipFirst):(kCGBitmapByteOrder32Big|kCGImageAlphaNoneSkipLast);
        CGContextRef bitmap=CGBitmapContextCreate(pixels,width,height,8,width*4,space,flags);
        if(bitmap){CGImageRef image=CGBitmapContextCreateImage(bitmap);[UIImagePNGRepresentation([UIImage imageWithCGImage:image]) writeToFile:[root stringByAppendingPathComponent:[NSString stringWithFormat:@"private-frame-%d.png",runCalls]] atomically:YES];CGImageRelease(image);CGContextRelease(bitmap);}CGColorSpaceRelease(space);
        vkUnmapMemory(vkInterface.device,memory);vkDestroyBuffer(vkInterface.device,buffer,NULL);vkFreeMemory(vkInterface.device,memory,NULL);vkDestroyCommandPool(vkInterface.device,pool,NULL);
    }
    if(signalSemaphore){VkSubmitInfo signal={.sType=VK_STRUCTURE_TYPE_SUBMIT_INFO,.signalSemaphoreCount=1,.pSignalSemaphores=&signalSemaphore};vkQueueSubmit(vkInterface.queue,1,&signal,VK_NULL_HANDLE);signalSemaphore=VK_NULL_HANDLE;}
    vkQueueWaitIdle(vkInterface.queue);queueUnlock(NULL);
}
