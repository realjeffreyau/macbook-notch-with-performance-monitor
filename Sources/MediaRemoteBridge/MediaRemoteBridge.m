#import "MediaRemoteBridge.h"

#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
#import <dlfcn.h>
#import <math.h>
#import <stdatomic.h>

typedef void (^DNGetNowPlayingInfoBlock)(CFDictionaryRef info);
typedef void (^DNGetDisplayIdentifierBlock)(CFStringRef displayIdentifier);

typedef void (*DNRegisterForNotificationsFunction)(dispatch_queue_t queue);
typedef void (*DNUnregisterForNotificationsFunction)(void);
typedef void (*DNGetNowPlayingInfoFunction)(dispatch_queue_t queue, DNGetNowPlayingInfoBlock completion);
typedef void (*DNGetDisplayIdentifierFunction)(
    dispatch_queue_t queue,
    DNGetDisplayIdentifierBlock completion
);
typedef Boolean (*DNSendCommandFunction)(int32_t command, id options);

struct DNMediaRemoteBridge {
    void *handle;
    dispatch_queue_t queue;
    CFStringRef nowPlayingInfoDidChangeNotification;
    CFStringRef playbackPositionOptionKey;

    DNRegisterForNotificationsFunction registerForNotifications;
    DNUnregisterForNotificationsFunction unregisterForNotifications;
    DNGetNowPlayingInfoFunction getNowPlayingInfo;
    DNGetDisplayIdentifierFunction getDisplayIdentifier;
    DNSendCommandFunction sendCommand;

    DNMediaRemoteInfoCallback callback;
    void *context;
    atomic_int references;
    atomic_bool active;
    atomic_bool destroyed;
};

static void *dn_symbol(void *handle, const char *name) {
    return handle == NULL ? NULL : dlsym(handle, name);
}

static CFStringRef dn_string_symbol(void *handle, const char *name) {
    void *address = dn_symbol(handle, name);
    if (address == NULL) {
        return NULL;
    }

    CFStringRef value = *(CFStringRef *)address;
    if (value == NULL || CFGetTypeID(value) != CFStringGetTypeID()) {
        return NULL;
    }
    return value;
}

static void dn_retain(DNMediaRemoteBridge *bridge) {
    atomic_fetch_add_explicit(&bridge->references, 1, memory_order_relaxed);
}

static void dn_release(DNMediaRemoteBridge *bridge) {
    if (atomic_fetch_sub_explicit(&bridge->references, 1, memory_order_acq_rel) != 1) {
        return;
    }
    if (!atomic_load_explicit(&bridge->destroyed, memory_order_acquire)) {
        return;
    }

    if (bridge->handle != NULL) {
        dlclose(bridge->handle);
    }
    free(bridge);
}

static void dn_emit(
    DNMediaRemoteBridge *bridge,
    CFDictionaryRef info,
    CFStringRef displayIdentifier,
    int32_t processIdentifier
) {
    if (!atomic_load_explicit(&bridge->active, memory_order_acquire)) {
        return;
    }

    DNMediaRemoteInfoCallback callback = bridge->callback;
    if (callback != NULL) {
        // The callback is invoked synchronously. Callers must copy values they
        // retain; the bridge releases its temporary Core Foundation copies
        // immediately after this function returns.
        callback(info, displayIdentifier, processIdentifier, bridge->context);
    }
}

static void dn_notification(
    CFNotificationCenterRef center,
    void *observer,
    CFStringRef name,
    const void *object,
    CFDictionaryRef userInfo
) {
    (void)center;
    (void)name;
    (void)object;
    (void)userInfo;

    DNMediaRemoteBridge *bridge = (DNMediaRemoteBridge *)observer;
    if (bridge != NULL && atomic_load_explicit(&bridge->active, memory_order_acquire)) {
        DNMediaRemoteBridgeRefresh(bridge);
    }
}

static void *dn_open_media_remote(void) {
    const char *paths[] = {
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",
        "/System/Library/PrivateFrameworks/MediaRemote.framework/Versions/Current/MediaRemote",
        "/System/Library/PrivateFrameworks/MediaRemote.framework/Versions/A/MediaRemote"
    };

    for (size_t index = 0; index < sizeof(paths) / sizeof(paths[0]); index += 1) {
        void *handle = dlopen(paths[index], RTLD_LAZY | RTLD_LOCAL);
        if (handle != NULL) {
            return handle;
        }
    }
    return NULL;
}

DNMediaRemoteBridge *DNMediaRemoteBridgeCreate(void) {
    void *handle = dn_open_media_remote();
    if (handle == NULL) {
        return NULL;
    }

    DNMediaRemoteBridge *bridge = calloc(1, sizeof(DNMediaRemoteBridge));
    if (bridge == NULL) {
        dlclose(handle);
        return NULL;
    }

    bridge->handle = handle;
    bridge->queue = dispatch_get_main_queue();
    bridge->registerForNotifications = (DNRegisterForNotificationsFunction)dn_symbol(
        handle,
        "MRMediaRemoteRegisterForNowPlayingNotifications"
    );
    bridge->unregisterForNotifications = (DNUnregisterForNotificationsFunction)dn_symbol(
        handle,
        "MRMediaRemoteUnregisterForNowPlayingNotifications"
    );
    bridge->getNowPlayingInfo = (DNGetNowPlayingInfoFunction)dn_symbol(
        handle,
        "MRMediaRemoteGetNowPlayingInfo"
    );
    bridge->getDisplayIdentifier = (DNGetDisplayIdentifierFunction)dn_symbol(
        handle,
        "MRMediaRemoteGetNowPlayingApplicationDisplayID"
    );
    bridge->sendCommand = (DNSendCommandFunction)dn_symbol(handle, "MRMediaRemoteSendCommand");
    bridge->nowPlayingInfoDidChangeNotification = dn_string_symbol(
        handle,
        "kMRMediaRemoteNowPlayingInfoDidChangeNotification"
    );
    bridge->playbackPositionOptionKey = dn_string_symbol(
        handle,
        "kMRMediaRemoteOptionPlaybackPosition"
    );

    bool requiredSymbolsAvailable =
        bridge->registerForNotifications != NULL &&
        bridge->unregisterForNotifications != NULL &&
        bridge->getNowPlayingInfo != NULL &&
        bridge->nowPlayingInfoDidChangeNotification != NULL;
    if (!requiredSymbolsAvailable) {
        dlclose(handle);
        free(bridge);
        return NULL;
    }

    atomic_init(&bridge->references, 1);
    atomic_init(&bridge->active, false);
    atomic_init(&bridge->destroyed, false);
    return bridge;
}

