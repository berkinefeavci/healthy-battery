// Root LaunchDaemon: the only code that can write the charge-inhibit SMC keys.
// Safety logic is in ChargeInhibitSafety.c (unit-tested); this file is IOKit + socket glue.
// Everything runs on one serial dispatch queue, so there is no locking.
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <Security/Security.h>
#include <dispatch/dispatch.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include "ChargeInhibitIPC.h"

// ---------------------------------------------------------------- SMC (AppleSMC, 80-byte struct)
enum { SMC_WRITE = 6, SMC_READ = 5, SMC_INFO = 9 };
static io_connect_t smcConnection;

static int smc_open(void) {
    if (smcConnection) return 0;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return -1;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &smcConnection);
    IOObjectRelease(service);
    if (result != kIOReturnSuccess) { smcConnection = 0; return -1; }
    return 0;
}

static int smc_call(const char *key, uint8_t command, int size, const uint8_t *payload, uint8_t out[80]) {
    if (smc_open()) return -1;
    uint8_t in[80] = {0};
    uint32_t code = 0;
    for (int i = 0; i < 4; i++) code = code << 8 | (uint8_t)key[i];
    memcpy(in, &code, 4);
    in[28] = (uint8_t)size;
    in[42] = command;
    if (payload) memcpy(in + 48, payload, (size_t)size);
    size_t outSize = 80;
    memset(out, 0, 80);
    kern_return_t call = IOConnectCallStructMethod(smcConnection, 2, in, 80, out, &outSize);
    if (call == kIOReturnNotPrivileged) return CI_SMC_GATED; // macOS 27 entitlement gate; connection stays usable
    if (call != kIOReturnSuccess || outSize != 80) {
        IOServiceClose(smcConnection); smcConnection = 0; // reopen on the next call
        return -1;
    }
    return out[40];
}

static int real_info(void *context, const char *key, int *size, char type[5]) {
    (void)context; uint8_t out[80];
    int status = smc_call(key, SMC_INFO, 0, NULL, out);
    if (status) return status ? status : -1;
    uint32_t length; memcpy(&length, out + 28, 4);
    if (length < 1 || length > CI_MAX_KEY_BYTES) return -2;
    *size = (int)length;
    for (int i = 0; i < 4; i++) type[i] = (char)out[35 - i];
    type[4] = 0;
    return 0;
}
static int real_read(void *context, const char *key, int size, uint8_t *bytes) {
    (void)context; uint8_t out[80];
    int status = smc_call(key, SMC_READ, size, NULL, out);
    if (status) return status;
    memcpy(bytes, out + 48, (size_t)size);
    return 0;
}
static int real_write(void *context, const char *key, int size, const uint8_t *bytes) {
    (void)context; uint8_t out[80];
    if (!ci_write_allowed(key, size, bytes)) return -3; // defence in depth: same check as the logic layer
    return smc_call(key, SMC_WRITE, size, bytes, out);
}
static CISMCOps smcOps = {real_info, real_read, real_write, NULL};

// ---------------------------------------------------------------- battery
static int read_battery(int *percent, int *adapterDetails) {
    io_service_t battery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (!battery) return -1;
    int current = -1, maximum = -1, adapter = 0;
    CFTypeRef value;
    if ((value = IORegistryEntryCreateCFProperty(battery, CFSTR("CurrentCapacity"), kCFAllocatorDefault, 0))) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &current);
        CFRelease(value);
    }
    if ((value = IORegistryEntryCreateCFProperty(battery, CFSTR("MaxCapacity"), kCFAllocatorDefault, 0))) {
        if (CFGetTypeID(value) == CFNumberGetTypeID()) CFNumberGetValue(value, kCFNumberIntType, &maximum);
        CFRelease(value);
    }
    // While the adapter is logically inhibited macOS may report ExternalConnected = No even though
    // the cable is plugged in; AdapterDetails stays populated for as long as a source is attached.
    if ((value = IORegistryEntryCreateCFProperty(battery, CFSTR("AdapterDetails"), kCFAllocatorDefault, 0))) {
        adapter = CFGetTypeID(value) == CFDictionaryGetTypeID() && CFDictionaryGetCount(value) > 0;
        CFRelease(value);
    }
    IOObjectRelease(battery);
    // Apple Silicon reports CurrentCapacity as a percentage with MaxCapacity 100.
    *percent = (current >= 0 && maximum > 0) ? (int)((current * 100.0) / maximum + 0.5) : -1;
    *adapterDetails = adapter; // ExternalConnected is intentionally not read: see ci_cable_present
    return 0;
}

// ---------------------------------------------------------------- engine glue
static CIEngine engine;
static CICapabilities capabilities;
static int sleeping = 0, shuttingDown = 0, releasePending = 0, tickCount = 0;
static io_connect_t powerRoot;
static dispatch_queue_t queue;

