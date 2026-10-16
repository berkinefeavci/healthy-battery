#include "ChargeInhibitSafety.h"
#include <string.h>

const CIChannelVariant CI_CHARGING_VARIANTS[CI_CHARGING_VARIANT_COUNT] = {
    {"CHTE", 1, {{"CHTE", 4, {0x01, 0x00, 0x00, 0x00}, {0x00, 0x00, 0x00, 0x00}}}},
    {"CH0B+CH0C", 2, {{"CH0B", 1, {0x02}, {0x00}}, {"CH0C", 1, {0x02}, {0x00}}}},
};
const CIChannelVariant CI_ADAPTER_VARIANTS[CI_ADAPTER_VARIANT_COUNT] = {
    {"CHIE", 1, {{"CHIE", 1, {0x08}, {0x00}}}},
};

static const CIKey *find_key(const char *name) {
    for (int v = 0; v < CI_CHARGING_VARIANT_COUNT; v++)
        for (int k = 0; k < CI_CHARGING_VARIANTS[v].keyCount; k++)
            if (!strcmp(CI_CHARGING_VARIANTS[v].keys[k].name, name)) return &CI_CHARGING_VARIANTS[v].keys[k];
    for (int v = 0; v < CI_ADAPTER_VARIANT_COUNT; v++)
        for (int k = 0; k < CI_ADAPTER_VARIANTS[v].keyCount; k++)
            if (!strcmp(CI_ADAPTER_VARIANTS[v].keys[k].name, name)) return &CI_ADAPTER_VARIANTS[v].keys[k];
    return NULL;
}

int ci_write_allowed(const char *key, int size, const uint8_t *bytes) {
    if (!key || !bytes) return 0;
    const CIKey *entry = find_key(key);
    if (!entry || size != entry->size) return 0;
    return !memcmp(bytes, entry->on, (size_t)size) || !memcmp(bytes, entry->off, (size_t)size);
}

CIKeyReason ci_classify_smc_error(int code) {
    if (code == 0) return CI_KEY_OK;
    if (code == CI_SMC_NOT_FOUND) return CI_KEY_MISSING;
    if (code == CI_SMC_GATED || code == CI_SMC_NOT_WRITABLE) return CI_KEY_GATED;
    return CI_KEY_ERROR;
}

const char *ci_key_reason_name(CIKeyReason reason) {
    switch (reason) {
    case CI_KEY_OK: return "ok"; case CI_KEY_MISSING: return "missing"; case CI_KEY_GATED: return "gated"; case CI_KEY_ERROR: return "error";
    }
    return "?";
}

int ci_channel_usable(const CIChannelVariant *variant, CIKeyReason reason) { return variant != NULL && reason != CI_KEY_GATED; }

// OK when every key of the variant exists with the exact size, is not a float and can be read.
static CIKeyReason variant_status(const CISMCOps *ops, const CIChannelVariant *variant) {
    for (int k = 0; k < variant->keyCount; k++) {
        int size = 0; char type[5] = {0};
        int code = ops->info(ops->context, variant->keys[k].name, &size, type);
        if (code) return ci_classify_smc_error(code);
        if (size != variant->keys[k].size || !strcmp(type, "flt ")) return CI_KEY_ERROR;
        uint8_t probe[CI_MAX_KEY_BYTES];
        code = ops->read(ops->context, variant->keys[k].name, size, probe);
        if (code) return ci_classify_smc_error(code);
    }
    return CI_KEY_OK;
}

// Several variants compete for one channel: the first usable one wins; otherwise the most
// informative failure is reported (gated > error > missing).
static CIKeyReason pick_variant(const CISMCOps *ops, const CIChannelVariant *variants, int count, const CIChannelVariant **chosen) {
    CIKeyReason worst = CI_KEY_MISSING;
    *chosen = NULL;
    for (int v = 0; v < count; v++) {
        CIKeyReason status = variant_status(ops, &variants[v]);
        if (status == CI_KEY_OK) { *chosen = &variants[v]; return CI_KEY_OK; }
        if (status == CI_KEY_GATED || (status == CI_KEY_ERROR && worst != CI_KEY_GATED)) worst = status;
    }
    return worst;
}

CICapabilities ci_resolve_capabilities(const CISMCOps *ops) {
    CICapabilities capabilities = {NULL, NULL, CI_KEY_MISSING, CI_KEY_MISSING};
    capabilities.chargingReason = pick_variant(ops, CI_CHARGING_VARIANTS, CI_CHARGING_VARIANT_COUNT, &capabilities.charging);
    capabilities.adapterReason = pick_variant(ops, CI_ADAPTER_VARIANTS, CI_ADAPTER_VARIANT_COUNT, &capabilities.adapter);
    return capabilities;
}

