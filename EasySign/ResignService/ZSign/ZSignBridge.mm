#import "ZSignBridge.h"

#include "archive.h"
#include "bundle.h"
#include "log.h"
#include "openssl.h"
#include "ZSignMachOInjector.h"

static NSString * const ZSignBridgeErrorDomain = @"com.EasySign.zsign";

@implementation ZSignBridgeOptions

- (instancetype)init
{
    self = [super init];
    if (self) {
        _inputPath = @"";
        _p12Path = @"";
        _p12Password = @"";
        _mobileProvisionPath = @"";
        _outputPath = @"";
        _temporaryDirectory = @"";
        _injectedDylibPaths = @[];
        _weakInject = NO;
        _zipLevel = 0;
    }
    return self;
}

@end

static NSError *ZSignBridgeMakeError(NSString *message)
{
    return [NSError errorWithDomain:ZSignBridgeErrorDomain
                               code:-1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL ZSignBridgeFail(NSError **error, NSString *message)
{
    if (error) {
        *error = ZSignBridgeMakeError(message);
    }
    return NO;
}

static std::string ZSignBridgeString(NSString *value)
{
    if (!value) {
        return std::string();
    }
    return std::string(value.UTF8String ?: "");
}

static void ZSignBridgeLogCallback(int level, const char *message, void *context)
{
    if (!context || !message) {
        return;
    }

    ZSignBridgeLogHandler handler = (__bridge ZSignBridgeLogHandler)context;
    NSString *text = [NSString stringWithUTF8String:message];
    if (!text) {
        text = @"";
    }
    handler(level, text);
}

static BOOL ZSignBridgeCopyAppIntoPayload(NSString *inputPath, NSString *archiveBasePath, NSError **error)
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSString *payloadPath = [archiveBasePath stringByAppendingPathComponent:@"Payload"];
    NSString *targetPath = [payloadPath stringByAppendingPathComponent:inputPath.lastPathComponent];

    if (![fileManager createDirectoryAtPath:payloadPath withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    if (![fileManager copyItemAtPath:inputPath toPath:targetPath error:error]) {
        return NO;
    }

    return YES;
}

@implementation ZSignBridge

+ (BOOL)injectDylibs:(NSArray<NSString *> *)dylibNames
      intoExecutable:(NSString *)executablePath
          weakInject:(BOOL)weakInject
               error:(NSError **)error
{
    if (executablePath.length == 0) {
        return ZSignBridgeFail(error, @"主可执行文件路径为空");
    }
    if (![NSFileManager.defaultManager fileExistsAtPath:executablePath]) {
        return ZSignBridgeFail(error, @"主可执行文件不存在");
    }
    if (dylibNames.count == 0) {
        return YES;
    }

    std::vector<std::string> dylibs;
    for (NSString *dylibName in dylibNames) {
        if (dylibName.length == 0) {
            return ZSignBridgeFail(error, @"注入动态库名称为空");
        }
        dylibs.push_back(ZSignBridgeString(dylibName));
    }

    std::string errorMessage;
    if (!ZSignInjectDylibs(ZSignBridgeString(executablePath), dylibs, weakInject, errorMessage)) {
        return ZSignBridgeFail(error, [NSString stringWithUTF8String:errorMessage.c_str()]);
    }

    return YES;
}

+ (BOOL)resignWithOptions:(ZSignBridgeOptions *)options error:(NSError **)error
{
    if (!options) {
        return ZSignBridgeFail(error, @"zsign 参数为空");
    }

    NSFileManager *fileManager = NSFileManager.defaultManager;
    if (![fileManager fileExistsAtPath:options.inputPath]) {
        return ZSignBridgeFail(error, @"输入文件不存在");
    }
    if (![fileManager fileExistsAtPath:options.p12Path]) {
        return ZSignBridgeFail(error, @"p12 文件不存在");
    }
    if (![fileManager fileExistsAtPath:options.mobileProvisionPath]) {
        return ZSignBridgeFail(error, @"描述文件不存在");
    }
    if (options.entitlementsPath.length > 0 && ![fileManager fileExistsAtPath:options.entitlementsPath]) {
        return ZSignBridgeFail(error, @"entitlements 文件不存在");
    }
    if (options.outputPath.length == 0) {
        return ZSignBridgeFail(error, @"输出路径为空");
    }
    if (options.temporaryDirectory.length == 0) {
        return ZSignBridgeFail(error, @"临时目录为空");
    }
    for (NSString *dylibPath in options.injectedDylibPaths) {
        if (![fileManager fileExistsAtPath:dylibPath]) {
            return ZSignBridgeFail(error, [NSString stringWithFormat:@"注入动态库不存在：%@", dylibPath]);
        }
        if (![dylibPath.pathExtension.lowercaseString isEqualToString:@"dylib"]) {
            return ZSignBridgeFail(error, [NSString stringWithFormat:@"注入文件不是 dylib：%@", dylibPath]);
        }
    }

    NSString *bridgeWorkspace = [options.temporaryDirectory stringByAppendingPathComponent:@"zsign_bridge"];
    [fileManager removeItemAtPath:bridgeWorkspace error:nil];
    if (![fileManager createDirectoryAtPath:bridgeWorkspace withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    ZSignBridgeLogHandler logHandler = [options.logHandler copy];
    ZLog::SetLogLever(ZLog::E_INFO);
    ZLog::SetLogCallback(logHandler ? ZSignBridgeLogCallback : NULL, (__bridge void *)logHandler);

    BOOL result = NO;
    NSError *localError = nil;

    @try {
        NSString *inputExtension = options.inputPath.pathExtension.lowercaseString;
        NSString *signRootPath = options.inputPath;

        if ([inputExtension isEqualToString:@"ipa"] || [inputExtension isEqualToString:@"zip"]) {
            NSString *extractPath = [bridgeWorkspace stringByAppendingPathComponent:@"extract"];
            ZLog::PrintV(">>> Unzip:\t%s -> %s ... \n", options.inputPath.UTF8String, extractPath.UTF8String);
            if (!Zip::Extract(options.inputPath.UTF8String, extractPath.UTF8String)) {
                localError = ZSignBridgeMakeError(@"zsign 解压 IPA 失败");
                goto cleanup;
            }
            signRootPath = extractPath;
        } else if ([inputExtension isEqualToString:@"app"]) {
            NSString *archiveBasePath = [bridgeWorkspace stringByAppendingPathComponent:@"package"];
            if (!ZSignBridgeCopyAppIntoPayload(options.inputPath, archiveBasePath, &localError)) {
                goto cleanup;
            }
            signRootPath = [archiveBasePath stringByAppendingPathComponent:[@"Payload" stringByAppendingPathComponent:options.inputPath.lastPathComponent]];
        } else {
            localError = ZSignBridgeMakeError(@"zsign 仅支持 ipa、zip 或 app 输入");
            goto cleanup;
        }

        ZSignAsset signAsset;
        if (!signAsset.Init("",
                            ZSignBridgeString(options.p12Path),
                            ZSignBridgeString(options.mobileProvisionPath),
                            ZSignBridgeString(options.entitlementsPath ?: @""),
                            ZSignBridgeString(options.p12Password),
                            false,
                            false,
                            false)) {
            localError = ZSignBridgeMakeError(@"zsign 初始化签名资产失败，请检查 p12、密码和描述文件是否匹配");
            goto cleanup;
        }

        ZBundle bundle;
        std::vector<std::string> dylibFiles;
        for (NSString *dylibPath in options.injectedDylibPaths) {
            dylibFiles.push_back(ZSignBridgeString(dylibPath));
        }
        std::vector<std::string> removeDylibNames;
        if (!bundle.SignFolder(&signAsset,
                               ZSignBridgeString(signRootPath),
                               "",
                               "",
                               "",
                               dylibFiles,
                               removeDylibNames,
                               true,
                               options.weakInject,
                               false,
                               false)) {
            localError = ZSignBridgeMakeError(@"zsign 签名失败");
            goto cleanup;
        }

        size_t payloadPosition = bundle.m_strAppFolder.rfind("Payload");
        if (payloadPosition == std::string::npos || payloadPosition == 0) {
            localError = ZSignBridgeMakeError(@"zsign 无法定位 Payload 目录");
            goto cleanup;
        }

        NSString *outputDirectory = options.outputPath.stringByDeletingLastPathComponent;
        if (![fileManager createDirectoryAtPath:outputDirectory withIntermediateDirectories:YES attributes:nil error:&localError]) {
            goto cleanup;
        }
        if ([fileManager fileExistsAtPath:options.outputPath]) {
            if (![fileManager removeItemAtPath:options.outputPath error:&localError]) {
                goto cleanup;
            }
        }

        std::string archiveBasePath = bundle.m_strAppFolder.substr(0, payloadPosition - 1);
        int zipLevel = (int)MAX(0, MIN(options.zipLevel, 9));
        ZLog::PrintV(">>> Archiving:\t%s ... \n", options.outputPath.UTF8String);
        if (!Zip::Archive(archiveBasePath, ZSignBridgeString(options.outputPath), zipLevel)) {
            localError = ZSignBridgeMakeError(@"zsign 打包 IPA 失败");
            goto cleanup;
        }

        result = YES;
    } @catch (NSException *exception) {
        localError = ZSignBridgeMakeError(exception.reason ?: @"zsign 发生未知异常");
    }

cleanup:
    ZLog::SetLogCallback(NULL, NULL);
    if (!result && error && localError) {
        *error = localError;
    }
    return result;
}

@end