static double monotonic_seconds(void) {
    struct timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    return (double)now.tv_sec + (double)now.tv_nsec / 1e9;
}

static CIInputs current_inputs(void) {
    CIInputs inputs = {monotonic_seconds(), -1, 0, sleeping, shuttingDown};
    int percent = -1, details = 0, acW = 0;
    int acReadable = ci_read_ac_w(&smcOps, &acW) == 0;
    if (!read_battery(&percent, &details)) inputs.batteryPercent = percent;
    CIPlugInputs plug = {acReadable, acW, details};
    inputs.adapterPresent = ci_cable_present(&plug);
    return inputs;
}

// Fail-safe: charging and adapter back to normal. Retried every tick until the read-back confirms it.
static void release_everything(CIReason reason) {
    CIState released = {0, 0}, applied = {0, 0};
    ci_engine_init(&engine);
    releasePending = ci_apply_state(&smcOps, &capabilities, released, &applied) != CI_OK;
    if (reason != CI_REASON_NONE) fprintf(stderr, "charge-inhibit: released (%s)%s\n", ci_reason_name(reason), releasePending ? ", retrying" : "");
}

static void tick(void) {
    CIInputs inputs = current_inputs();
    CIReason reason = ci_tick(&engine, &inputs);
    if (reason != CI_REASON_NONE) { release_everything(reason); return; }
    if (releasePending) { release_everything(CI_REASON_NONE); return; }
    // Every 5 s make sure the SMC agrees with the engine (covers crashes and outside writers).
    if (++tickCount % 5 == 0 && ci_state_is_released(engine.requested)) {
        CIState actual;
        if (ci_read_state(&smcOps, &capabilities, &actual) == CI_OK && !ci_state_is_released(actual)) release_everything(CI_REASON_START);
    }
}

static void handle_client(int client) {
    char line[24] = {0}; size_t length = 0;
    while (length < sizeof(line) - 1) {
        ssize_t n = read(client, line + length, 1);
        if (n != 1 || line[length++] == '\n') break;
    }
    CIState wanted = {0, 0};
    CICommand command = ci_parse_request(line, &wanted);
    CIInputs inputs = current_inputs();
    CIState actual = {0, 0};
    switch (command) {
    case CI_CMD_READ:
        if (ci_read_state(&smcOps, &capabilities, &actual) == CI_OK) dprintf(client, "0 %d %d\n", actual.chargingInhibited, actual.adapterInhibited);
        else dprintf(client, "%d\n", CI_FAILED);
        break;
    case CI_CMD_CAPABILITIES:
        dprintf(client, "0 %d %d %d %d\n", ci_channel_usable(capabilities.charging, capabilities.chargingReason),
                ci_channel_usable(capabilities.adapter, capabilities.adapterReason),
                (int)capabilities.chargingReason, (int)capabilities.adapterReason);
        break;
    case CI_CMD_HEARTBEAT:
        ci_heartbeat(&engine, &inputs);
        dprintf(client, "0\n");
        break;
    case CI_CMD_SET: {
        CIStatus status = ci_request(&engine, &inputs, &capabilities, wanted);
        if (status == CI_OK) {
            status = ci_apply_state(&smcOps, &capabilities, engine.requested, &actual);
            if (status != CI_OK) release_everything(CI_REASON_VERIFY_FAILED); // CI_GATED stays sticky in capabilities
        } else if (status == CI_REFUSED) {
            release_everything(CI_REASON_REQUEST); // a refused inhibit must leave nothing inhibited
        }
        if (status == CI_OK) dprintf(client, "0 %d %d\n", actual.chargingInhibited, actual.adapterInhibited);
        else dprintf(client, "%d\n", status);
        break;
    }
    default:
        dprintf(client, "%d\n", CI_BAD_REQUEST);
    }
}

// ---------------------------------------------------------------- trust (same model as the other helpers)
static int authorize_uid(uid_t uid) {
    if (geteuid() != 0) return 4;
    if (mkdir("/Library/Application Support", 0755) && errno != EEXIST) return 4;
    if (mkdir(CI_STATE_DIR, 0755) && errno != EEXIST) return 4;
    struct stat state;
    if (lstat(CI_STATE_DIR, &state) || !S_ISDIR(state.st_mode) || state.st_uid != 0 || (state.st_mode & 022)) return 4;
    int fd = open(CI_CLIENT_FILE, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0) return 4;
    int result = write(fd, &uid, sizeof(uid)) == sizeof(uid) && !fsync(fd) ? 0 : 4;
    close(fd);
    return result;
}