int ci_read_ac_w(const CISMCOps *ops, int *value) {
    int size = 0; char type[5] = {0}; uint8_t byte = 0;
    if (ops->info(ops->context, "AC-W", &size, type) || size != 1 || strcmp(type, "si8 ")) return -1;
    if (ops->read(ops->context, "AC-W", 1, &byte)) return -1;
    *value = (int8_t)byte;
    return 0;
}

int ci_cable_present(const CIPlugInputs *inputs) {
    if (inputs->acWReadable) return inputs->acW > 0;
    return inputs->adapterDetailsPresent != 0;
}

CIPowerPlan ci_power_plan(CIPowerEvent event) {
    CIPowerPlan plan = {0, CI_REASON_NONE, -1, 0, 0, 0};
    switch (event) {
    // Idle sleep may still be vetoed by someone else, so this does not mark the Mac as sleeping,
    // but the adapter is restored before we say yes: the Mac must never fall asleep cut off.
    case CI_POWER_CAN_SLEEP: plan.release = 1; plan.reason = CI_REASON_SLEEP; plan.acknowledge = 1; break;
    case CI_POWER_WILL_SLEEP: plan.release = 1; plan.reason = CI_REASON_SLEEP; plan.setSleeping = 1; plan.acknowledge = 1; break;
    case CI_POWER_HAS_POWERED_ON: plan.setSleeping = 0; plan.recheckAfter = 1; break;
    case CI_POWER_WILL_POWER_OFF: plan.release = 1; plan.reason = CI_REASON_SHUTDOWN; plan.setShuttingDown = 1; plan.acknowledge = 1; break;
    }
    return plan;
}

int ci_read_channel(const CISMCOps *ops, const CIChannelVariant *variant) {
    int on = 0, off = 0;
    for (int k = 0; k < variant->keyCount; k++) {
        const CIKey *key = &variant->keys[k];
        uint8_t bytes[CI_MAX_KEY_BYTES] = {0};
        if (ops->read(ops->context, key->name, key->size, bytes)) return -1;
        if (!memcmp(bytes, key->on, (size_t)key->size)) on++;
        else if (!memcmp(bytes, key->off, (size_t)key->size)) off++;
        else return -1;
    }
    if (on == variant->keyCount) return 1;
    if (off == variant->keyCount) return 0;
    return -1;
}

CIStatus ci_write_channel(const CISMCOps *ops, const CIChannelVariant *variant, int on) {
    for (int k = 0; k < variant->keyCount; k++) {
        const CIKey *key = &variant->keys[k];
        const uint8_t *bytes = on ? key->on : key->off;
        if (!ci_write_allowed(key->name, key->size, bytes)) return CI_REFUSED;
        int code = ops->write(ops->context, key->name, key->size, bytes);
        if (code) return ci_classify_smc_error(code) == CI_KEY_GATED ? CI_GATED : CI_FAILED;
    }
    return ci_read_channel(ops, variant) == (on ? 1 : 0) ? CI_OK : CI_FAILED;
}

CIStatus ci_read_state(const CISMCOps *ops, const CICapabilities *capabilities, CIState *state) {
    CIState result = {0, 0};
    if (capabilities->charging) {
        int value = ci_read_channel(ops, capabilities->charging);
        if (value < 0) return CI_FAILED;
        result.chargingInhibited = value;
    }
    if (capabilities->adapter) {
        int value = ci_read_channel(ops, capabilities->adapter);
        if (value < 0) return CI_FAILED;
        result.adapterInhibited = value;
    }
    *state = result;
    return CI_OK;
}

