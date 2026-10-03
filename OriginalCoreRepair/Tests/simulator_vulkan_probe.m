// Public Vulkan loading preflight. No game, plugin, keys or saves are used.
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <signal.h>
#import <sys/ucontext.h>
#import <fcntl.h>
#import <unistd.h>
#include <vulkan/vulkan.h>
#include "simulator_metal_arrays.h"

static NSMutableDictionary *state;
static NSString *destination;
static int faultFD=-1;
static uintptr_t moltenBase;
static void fatalSignal(int signal,siginfo_t *info,void *context) {
    ucontext_t *c=context;
    uint64_t record[]={0x4d414e4943564b31,(uint64_t)signal,(uintptr_t)info->si_addr,moltenBase,
        c->uc_mcontext->__ss.__pc,c->uc_mcontext->__ss.__lr,c->uc_mcontext->__ss.__sp};
    if(faultFD>=0){write(faultFD,record,sizeof(record));fsync(faultFD);}
    _exit(128+signal);
}
static void checkpoint(NSString *stage) {
    state[@"stage"]=stage;
    [[NSJSONSerialization dataWithJSONObject:state options:2 error:nil] writeToFile:destination atomically:YES];
}
static void uncaughtException(NSException *exception) {
    state[@"objc_exception"]=exception.name;state[@"exception_reason"]=exception.reason?:@"";
    state[@"exception_backtrace"]=exception.callStackSymbols;checkpoint(@"objc_exception");
}
@interface VulkanProbeApp : UIResponder <UIApplicationDelegate>
@property(nonatomic,strong) UIWindow *window;
@end
@implementation VulkanProbeApp
- (BOOL)application:(UIApplication *)app didFinishLaunchingWithOptions:(NSDictionary *)options {
    self.window=[[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window.rootViewController=[UIViewController new];[self.window makeKeyAndVisible];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
        destination=[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES).firstObject
            stringByAppendingPathComponent:@"vulkan-preflight.json"];
        state=[@{@"moltenvk_version":@"1.2.8",@"actual_game_executed":@NO,@"plugin_executed":@NO} mutableCopy];
        NSString *directory=destination.stringByDeletingLastPathComponent;
        faultFD=open([directory stringByAppendingPathComponent:@"vulkan-fatal.bin"].fileSystemRepresentation,O_CREAT|O_WRONLY|O_EXCL,0600);
        struct sigaction action={0};action.sa_sigaction=fatalSignal;action.sa_flags=SA_SIGINFO;
        for(int s=1;s<NSIG;s++)if(s==SIGSEGV||s==SIGBUS||s==SIGABRT||s==SIGILL||s==SIGTRAP)sigaction(s,&action,NULL);
        NSSetUncaughtExceptionHandler(uncaughtException);
        checkpoint(@"metal_array_capability_test");
        state[@"metal_array_capabilities"]=metalArrayDiagnostic();
        checkpoint(@"dlopen");
        void *library=dlopen([[NSBundle.mainBundle pathForResource:@"moltenvk-probe" ofType:@"dylib"] fileSystemRepresentation],RTLD_NOW|RTLD_LOCAL);
        if(!library){state[@"error"]=@(dlerror()?:"dlopen failed");checkpoint(@"failed");return;}
        PFN_vkGetInstanceProcAddr get=(void *)dlsym(library,"vkGetInstanceProcAddr");
        if(!get){checkpoint(@"missing_vkGetInstanceProcAddr");return;}
        Dl_info location={0};dladdr(get,&location);moltenBase=(uintptr_t)location.dli_fbase;
        PFN_vkCreateInstance create=(void *)get(VK_NULL_HANDLE,"vkCreateInstance");
        PFN_vkEnumerateInstanceExtensionProperties enumerateExtensions=(void *)get(VK_NULL_HANDLE,"vkEnumerateInstanceExtensionProperties");
        uint32_t extensionCount=0;enumerateExtensions(NULL,&extensionCount,NULL);
        VkExtensionProperties *available=calloc(extensionCount,sizeof(*available));enumerateExtensions(NULL,&extensionCount,available);
        const char *extensions[2];uint32_t enabledCount=0;bool portabilityEnumeration=false;
        NSMutableArray *names=[NSMutableArray new];
        for(uint32_t i=0;i<extensionCount;i++){
            [names addObject:@(available[i].extensionName)];
            if(!strcmp(available[i].extensionName,"VK_KHR_portability_enumeration")){extensions[enabledCount++]="VK_KHR_portability_enumeration";portabilityEnumeration=true;}
            else if(!strcmp(available[i].extensionName,"VK_KHR_get_physical_device_properties2"))extensions[enabledCount++]="VK_KHR_get_physical_device_properties2";
        }
        free(available);state[@"advertised_instance_extensions"]=names;
        VkApplicationInfo application={.sType=VK_STRUCTURE_TYPE_APPLICATION_INFO,.pApplicationName="Manic Vulkan preflight",.apiVersion=VK_API_VERSION_1_1};
        VkInstanceCreateInfo info={.sType=VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .flags=portabilityEnumeration?VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR:0,.pApplicationInfo=&application,
            .enabledExtensionCount=enabledCount,.ppEnabledExtensionNames=extensions};
        VkInstance instance=VK_NULL_HANDLE;checkpoint(@"vkCreateInstance");
        VkResult result=create(&info,NULL,&instance);state[@"instance_result"]=@(result);
        if(result!=VK_SUCCESS){checkpoint(@"failed");return;}
        PFN_vkEnumeratePhysicalDevices enumerate=(void *)get(instance,"vkEnumeratePhysicalDevices");
        uint32_t count=0;result=enumerate(instance,&count,NULL);state[@"physical_devices"]=@(count);
        if(result!=VK_SUCCESS||!count){checkpoint(@"failed");return;}
        VkPhysicalDevice *devices=calloc(count,sizeof(*devices));enumerate(instance,&count,devices);
        VkPhysicalDevice gpu=devices[0];free(devices);
        PFN_vkGetPhysicalDeviceProperties properties=(void *)get(instance,"vkGetPhysicalDeviceProperties");
        VkPhysicalDeviceProperties props;properties(gpu,&props);state[@"gpu_name"]=@(props.deviceName);state[@"api_version"]=@(props.apiVersion);
        PFN_vkGetPhysicalDeviceQueueFamilyProperties families=(void *)get(instance,"vkGetPhysicalDeviceQueueFamilyProperties");
        count=0;families(gpu,&count,NULL);VkQueueFamilyProperties *queues=calloc(count,sizeof(*queues));families(gpu,&count,queues);
        uint32_t family=UINT32_MAX;
        for(uint32_t i=0;i<count;i++)if(queues[i].queueFlags&VK_QUEUE_GRAPHICS_BIT){family=i;break;}
        free(queues);if(family==UINT32_MAX){checkpoint(@"failed");return;}
        float priority=1;VkDeviceQueueCreateInfo queueInfo={.sType=VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,.queueFamilyIndex=family,.queueCount=1,.pQueuePriorities=&priority};
        const char *deviceExtensions[]={"VK_KHR_portability_subset"};
        VkDeviceCreateInfo deviceInfo={.sType=VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .queueCreateInfoCount=1,.pQueueCreateInfos=&queueInfo,.enabledExtensionCount=1,.ppEnabledExtensionNames=deviceExtensions};
        PFN_vkCreateDevice createDevice=(void *)get(instance,"vkCreateDevice");
        VkDevice device=VK_NULL_HANDLE;checkpoint(@"vkCreateDevice");result=createDevice(gpu,&deviceInfo,NULL,&device);
        state[@"device_result"]=@(result);if(result!=VK_SUCCESS){checkpoint(@"failed");return;}
        PFN_vkDeviceWaitIdle idle=(void *)get(instance,"vkDeviceWaitIdle");
        result=idle(device);state[@"device_idle_result"]=@(result);
        PFN_vkDestroyDevice destroyDevice=(void *)get(instance,"vkDestroyDevice");destroyDevice(device,NULL);
        PFN_vkDestroyInstance destroyInstance=(void *)get(instance,"vkDestroyInstance");destroyInstance(instance,NULL);
        state[@"vulkan_device_verified"]=@(result==VK_SUCCESS);checkpoint(@"completed");
    });return YES;
}
@end
int main(int argc,char **argv){@autoreleasepool{return UIApplicationMain(argc,argv,nil,NSStringFromClass(VulkanProbeApp.class));}}
