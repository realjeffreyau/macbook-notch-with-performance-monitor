#ifndef DYNAMIC_NOTCH_MEDIA_REMOTE_BRIDGE_H
#define DYNAMIC_NOTCH_MEDIA_REMOTE_BRIDGE_H

#include <CoreFoundation/CoreFoundation.h>
#include <stdbool.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DNMediaRemoteBridge DNMediaRemoteBridge;

typedef void (*DNMediaRemoteInfoCallback)(
    CFDictionaryRef info,
    CFStringRef sourceDisplayIdentifier,
    int32_t sourceProcessIdentifier,
    void *context
);

// Values are verified from the Tahoe MediaRemote command descriptions. The
// private framework remains dynamically loaded; these constants are not a
// public API contract.
enum DNMediaRemoteCommand {
    DNMediaRemoteCommandPlay = 0,
    DNMediaRemoteCommandPause = 1,
    DNMediaRemoteCommandTogglePlayPause = 2,
    DNMediaRemoteCommandNextTrack = 4,
    DNMediaRemoteCommandPreviousTrack = 5,
    DNMediaRemoteCommandSeekToPlaybackPosition = 24
};

DNMediaRemoteBridge *DNMediaRemoteBridgeCreate(void);
void DNMediaRemoteBridgeDestroy(DNMediaRemoteBridge *bridge);
bool DNMediaRemoteBridgeIsAvailable(const DNMediaRemoteBridge *bridge);

void DNMediaRemoteBridgeStart(
    DNMediaRemoteBridge *bridge,
    DNMediaRemoteInfoCallback callback,
    void *context
);
void DNMediaRemoteBridgeStop(DNMediaRemoteBridge *bridge);
void DNMediaRemoteBridgeRefresh(DNMediaRemoteBridge *bridge);

bool DNMediaRemoteBridgeSendCommand(
    DNMediaRemoteBridge *bridge,
    int32_t command,
    double playbackPosition,
    bool hasPlaybackPosition
);

#ifdef __cplusplus
}
#endif

#endif
