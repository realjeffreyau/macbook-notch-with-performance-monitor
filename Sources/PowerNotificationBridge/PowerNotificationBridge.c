#include "PowerNotificationBridge.h"
#include <dispatch/dispatch.h>
#include <notify.h>

int32_t DNObservePowerAssertions(void (^handler)(void)) {
    int32_t token = -1;
    uint32_t result = notify_register_dispatch(
        "com.apple.system.powermanagement.assertions", &token,
        dispatch_get_main_queue(), ^(int ignored) { handler(); }
    );
    return result == NOTIFY_STATUS_OK ? token : -1;
}

void DNCancelPowerAssertionObservation(int32_t token) {
    notify_cancel(token);
}
