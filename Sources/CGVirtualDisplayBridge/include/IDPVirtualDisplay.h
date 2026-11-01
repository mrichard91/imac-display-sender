// Public face of CGVirtualDisplayBridge: a small wrapper around the private
// CGVirtualDisplay* classes. No private type appears in this header, so Swift
// code never links against them directly.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const IDPVirtualDisplayErrorDomain;

typedef NS_ERROR_ENUM(IDPVirtualDisplayErrorDomain, IDPVirtualDisplayErrorCode) {
    /// The private classes or selectors are missing on this macOS version.
    IDPVirtualDisplayErrorUnavailable = 1,
    /// CGVirtualDisplay refused the descriptor (returned nil or display ID 0).
    IDPVirtualDisplayErrorCreateFailed = 2,
    /// applySettings: returned NO.
    IDPVirtualDisplayErrorApplySettingsFailed = 3,
};

/// One selectable mode, in points. With hiDPI the backing store is 2x.
@interface IDPVirtualDisplayMode : NSObject
@property (nonatomic, readonly) NSUInteger width;
@property (nonatomic, readonly) NSUInteger height;
@property (nonatomic, readonly) double refreshRate;
- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate;
- (instancetype)init NS_UNAVAILABLE;
@end

@interface IDPVirtualDisplayConfiguration : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic) uint32_t vendorID;
@property (nonatomic) uint32_t productID;
@property (nonatomic) uint32_t serialNumber;
@property (nonatomic) uint32_t maxPixelsWide;
@property (nonatomic) uint32_t maxPixelsHigh;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) BOOL hiDPI;
/// The first mode is the one macOS picks unless it remembers another.
@property (nonatomic, copy) NSArray<IDPVirtualDisplayMode *> *modes;
@end

/// A live virtual display. It disappears when this object is invalidated or
/// deallocated.
@interface IDPVirtualDisplay : NSObject

/// nil when the private API looks usable, otherwise a human-readable reason.
+ (nullable NSString *)unavailabilityReason;

/// `terminationHandler` runs on `queue` if the system tears the display down.
- (nullable instancetype)initWithConfiguration:(IDPVirtualDisplayConfiguration *)configuration
                                         queue:(dispatch_queue_t)queue
                            terminationHandler:(nullable void (^)(void))terminationHandler
                                         error:(NSError **)error;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// Drops the underlying display. Safe to call more than once.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
