#include "smc.h"

#include <IOKit/IOKitLib.h>
#include <math.h>
#include <string.h>

#define KERNEL_INDEX_SMC      2
#define SMC_CMD_READ_BYTES    5
#define SMC_CMD_READ_KEYINFO  9

typedef struct {
    char major;
    char minor;
    char build;
    char reserved[1];
    UInt16 release;
} SMCVersion;

typedef struct {
    UInt16 version;
    UInt16 length;
    UInt32 cpuPLimit;
    UInt32 gpuPLimit;
    UInt32 memPLimit;
} SMCPLimitData;

typedef struct {
    UInt32 dataSize;
    UInt32 dataType;
    char dataAttributes;
} SMCKeyInfo;

typedef struct {
    UInt32 key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    char result;
    char status;
    char data8;
    UInt32 data32;
    unsigned char bytes[32];
} SMCKeyData;

static io_connect_t smc_conn = 0;

static UInt32 fourcc(const char *s) {
    return ((UInt32)(unsigned char)s[0] << 24) |
           ((UInt32)(unsigned char)s[1] << 16) |
           ((UInt32)(unsigned char)s[2] << 8)  |
            (UInt32)(unsigned char)s[3];
}

int smc_open(void) {
    if (smc_conn) return 0;

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                       IOServiceMatching("AppleSMC"));
    if (!service) return -1;

    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &smc_conn);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        smc_conn = 0;
        return -1;
    }
    return 0;
}

void smc_close(void) {
    if (smc_conn) {
        IOServiceClose(smc_conn);
        smc_conn = 0;
    }
}

static kern_return_t smc_call(SMCKeyData *in, SMCKeyData *out) {
    size_t outSize = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(smc_conn, KERNEL_INDEX_SMC,
                                     in, sizeof(SMCKeyData), out, &outSize);
}

double smc_read_temperature(const char *key) {
    double v = smc_read_value(key);
    return isnan(v) ? -1 : v;
}

double smc_read_value(const char *key) {
    if (!key || strlen(key) != 4) return NAN;
    if (!smc_conn && smc_open() != 0) return NAN;

    SMCKeyData in, out;
    memset(&in, 0, sizeof(in));
    memset(&out, 0, sizeof(out));

    // 1. Key info (size + data type)
    in.key = fourcc(key);
    in.data8 = SMC_CMD_READ_KEYINFO;
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return NAN;

    UInt32 size = out.keyInfo.dataSize;
    UInt32 type = out.keyInfo.dataType;

    // 2. The actual bytes
    in.keyInfo.dataSize = size;
    in.data8 = SMC_CMD_READ_BYTES;
    memset(&out, 0, sizeof(out));
    if (smc_call(&in, &out) != KERN_SUCCESS || out.result != 0) return NAN;

    const unsigned char *b = out.bytes;

    if (type == fourcc("sp78") && size >= 2) {
        // signed fixed-point 7.8 (temperatures)
        return (double)(signed char)b[0] + (double)b[1] / 256.0;
    }
    if (type == fourcc("fpe2") && size >= 2) {
        // unsigned fixed-point 14.2 (fan speeds on Intel)
        return (double)(((UInt32)b[0] << 8) | b[1]) / 4.0;
    }
    if (type == fourcc("flt ") && size == 4) {
        float f;
        memcpy(&f, b, sizeof(f));
        return (double)f;
    }
    if (type == fourcc("ui8 ") && size >= 1) return (double)b[0];
    if (type == fourcc("ui16") && size >= 2) return (double)(((UInt32)b[0] << 8) | b[1]);
    if (type == fourcc("ui32") && size >= 4) {
        return (double)(((UInt32)b[0] << 24) | ((UInt32)b[1] << 16) | ((UInt32)b[2] << 8) | b[3]);
    }
    return NAN;
}
