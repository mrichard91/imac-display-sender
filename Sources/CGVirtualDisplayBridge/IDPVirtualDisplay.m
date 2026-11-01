#import "IDPVirtualDisplay.h"
#import "CGVirtualDisplayPrivate.h"

#if !__has_feature(objc_arc)
#error "CGVirtualDisplayBridge must be compiled with ARC"
#endif

NSErrorDomain const IDPVirtualDisplayErrorDomain = @"IDPVirtualDisplayErrorDomain";

static NSError *IDPError(IDPVirtualDisplayErrorCode code, NSString *message) {
    return [NSError errorWithDomain:IDPVirtualDisplayErrorDomain
                               code:code
                           userInfo:@{NSLocalizedDescriptionKey : message}];
}

@implementation IDPVirtualDisplayMode

- (instancetype)initWithWidth:(NSUInteger)width height:(NSUInteger)height refreshRate:(double)refreshRate {
    if ((self = [super init])) {
        _width = width;
        _height = height;
        _refreshRate = refreshRate;
    }
    return self;
}

@end

@implementation IDPVirtualDisplayConfiguration

- (instancetype)init {
    if ((self = [super init])) {
        _name = @"Virtual Display";
        _modes = @[];
    }
    return self;
}

@end

@implementation IDPVirtualDisplay {
    CGVirtualDisplay *_display;
}

+ (nullable NSString *)unavailabilityReason {
    struct Requirement {
        NSString *className;
        SEL selectors[3];
    };
    const struct Requirement requirements[] = {
        {@"CGVirtualDisplayDescriptor",
         {@selector(setMaxPixelsWide:), @selector(setSizeInMillimeters:), @selector(setTerminationHandler:)}},
        {@"CGVirtualDisplayMode", {@selector(initWithWidth:height:refreshRate:), NULL, NULL}},
        {@"CGVirtualDisplaySettings", {@selector(setModes:), @selector(setHiDPI:), NULL}},
        {@"CGVirtualDisplay", {@selector(initWithDescriptor:), @selector(applySettings:), @selector(displayID)}},
    };
    for (size_t i = 0; i < sizeof(requirements) / sizeof(requirements[0]); i++) {
        Class cls = NSClassFromString(requirements[i].className);
        if (cls == nil) {
            return [NSString stringWithFormat:@"%@ is not available on this version of macOS",
                                              requirements[i].className];
        }
        for (size_t s = 0; s < 3; s++) {
            SEL selector = requirements[i].selectors[s];
            if (selector != NULL && ![cls instancesRespondToSelector:selector]) {
                return [NSString stringWithFormat:@"%@ no longer responds to %@ on this version of macOS",
                                                  requirements[i].className, NSStringFromSelector(selector)];
            }
        }
    }
    return nil;
}

- (nullable instancetype)initWithConfiguration:(IDPVirtualDisplayConfiguration *)configuration
                                         queue:(dispatch_queue_t)queue
                            terminationHandler:(nullable void (^)(void))terminationHandler
                                         error:(NSError **)error {
    NSString *reason = [IDPVirtualDisplay unavailabilityReason];
    if (reason != nil) {
        if (error) *error = IDPError(IDPVirtualDisplayErrorUnavailable, reason);
        return nil;
    }
    if (!(self = [super init])) return nil;

    CGVirtualDisplayDescriptor *descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    descriptor.queue = queue;
    descriptor.name = configuration.name;
    descriptor.maxPixelsWide = configuration.maxPixelsWide;
    descriptor.maxPixelsHigh = configuration.maxPixelsHigh;
    descriptor.sizeInMillimeters = configuration.sizeInMillimeters;
    descriptor.vendorID = configuration.vendorID;
    descriptor.productID = configuration.productID;
    descriptor.serialNum = configuration.serialNumber;
    if (terminationHandler != nil) {
        void (^handler)(void) = [terminationHandler copy];
        descriptor.terminationHandler = ^(id _Nullable unused, CGVirtualDisplay *_Nullable display) {
            (void)unused;
            (void)display;
            handler();
        };
    }

    _display = [[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (_display == nil || _display.displayID == kCGNullDirectDisplay) {
        _display = nil;
        if (error) *error = IDPError(IDPVirtualDisplayErrorCreateFailed, @"CGVirtualDisplay could not be created");
        return nil;
    }

    NSMutableArray<CGVirtualDisplayMode *> *modes = [NSMutableArray array];
    Class modeClass = NSClassFromString(@"CGVirtualDisplayMode");
    for (IDPVirtualDisplayMode *mode in configuration.modes) {
        [modes addObject:[[modeClass alloc] initWithWidth:mode.width
                                                   height:mode.height
                                              refreshRate:mode.refreshRate]];
    }
    CGVirtualDisplaySettings *settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    settings.modes = modes;
    settings.hiDPI = configuration.hiDPI ? 1 : 0;
    if (![_display applySettings:settings]) {
        _display = nil;
        if (error) *error = IDPError(IDPVirtualDisplayErrorApplySettingsFailed, @"CGVirtualDisplay rejected the modes");
        return nil;
    }
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display != nil ? _display.displayID : kCGNullDirectDisplay;
}

- (void)invalidate {
    _display = nil;
}

@end
