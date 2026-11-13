#include "hid_thermal.h"

#include <CoreFoundation/CoreFoundation.h>
#include <string.h>

// Private IOKit API (exported by IOKit.framework, not declared in the public SDK).
// Widely used by system monitors to read Apple Silicon temperature sensors.
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type,
                                                 int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

#define kIOHIDEventTypeTemperature 15
#define IOHIDEventFieldBase(type) ((type) << 16)

// Vendor-defined usage page/usage for temperature sensors.
#define kHIDPage_AppleVendor 0xff00
#define kHIDUsage_AppleVendor_TemperatureSensor 0x0005

static IOHIDEventSystemClientRef client = NULL;
static CFArrayRef services = NULL;

static CFNumberRef make_int(int value) {
    return CFNumberCreate(kCFAllocatorDefault, kCFNumberIntType, &value);
}

static int ensure_services(void) {
    if (services) return 1;

    if (!client) {
        client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        if (!client) return 0;
    }

    CFNumberRef page = make_int(kHIDPage_AppleVendor);
    CFNumberRef usage = make_int(kHIDUsage_AppleVendor_TemperatureSensor);
    const void *keys[] = { CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage") };
    const void *values[] = { page, usage };
    CFDictionaryRef matching = CFDictionaryCreate(kCFAllocatorDefault, keys, values, 2,
                                                  &kCFTypeDictionaryKeyCallBacks,
                                                  &kCFTypeDictionaryValueCallBacks);
    CFRelease(page);
    CFRelease(usage);

    IOHIDEventSystemClientSetMatching(client, matching);
    CFRelease(matching);

    services = IOHIDEventSystemClientCopyServices(client);
    return services != NULL && CFArrayGetCount(services) > 0;
}

int hid_read_temperatures(hid_temperature_t *out, int max) {
    if (!out || max <= 0 || !ensure_services()) return 0;

    int written = 0;
    CFIndex count = CFArrayGetCount(services);

    for (CFIndex i = 0; i < count && written < max; i++) {
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(services, i);
        if (!service) continue;

        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kIOHIDEventTypeTemperature, 0, 0);
        if (!event) continue;
        double value = IOHIDEventGetFloatValue(event, IOHIDEventFieldBase(kIOHIDEventTypeTemperature));
        CFRelease(event);

        hid_temperature_t *entry = &out[written];
        entry->name[0] = '\0';
        entry->celsius = value;

        CFTypeRef product = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (product) {
            if (CFGetTypeID(product) == CFStringGetTypeID()) {
                CFStringGetCString((CFStringRef)product, entry->name, sizeof(entry->name),
                                   kCFStringEncodingUTF8);
            }
            CFRelease(product);
        }
        written++;
    }
    return written;
}