// A Developer ID helper answers only the Healthy Battery app signed by its own team, on top of the uid
// check: another program of the same user cannot cut the adapter. A local ad-hoc helper has no team and
// keeps the uid check alone. A team without a usable requirement refuses everyone (fail closed).
#define CI_APP_IDENTIFIER "io.github.berkinefeavci.cellkeep"
static SecRequirementRef clientRequirement;
static int signatureMode; // 0 ad-hoc helper: uid only · 1 enforce · -1 broken: refuse

static void load_client_requirement(void) {
    SecCodeRef self = NULL; SecStaticCodeRef staticSelf = NULL; CFDictionaryRef info = NULL;
    signatureMode = -1;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) == errSecSuccess &&
        SecCodeCopyStaticCode(self, kSecCSDefaultFlags, &staticSelf) == errSecSuccess &&
        SecCodeCopySigningInformation(staticSelf, kSecCSSigningInformation, &info) == errSecSuccess) {
        CFTypeRef team = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
        if (!team) signatureMode = 0;
        else if (CFGetTypeID(team) == CFStringGetTypeID()) {
            CFStringRef text = CFStringCreateWithFormat(NULL, NULL,
                CFSTR("identifier \"" CI_APP_IDENTIFIER "\" and anchor apple generic and certificate leaf[subject.OU] = \"%@\""), team);
            if (text && SecRequirementCreateWithString(text, kSecCSDefaultFlags, &clientRequirement) == errSecSuccess) signatureMode = 1;
            if (text) CFRelease(text);
        }
    }
    if (info) CFRelease(info);
    if (staticSelf) CFRelease(staticSelf);
    if (self) CFRelease(self);
    if (signatureMode < 0) fprintf(stderr, "charge-inhibit: own signature unreadable; refusing all clients\n");
}

static int client_signature_ok(int socketFD) {
    if (signatureMode == 0) return 1;
    if (signatureMode < 0 || !clientRequirement) return 0;
    audit_token_t token; socklen_t length = sizeof(token);
    if (getsockopt(socketFD, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) || length != sizeof(token)) return 0;
    CFDataRef data = CFDataCreate(NULL, (const UInt8 *)&token, sizeof(token));
    if (!data) return 0;
    const void *keys[] = {kSecGuestAttributeAudit}, *values[] = {data};
    CFDictionaryRef attributes = CFDictionaryCreate(NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                                                    &kCFTypeDictionaryValueCallBacks);
    CFRelease(data);
    SecCodeRef code = NULL;
    int ok = attributes && SecCodeCopyGuestWithAttributes(NULL, attributes, kSecCSDefaultFlags, &code) == errSecSuccess &&
        SecCodeCheckValidity(code, kSecCSDefaultFlags, clientRequirement) == errSecSuccess;
    if (code) CFRelease(code);
    if (attributes) CFRelease(attributes);
    return ok;
}

static int trusted_client(int socketFD) {
    uid_t uid = 0, gid = 0, expected = 0;
    if (getpeereid(socketFD, &uid, &gid)) return 0;
    int fd = open(CI_CLIENT_FILE, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 0;
    struct stat state;
    int trusted = !fstat(fd, &state) && S_ISREG(state.st_mode) && state.st_uid == 0 && !(state.st_mode & 022) &&
        state.st_size == (off_t)sizeof(expected) && read(fd, &expected, sizeof(expected)) == sizeof(expected) && expected == uid;
    close(fd);
    return trusted && client_signature_ok(socketFD);
}

// ---------------------------------------------------------------- power events and signals
static void power_callback(void *refcon, io_service_t service, natural_t message, void *argument) {
    (void)refcon; (void)service;
    CIPowerEvent event;
    switch (message) {
    case kIOMessageCanSystemSleep: event = CI_POWER_CAN_SLEEP; break;
    case kIOMessageSystemWillSleep: event = CI_POWER_WILL_SLEEP; break;
    case kIOMessageSystemHasPoweredOn: event = CI_POWER_HAS_POWERED_ON; break;
    case kIOMessageSystemWillPowerOff: event = CI_POWER_WILL_POWER_OFF; break;
    default: return;
    }
    CIPowerPlan plan = ci_power_plan(event);
    if (plan.setSleeping >= 0) sleeping = plan.setSleeping;
    if (plan.setShuttingDown) shuttingDown = 1;
    if (plan.release) release_everything(plan.reason); // before acknowledging, so the Mac sleeps with the adapter restored
    if (plan.acknowledge) IOAllowPowerChange(powerRoot, (intptr_t)argument);
    if (plan.recheckAfter) {
        // After wake nothing may stay cut off (the SMC can keep CHIE across sleep): re-read and restore.
        CIState actual;
        if (releasePending || ci_read_state(&smcOps, &capabilities, &actual) != CI_OK || !ci_state_is_released(actual))
            release_everything(CI_REASON_WAKE);
    }
}

static void terminate_now(int sig) { (void)sig; shuttingDown = 1; release_everything(CI_REASON_SHUTDOWN); _exit(0); }

static int open_server(void) {
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) return -1;
    fcntl(server, F_SETFD, FD_CLOEXEC);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (strlen(CI_SOCKET_PATH) >= sizeof(address.sun_path)) { close(server); return -1; }
    memcpy(address.sun_path, CI_SOCKET_PATH, strlen(CI_SOCKET_PATH) + 1);
    unlink(CI_SOCKET_PATH);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) || chmod(CI_SOCKET_PATH, 0666) || listen(server, 4)) {
        close(server); return -1;
    }
    signal(SIGPIPE, SIG_IGN);
    return server;
}