bool DNMediaRemoteBridgeIsAvailable(const DNMediaRemoteBridge *bridge) {
    return bridge != NULL &&
        bridge->registerForNotifications != NULL &&
        bridge->unregisterForNotifications != NULL &&
        bridge->getNowPlayingInfo != NULL &&
        bridge->nowPlayingInfoDidChangeNotification != NULL;
}

void DNMediaRemoteBridgeStart(
    DNMediaRemoteBridge *bridge,
    DNMediaRemoteInfoCallback callback,
    void *context
) {
    if (!DNMediaRemoteBridgeIsAvailable(bridge) || callback == NULL) {
        return;
    }
    if (atomic_exchange_explicit(&bridge->active, true, memory_order_acq_rel)) {
        return;
    }

    bridge->callback = callback;
    bridge->context = context;
    CFNotificationCenterAddObserver(
        CFNotificationCenterGetLocalCenter(),
        bridge,
        dn_notification,
        bridge->nowPlayingInfoDidChangeNotification,
        NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately
    );
    bridge->registerForNotifications(bridge->queue);
    DNMediaRemoteBridgeRefresh(bridge);
}

void DNMediaRemoteBridgeStop(DNMediaRemoteBridge *bridge) {
    if (bridge == NULL) {
        return;
    }

    bool wasActive = atomic_exchange_explicit(&bridge->active, false, memory_order_acq_rel);
    if (!wasActive) {
        bridge->callback = NULL;
        bridge->context = NULL;
        return;
    }

    CFNotificationCenterRemoveObserver(
        CFNotificationCenterGetLocalCenter(),
        bridge,
        bridge->nowPlayingInfoDidChangeNotification,
        NULL
    );
    bridge->unregisterForNotifications();
    bridge->callback = NULL;
    bridge->context = NULL;
}

void DNMediaRemoteBridgeDestroy(DNMediaRemoteBridge *bridge) {
    if (bridge == NULL) {
        return;
    }

    DNMediaRemoteBridgeStop(bridge);
    atomic_store_explicit(&bridge->destroyed, true, memory_order_release);
    dn_release(bridge);
}

static void dn_request_info(DNMediaRemoteBridge *bridge, CFStringRef displayIdentifier) {
    if (!atomic_load_explicit(&bridge->active, memory_order_acquire)) {
        if (displayIdentifier != NULL) {
            CFRelease(displayIdentifier);
        }
        return;
    }

    dn_retain(bridge);
    bridge->getNowPlayingInfo(bridge->queue, ^(CFDictionaryRef info) {
        // The provider copies only the familiar fields it accepts while this
        // callback is active. Avoid retaining an unbounded artwork blob in a
        // second dictionary between the info and identity callbacks.
        dn_emit(bridge, info, displayIdentifier, 0);
        if (displayIdentifier != NULL) {
            CFRelease(displayIdentifier);
        }
        dn_release(bridge);
    });
}

void DNMediaRemoteBridgeRefresh(DNMediaRemoteBridge *bridge) {
    if (!DNMediaRemoteBridgeIsAvailable(bridge) ||
        !atomic_load_explicit(&bridge->active, memory_order_acquire)) {
        return;
    }

    if (bridge->getDisplayIdentifier == NULL) {
        dn_request_info(bridge, NULL);
        return;
    }

    dn_retain(bridge);
    bridge->getDisplayIdentifier(bridge->queue, ^(CFStringRef displayIdentifier) {
        CFStringRef displayIdentifierCopy = displayIdentifier == NULL
            ? NULL
            : CFStringCreateCopy(NULL, displayIdentifier);
        if (atomic_load_explicit(&bridge->active, memory_order_acquire)) {
            dn_request_info(bridge, displayIdentifierCopy);
        } else if (displayIdentifierCopy != NULL) {
            CFRelease(displayIdentifierCopy);
        }
        dn_release(bridge);
    });
}

bool DNMediaRemoteBridgeSendCommand(
    DNMediaRemoteBridge *bridge,
    int32_t command,
    double playbackPosition,
    bool hasPlaybackPosition
) {
    if (!DNMediaRemoteBridgeIsAvailable(bridge) ||
        !atomic_load_explicit(&bridge->active, memory_order_acquire) ||
        bridge->sendCommand == NULL) {
        return false;
    }

    id options = nil;
    if (hasPlaybackPosition) {
        if (!isfinite(playbackPosition) || bridge->playbackPositionOptionKey == NULL) {
            return false;
        }
        options = @{
            (__bridge NSString *)bridge->playbackPositionOptionKey: @(playbackPosition)
        };
    }

    return bridge->sendCommand(command, options);
}
