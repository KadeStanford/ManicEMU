// SPDX-License-Identifier: AGPL-3.0-or-later
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
// These selectors belong to the app's already-loaded Realm framework. The
// optional boundary is checked before use; no new framework or app build.
@interface NSObject (MDSRealmNaming)
+(id)defaultConfiguration;
+(id)realmWithConfiguration:(id)configuration error:(NSError**)error;
-(void)setFileURL:(NSURL*)url;
-(void)setReadOnly:(BOOL)value;
-(void)setDynamic:(BOOL)value;
-(void)setCache:(BOOL)value;
-(void)setDisableFormatUpgrade:(BOOL)value;
-(id)objectWithClassName:(NSString*)name forPrimaryKey:(id)key;
@end
static NSString *nicknameFromExtras(NSData *extras){
    if(![extras isKindOfClass:NSData.class]||extras.length>1024*1024)return nil;
    id json=[NSJSONSerialization JSONObjectWithData:extras options:0 error:nil];
    id name=[json isKindOfClass:NSDictionary.class]?json[@"nickname"]:nil;
    return [name isKindOfClass:NSString.class]?name:nil;
}
static NSString *configuredNickname(){
    if(!NSThread.isMainThread)return nil;
    @try {
        Class configClass=NSClassFromString(@"RLMRealmConfiguration"),realmClass=NSClassFromString(@"RLMRealm");
        if(![configClass respondsToSelector:@selector(defaultConfiguration)]||![realmClass respondsToSelector:@selector(realmWithConfiguration:error:)])return nil;
        NSURL *library=[NSFileManager.defaultManager URLsForDirectory:NSLibraryDirectory inDomains:NSUserDomainMask].firstObject;
        NSURL *url=[[library URLByAppendingPathComponent:@"Realm" isDirectory:YES] URLByAppendingPathComponent:@"default.realm"];
        if(![NSFileManager.defaultManager fileExistsAtPath:url.path])return nil;
        id config=[configClass defaultConfiguration];
        for(NSString *selector in @[@"setFileURL:",@"setReadOnly:",@"setDynamic:",@"setCache:",@"setDisableFormatUpgrade:"])
            if(![config respondsToSelector:NSSelectorFromString(selector)])return nil;
        [config setFileURL:url];[config setReadOnly:YES];[config setDynamic:YES];[config setCache:NO];[config setDisableFormatUpgrade:YES];
        NSError *error=nil;id realm=[realmClass realmWithConfiguration:config error:&error];if(!realm||error)return nil;
        // Query only the existing Settings row through Realm's dynamic API;
        // never open a write transaction or migrate it.
        if(![realm respondsToSelector:@selector(objectWithClassName:forPrimaryKey:)])return nil;
        id settings=[realm objectWithClassName:@"Settings" forPrimaryKey:@"SettingsDefault"];
        return settings?nicknameFromExtras([settings valueForKey:@"extras"]):nil;
    } @catch(NSException *exception){(void)exception;return nil;}
}
static NSString *boundedPlayerName(NSString *nickname,NSString *device){
    NSString *source=nickname.length?nickname:device;
    source=[[source componentsSeparatedByCharactersInSet:NSCharacterSet.controlCharacterSet] componentsJoinedByString:@" "];
    source=[source stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if(!source.length)source=@"Manic player";
    NSMutableString *name=[NSMutableString new];
    [source enumerateSubstringsInRange:NSMakeRange(0,source.length) options:NSStringEnumerationByComposedCharacterSequences usingBlock:^(NSString *part,NSRange range,NSRange enclosing,BOOL *stop){
        (void)range;(void)enclosing;if([name lengthOfBytesUsingEncoding:NSUTF8StringEncoding]+[part lengthOfBytesUsingEncoding:NSUTF8StringEncoding]>63){*stop=YES;return;}[name appendString:part];
    }];
    return name.length?name:@"Manic player";
}
static NSString *localPlayerName(){return boundedPlayerName(configuredNickname(),UIDevice.currentDevice.name);}
