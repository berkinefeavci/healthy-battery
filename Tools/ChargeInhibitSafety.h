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

typedef enum { CI_OK = 0, CI_BAD_REQUEST = 2, CI_REFUSED = 3, CI_FAILED = 4, CI_UNSUPPORTED = 5,
               CI_GATED = 6 /* macOS refuses the key (kIOReturnNotPrivileged); no point retrying */ } CIStatus;

// Why the engine dropped back to the released state (CI_REASON_NONE: it did not).
typedef enum {
    CI_REASON_NONE = 0, CI_REASON_START, CI_REASON_WATCHDOG, CI_REASON_LOW_BATTERY, CI_REASON_UNKNOWN_BATTERY,
    CI_REASON_UNPLUGGED, CI_REASON_SLEEP, CI_REASON_SHUTDOWN, CI_REASON_REQUEST, CI_REASON_VERIFY_FAILED, CI_REASON_WAKE
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
// Return codes of the SMC ops. 0 = ok. Anything else is classified by ci_classify_smc_error.
#define CI_SMC_NOT_FOUND 0x84    // SMC result byte: key does not exist
#define CI_SMC_NOT_WRITABLE 0x86 // SMC result byte: key exists but refuses the write
#define CI_SMC_GATED 0x2c1       // IOKit kIOReturnNotPrivileged (0xe00002c1): macOS 27 entitlement gate, even for root
typedef enum { CI_KEY_OK = 0, CI_KEY_MISSING = 1, CI_KEY_GATED = 2, CI_KEY_ERROR = 3 } CIKeyReason;
// Maps an ops return code to a reason ("gated" must never be reported as "missing").
CIKeyReason ci_classify_smc_error(int code);
const char *ci_key_reason_name(CIKeyReason reason);

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
    // Why the channel is unavailable (or CI_KEY_GATED once a write was refused, even if the variant
    // pointer stays set so the release path can still try to write the "off" value).
    CIKeyReason chargingReason, adapterReason;
} CICapabilities;
// A channel is usable only if its variant is verified and the OS has not gated it.
int ci_channel_usable(const CIChannelVariant *variant, CIKeyReason reason);

CICapabilities ci_resolve_capabilities(const CISMCOps *ops);
// Reads the channel back: 1 on, 0 off, -1 unknown/mixed.
int ci_read_channel(const CISMCOps *ops, const CIChannelVariant *variant);
// Writes one channel (allowlist enforced, read-back verified). Returns CI_OK or CI_FAILED/CI_REFUSED.
CIStatus ci_write_channel(const CISMCOps *ops, const CIChannelVariant *variant, int on);
// Applies both channels, verifying each. On any verify failure it writes both channels off and
// returns CI_FAILED, or CI_GATED (and marks the channel gated) when macOS refused a write. `applied` receives what was actually read back.
CIStatus ci_apply_state(const CISMCOps *ops, CICapabilities *capabilities, CIState wanted, CIState *applied);
CIStatus ci_read_state(const CISMCOps *ops, const CICapabilities *capabilities, CIState *state);

// --- Cable presence -----------------------------------------------------------------------
// While the adapter is logically cut (CHIE=08) IORegistry ExternalConnected may drop to No with the
// cable still in. Primary signal: SMC AC-W (si8, > 0 = a source is attached). Fallback only when
// AC-W cannot be read: IORegistry AdapterDetails non-empty. ExternalConnected is deliberately
// NOT an input: it must never decide "plugged" or "unplugged" on its own.
typedef struct {
    int acWReadable;           // AC-W was read successfully (1 byte, si8)
    int acW;                   // int8 value when readable
    int adapterDetailsPresent; // IORegistry AdapterDetails dictionary is non-empty
} CIPlugInputs;
int ci_cable_present(const CIPlugInputs *inputs);
// Reads AC-W through the ops (size 1, "si8 " only). 0 on success.
int ci_read_ac_w(const CISMCOps *ops, int *value);

// --- Power events -------------------------------------------------------------------------
typedef enum { CI_POWER_CAN_SLEEP, CI_POWER_WILL_SLEEP, CI_POWER_HAS_POWERED_ON, CI_POWER_WILL_POWER_OFF } CIPowerEvent;
typedef struct {
    int release;        // release the adapter/charging channels now, BEFORE acknowledging
    CIReason reason;
    int setSleeping;    // -1 unchanged, 0/1 new value
    int setShuttingDown;
    int recheckAfter;   // re-read the SMC and release anything still inhibited
    int acknowledge;    // IOAllowPowerChange once the release above has been attempted
} CIPowerPlan;
CIPowerPlan ci_power_plan(CIPowerEvent event);

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
