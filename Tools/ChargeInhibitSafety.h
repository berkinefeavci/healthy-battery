// Pure decision logic of the charge-inhibit helper. No IOKit, no sockets, no clock: every input is
// passed in, so Tests/ChargeInhibitSafetyTests.c exercises it without hardware. The Swift contract
// lives in Sources/ChargeMate/ChargeInhibit.swift; the constants below must match it.
#ifndef CHARGE_INHIBIT_SAFETY_H
#define CHARGE_INHIBIT_SAFETY_H
#include <stddef.h>
#include <stdint.h>

#define CI_CRITICAL_PERCENT 10
#define CI_WATCHDOG_SECONDS 60.0

typedef struct { int chargingInhibited; int adapterInhibited; } CIState;

typedef enum { CI_OK = 0, CI_BAD_REQUEST = 2, CI_REFUSED = 3, CI_FAILED = 4, CI_UNSUPPORTED = 5 } CIStatus;

// Why the engine dropped back to the released state (CI_REASON_NONE: it did not).
typedef enum {
    CI_REASON_NONE = 0, CI_REASON_START, CI_REASON_WATCHDOG, CI_REASON_LOW_BATTERY, CI_REASON_UNKNOWN_BATTERY,
    CI_REASON_UNPLUGGED, CI_REASON_SLEEP, CI_REASON_SHUTDOWN, CI_REASON_REQUEST, CI_REASON_VERIFY_FAILED
} CIReason;

// --- SMC key allowlist --------------------------------------------------------------------
// A channel is the group of keys one logical switch writes. Only these keys, with only these
// two byte patterns, are ever written. Values come from public open-source tools and are NOT
// yet verified on Mac17,8 (see docs/2026-10-06-SMC-probe.md): the helper enables a channel only
// when every key exists with the exact size and a type that is not a float.
#define CI_MAX_KEY_BYTES 4
#define CI_MAX_CHANNEL_KEYS 2
typedef struct { const char *name; int size; uint8_t on[CI_MAX_KEY_BYTES]; uint8_t off[CI_MAX_KEY_BYTES]; } CIKey;
typedef struct { const char *label; int keyCount; CIKey keys[CI_MAX_CHANNEL_KEYS]; } CIChannelVariant;

#define CI_CHARGING_VARIANT_COUNT 2
#define CI_ADAPTER_VARIANT_COUNT 1
extern const CIChannelVariant CI_CHARGING_VARIANTS[CI_CHARGING_VARIANT_COUNT];
extern const CIChannelVariant CI_ADAPTER_VARIANTS[CI_ADAPTER_VARIANT_COUNT];

// True only for (key, size, bytes) that is exactly an allowlisted on/off pattern.
int ci_write_allowed(const char *key, int size, const uint8_t *bytes);

// --- SMC abstraction (real implementation in the helper, fakes in tests) --------------------
typedef struct {
    // Returns 0 and fills size/type when the key exists.
    int (*info)(void *context, const char *key, int *size, char type[5]);
    int (*read)(void *context, const char *key, int size, uint8_t *bytes);
    int (*write)(void *context, const char *key, int size, const uint8_t *bytes);
    void *context;
} CISMCOps;

typedef struct {
    const CIChannelVariant *charging; // NULL: no verified charging key
    const CIChannelVariant *adapter;  // NULL: no verified adapter key
} CICapabilities;

CICapabilities ci_resolve_capabilities(const CISMCOps *ops);
// Reads the channel back: 1 on, 0 off, -1 unknown/mixed.
int ci_read_channel(const CISMCOps *ops, const CIChannelVariant *variant);
// Writes one channel (allowlist enforced, read-back verified). Returns CI_OK or CI_FAILED/CI_REFUSED.
CIStatus ci_write_channel(const CISMCOps *ops, const CIChannelVariant *variant, int on);
// Applies both channels, verifying each. On any verify failure it writes both channels off and
// returns CI_FAILED. `applied` receives what was actually read back.
CIStatus ci_apply_state(const CISMCOps *ops, const CICapabilities *capabilities, CIState wanted, CIState *applied);
CIStatus ci_read_state(const CISMCOps *ops, const CICapabilities *capabilities, CIState *state);

// --- Decision engine ------------------------------------------------------------------------
typedef struct { CIState requested; double lastHeartbeat; } CIEngine; // requested starts released

typedef struct {
    double now;           // monotonic seconds
    int batteryPercent;   // -1: unknown
    int adapterPresent;   // adapter physically present (even if logically inhibited)
    int sleeping;
    int shuttingDown;
} CIInputs;

void ci_engine_init(CIEngine *engine);
int ci_state_is_released(CIState state);
// Evaluates the safety rules against the current inputs. Returns the reason the engine must
// release (and then clears engine->requested, so a release is sticky until the app asks again).
CIReason ci_tick(CIEngine *engine, const CIInputs *inputs);
// Validates and records a request. CI_OK means the caller should now apply engine->requested.
CIStatus ci_request(CIEngine *engine, const CIInputs *inputs, const CICapabilities *capabilities, CIState wanted);
void ci_heartbeat(CIEngine *engine, const CIInputs *inputs);
const char *ci_reason_name(CIReason reason);

#endif
