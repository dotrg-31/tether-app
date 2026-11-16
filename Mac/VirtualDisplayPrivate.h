// Declarations for CoreGraphics' undocumented virtual display classes.
// These exist in macOS 11+ but are private API: fine for personal use,
// not acceptable for the Mac App Store.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int serialNum;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (copy, nonatomic, nullable) void (^terminationHandler)(id, CGVirtualDisplay *);
- (nullable dispatch_queue_t)dispatchQueue;
- (void)setDispatchQueue:(dispatch_queue_t)queue;
@end

@interface CGVirtualDisplayMode : NSObject
@property (readonly, nonatomic) CGFloat refreshRate;
@property (readonly, nonatomic) NSUInteger width;
@property (readonly, nonatomic) NSUInteger height;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(CGFloat)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property (readonly, nonatomic) CGDirectDisplayID displayID;
- (nullable instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

NS_ASSUME_NONNULL_END
