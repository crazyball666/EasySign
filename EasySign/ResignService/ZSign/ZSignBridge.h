#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^ZSignBridgeLogHandler)(NSInteger level, NSString *message);

@interface ZSignBridgeOptions : NSObject

@property (nonatomic, copy) NSString *inputPath;
@property (nonatomic, copy) NSString *p12Path;
@property (nonatomic, copy) NSString *p12Password;
@property (nonatomic, copy) NSString *mobileProvisionPath;
@property (nonatomic, copy, nullable) NSString *entitlementsPath;
@property (nonatomic, copy) NSString *outputPath;
@property (nonatomic, copy) NSString *temporaryDirectory;
@property (nonatomic, copy) NSArray<NSString *> *injectedDylibPaths;
@property (nonatomic) BOOL weakInject;
@property (nonatomic) NSInteger zipLevel;
@property (nonatomic, copy, nullable) ZSignBridgeLogHandler logHandler;

@end

@interface ZSignBridge : NSObject

+ (BOOL)resignWithOptions:(ZSignBridgeOptions *)options error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
