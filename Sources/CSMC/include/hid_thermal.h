#ifndef CSMC_HID_THERMAL_H
#define CSMC_HID_THERMAL_H

/// A single temperature sensor exposed through the IOHIDEventSystem (Apple Silicon).
typedef struct {
    char name[64];
    double celsius;
} hid_temperature_t;

/// Reads all temperature sensors exposed via the (private) IOHIDEventSystemClient API.
/// This is how temperatures are read on Apple Silicon, where the Intel SMC keys don't exist.
/// Writes up to `max` entries into `out` and returns how many were written (0 if unsupported).
int hid_read_temperatures(hid_temperature_t *out, int max);

#endif