// READ-ONLY report for the human: never calls SMC_WRITE. Works without root.
static int check_gating(void) {
    const char *keys[] = {"CHTE", "CHIE", "CH0B", "CH0C", "CH0I", "CH0J", "AC-W", NULL};
    for (int i = 0; keys[i]; i++) {
        uint8_t out[80];
        int code = smc_call(keys[i], SMC_INFO, 0, NULL, out);
        if (code) { printf("%-5s info: %s (code 0x%x)\n", keys[i], ci_key_reason_name(ci_classify_smc_error(code)), code); continue; }
        int size = (int)out[28]; char type[5];
        for (int k = 0; k < 4; k++) type[k] = (char)out[35 - k];
        type[4] = 0;
        printf("%-5s present type=%s size=%d  ", keys[i], type, size);
        if (size < 1 || size > CI_MAX_KEY_BYTES) { puts("read: skipped (size)"); continue; }
        code = smc_call(keys[i], SMC_READ, size, NULL, out);
        if (code) { printf("read: %s (code 0x%x)\n", ci_key_reason_name(ci_classify_smc_error(code)), code); continue; }
        printf("read: ok bytes=");
        for (int k = 0; k < size; k++) printf("%02x", out[48 + k]);
        putchar('\n');
    }
    puts("(read-only: no write was attempted; write gating on CHIE is only visible through 'S' and the helper log)");
    return 0;
}

static int self_test(void) {
    CIState state = {0, 0};
    const uint8_t off1[] = {0}, on1[] = {8};
    if (ci_parse_request("S 1 0\n", &state) != CI_CMD_SET || ci_parse_request("W CHIE 08\n", &state) != CI_CMD_INVALID ||
        !ci_write_allowed("CHIE", 1, on1) || ci_write_allowed("BCLM", 1, off1) || ci_write_allowed("CHIE", 1, (const uint8_t[]){9})) return 1;
    puts("Charge inhibit helper: fixed allowlist assertions passed; no SMC access.");
    return 0;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--version")) { printf("%d\n", CI_HELPER_VERSION); return 0; }
    if (argc == 2 && !strcmp(argv[1], "--self-test")) return self_test();
    if (argc == 2 && !strcmp(argv[1], "--check-gating")) return check_gating();
    if (argc == 3 && !strcmp(argv[1], "--authorize-uid")) {
        char *tail = NULL;
        long uid = strtol(argv[2], &tail, 10);
        return *argv[2] && !*tail && uid >= 0 && uid <= INT_MAX ? authorize_uid((uid_t)uid) : 2;
    }
    if (argc != 2 || strcmp(argv[1], "--daemon") || geteuid() != 0) return 2;

    ci_engine_init(&engine);
    load_client_requirement();
    capabilities = ci_resolve_capabilities(&smcOps);
    release_everything(CI_REASON_START); // fail-safe default at every start
    int server = open_server();
    if (server < 0) return 4;
    queue = dispatch_queue_create(CI_LABEL, DISPATCH_QUEUE_SERIAL);

    signal(SIGTERM, SIG_IGN); signal(SIGINT, SIG_IGN); signal(SIGHUP, SIG_IGN);
    int signals[] = {SIGTERM, SIGINT, SIGHUP};
    for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); i++) {
        dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL, (uintptr_t)signals[i], 0, queue);
        dispatch_source_set_event_handler(source, ^{ terminate_now(0); });
        dispatch_resume(source);
    }
    IONotificationPortRef port = NULL; io_object_t notifier = 0;
    powerRoot = IORegisterForSystemPower(NULL, &port, power_callback, &notifier);
    if (powerRoot) IONotificationPortSetDispatchQueue(port, queue);

    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{ tick(); });
    dispatch_resume(timer);

    dispatch_source_t accepting = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, (uintptr_t)server, 0, queue);
    dispatch_source_set_event_handler(accepting, ^{
        int client = accept(server, NULL, NULL);
        if (client < 0) return;
        fcntl(client, F_SETFD, FD_CLOEXEC);
        struct timeval limit = {2, 0};
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
        if (trusted_client(client)) handle_client(client); else dprintf(client, "4\n");
        close(client);
    });
    dispatch_resume(accepting);
    dispatch_main();
}
