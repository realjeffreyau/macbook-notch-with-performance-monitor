#ifndef DYNAMIC_NOTCH_POWER_NOTIFICATION_BRIDGE_H
#define DYNAMIC_NOTCH_POWER_NOTIFICATION_BRIDGE_H

#include <stdint.h>

// Main-queue, coalesced notification of aggregate power assertion changes.
// Returns -1 if registration failed. Cancel before releasing the handler.
int32_t DNObservePowerAssertions(void (^handler)(void));
void DNCancelPowerAssertionObservation(int32_t token);

#endif