CIStatus ci_apply_state(const CISMCOps *ops, CICapabilities *capabilities, CIState wanted, CIState *applied) {
    if ((wanted.chargingInhibited && capabilities->chargingReason == CI_KEY_GATED) ||
        (wanted.adapterInhibited && capabilities->adapterReason == CI_KEY_GATED)) return CI_GATED;
    if ((wanted.chargingInhibited && !capabilities->charging) || (wanted.adapterInhibited && !capabilities->adapter)) {
        return CI_UNSUPPORTED;
    }
    CIStatus status = CI_OK;
    CIStatus step;
#define CI_STEP(channel, reasonField, value) \
    if (status == CI_OK && capabilities->channel && (step = ci_write_channel(ops, capabilities->channel, value))) { \
        status = step; if (step == CI_GATED) capabilities->reasonField = CI_KEY_GATED; }
    // Turn things off first so a partial failure never leaves more inhibited than requested.
    if (!wanted.adapterInhibited) { CI_STEP(adapter, adapterReason, 0) }
    if (!wanted.chargingInhibited) { CI_STEP(charging, chargingReason, 0) }
    if (wanted.chargingInhibited) { CI_STEP(charging, chargingReason, 1) }
    if (wanted.adapterInhibited) { CI_STEP(adapter, adapterReason, 1) }
#undef CI_STEP
    if (status != CI_OK) {
        if (capabilities->adapter) (void)ci_write_channel(ops, capabilities->adapter, 0);
        if (capabilities->charging) (void)ci_write_channel(ops, capabilities->charging, 0);
    }
    CIState readBack = {0, 0};
    if (ci_read_state(ops, capabilities, &readBack)) { if (status == CI_OK) status = CI_FAILED; } else *applied = readBack;
    return status;
}

void ci_engine_init(CIEngine *engine) {
    engine->requested.chargingInhibited = 0;
    engine->requested.adapterInhibited = 0;
    engine->lastHeartbeat = 0;
}

int ci_state_is_released(CIState state) { return !state.chargingInhibited && !state.adapterInhibited; }

CIReason ci_tick(CIEngine *engine, const CIInputs *inputs) {
    if (ci_state_is_released(engine->requested)) return CI_REASON_NONE;
    CIReason reason = CI_REASON_NONE;
    if (inputs->shuttingDown) reason = CI_REASON_SHUTDOWN;
    else if (inputs->sleeping) reason = CI_REASON_SLEEP;
    else if (inputs->now - engine->lastHeartbeat > CI_WATCHDOG_SECONDS || inputs->now < engine->lastHeartbeat) reason = CI_REASON_WATCHDOG;
    else if (inputs->batteryPercent < 0) reason = CI_REASON_UNKNOWN_BATTERY;
    else if (inputs->batteryPercent < CI_CRITICAL_PERCENT) reason = CI_REASON_LOW_BATTERY;
    else if (!inputs->adapterPresent) reason = CI_REASON_UNPLUGGED;
    if (reason != CI_REASON_NONE) ci_engine_init(engine);
    return reason;
}

CIStatus ci_request(CIEngine *engine, const CIInputs *inputs, const CICapabilities *capabilities, CIState wanted) {
    if ((wanted.chargingInhibited != 0 && wanted.chargingInhibited != 1) || (wanted.adapterInhibited != 0 && wanted.adapterInhibited != 1)) {
        return CI_BAD_REQUEST;
    }
    if (ci_state_is_released(wanted)) { ci_engine_init(engine); return CI_OK; } // releasing is always allowed
    if (inputs->shuttingDown || inputs->sleeping) return CI_REFUSED;
    if (inputs->batteryPercent < CI_CRITICAL_PERCENT) return CI_REFUSED; // also covers unknown (-1)
    if (!inputs->adapterPresent) return CI_REFUSED;
    if ((wanted.chargingInhibited && capabilities->chargingReason == CI_KEY_GATED) ||
        (wanted.adapterInhibited && capabilities->adapterReason == CI_KEY_GATED)) return CI_GATED;
    if ((wanted.chargingInhibited && !capabilities->charging) || (wanted.adapterInhibited && !capabilities->adapter)) return CI_UNSUPPORTED;
    engine->requested = wanted;
    engine->lastHeartbeat = inputs->now;
    return CI_OK;
}

void ci_heartbeat(CIEngine *engine, const CIInputs *inputs) {
    if (!ci_state_is_released(engine->requested)) engine->lastHeartbeat = inputs->now;
}

const char *ci_reason_name(CIReason reason) {
    switch (reason) {
    case CI_REASON_NONE: return "none"; case CI_REASON_START: return "start"; case CI_REASON_WATCHDOG: return "watchdog";
    case CI_REASON_LOW_BATTERY: return "low-battery"; case CI_REASON_UNKNOWN_BATTERY: return "unknown-battery";
    case CI_REASON_UNPLUGGED: return "unplugged"; case CI_REASON_SLEEP: return "sleep"; case CI_REASON_SHUTDOWN: return "shutdown";
    case CI_REASON_REQUEST: return "request"; case CI_REASON_VERIFY_FAILED: return "verify-failed"; case CI_REASON_WAKE: return "wake";
    }
    return "?";
}
