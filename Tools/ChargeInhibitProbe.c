// READ-ONLY AppleSMC probe for charge-inhibit candidate keys. It never writes a key:
// the only SMC commands used are 9 (key info), 5 (read bytes) and 8 (key by index).
// Build: xcrun clang -O2 Tools/ChargeInhibitProbe.c -framework IOKit -framework CoreFoundation -o probe
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { CMD_READ = 5, CMD_INDEX = 8, CMD_INFO = 9 };

static io_connect_t smc;

static int call(const char *key, uint32_t index, uint8_t command, uint32_t size, uint8_t out[80]) {
    uint8_t in[80] = {0};
    if (command == CMD_INDEX) { memcpy(in + 44, &index, 4); }
    else { uint32_t code = 0; for (int i = 0; i < 4; i++) code = code << 8 | (uint8_t)key[i]; memcpy(in, &code, 4); }
    in[28] = (uint8_t)size;
    in[42] = command;
    size_t outSize = 80;
    memset(out, 0, 80);
    kern_return_t result = IOConnectCallStructMethod(smc, 2, in, 80, out, &outSize);
    if (result == kIOReturnNotPrivileged) return 0x2c1; // gated by macOS 27 entitlement
    if (result != kIOReturnSuccess) return -1;
    if (outSize != 80) return -2;
    return out[40] == 0 ? 0 : out[40];
}

static int info(const char *key, uint32_t *size, char type[5]) {
    uint8_t out[80];
    int status = call(key, 0, CMD_INFO, 0, out);
    if (status) return status;
    memcpy(size, out + 28, 4);
    for (int i = 0; i < 4; i++) type[i] = (char)out[35 - i];
    type[4] = 0;
    return 0;
}

static void report(const char *key) {
    uint32_t size = 0; char type[5] = {0};
    int status = info(key, &size, type);
    if (status) { printf("%-5s  %s (status 0x%02x)\n", key, status == 0x2c1 ? "GATED" : "absent", status & 0xff); return; }
    uint8_t out[80];
    status = call(key, 0, CMD_READ, size, out);
    printf("%-5s  type=%-4s size=%u  ", key, type, size);
    if (status) { printf("read failed (status 0x%02x)\n", status & 0xff); return; }
    printf("bytes=");
    for (uint32_t i = 0; i < size && i < 32; i++) printf("%02x", out[48 + i]);
    printf("\n");
}

int main(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) { puts("AppleSMC service unavailable"); return 1; }
    kern_return_t opened = IOServiceOpen(service, mach_task_self(), 0, &smc);
    IOObjectRelease(service);
    if (opened != kIOReturnSuccess) { printf("IOServiceOpen failed 0x%08x (may need root; not escalating)\n", opened); return 1; }
    puts("# Candidate keys");
    const char *keys[] = {"CHTE", "CHIE", "CH0B", "CH0C", "CH0I", "CH0J", "CHLC", "CHWA", "BCLM", "BFCL", "ACLC", "ACFP", "AC-W", "CHBI", "CHCC", NULL};
    for (int i = 0; keys[i]; i++) report(keys[i]);
    uint8_t out[80];
    uint32_t count = 0;
    if (!call("#KEY", 0, CMD_READ, 4, out)) { count = (uint32_t)out[48] << 24 | out[49] << 16 | out[50] << 8 | out[51]; }
    printf("\n# Keys starting with CH or BC or AC (of %u total)\n", count);
    for (uint32_t i = 0; i < count; i++) {
        if (call(NULL, i, CMD_INDEX, 0, out)) continue;
        char key[5] = {(char)out[3], (char)out[2], (char)out[1], (char)out[0], 0};
        if ((key[0] == 'C' && key[1] == 'H') || (key[0] == 'B' && key[1] == 'C') || (key[0] == 'A' && key[1] == 'C')) report(key);
    }
    IOServiceClose(smc);
    return 0;
}
