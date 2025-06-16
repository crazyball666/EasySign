//
//  MachOSignture.h
//  EasySign
//
//  Created by crazyball on 2025/6/16.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface MachOSignatureResult : NSObject
@property(nonatomic, copy) NSString* arch;
@property(nonatomic, copy) NSString* entitlements;
@end


@interface MachOSignature : NSObject

+ (NSArray<MachOSignatureResult *> *)loadSignature: (NSURL *)filePath;


@end

NS_ASSUME_NONNULL_END
