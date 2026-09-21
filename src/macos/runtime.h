/* SPDX-License-Identifier: MIT */
#import "platform.h"
@interface RheoRuntime : NSObject
- (instancetype)initWithEnabled:(BOOL)enabled;
- (BOOL)start;
- (void)stop;
- (void)setEnabled:(BOOL)enabled;
- (void)refreshEnvironment;
- (NSString *)requestSwitch:(sn_direction)direction;
- (NSDictionary *)status;
@end
