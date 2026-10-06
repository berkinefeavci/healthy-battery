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

static int variant_present(const CISMCOps *ops, const CIChannelVariant *variant) {
    for (int k = 0; k < variant->keyCount; k++) {
        int size = 0; char type[5] = {0};
        if (ops->info(ops->context, variant->keys[k].name, &size, type)) return 0;
        if (size != variant->keys[k].size || !strcmp(type, "flt ")) return 0;
        uint8_t probe[CI_MAX_KEY_BYTES];
        if (ops->read(ops->context, variant->keys[k].name, size, probe)) return 0;
    }
    return 1;
}

CICapabilities ci_resolve_capabilities(const CISMCOps *ops) {
    CICapabilities capabilities = {NULL, NULL};
    for (int v = 0; v < CI_CHARGING_VARIANT_COUNT && !capabilities.charging; v++)
        if (variant_present(ops, &CI_CHARGING_VARIANTS[v])) capabilities.charging = &CI_CHARGING_VARIANTS[v];
    for (int v = 0; v < CI_ADAPTER_VARIANT_COUNT && !capabilities.adapter; v++)
        if (variant_present(ops, &CI_ADAPTER_VARIANTS[v])) capabilities.adapter = &CI_ADAPTER_VARIANTS[v];
    return capabilities;
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
        if (ops->write(ops->context, key->name, key->size, bytes)) return CI_FAILED;
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

CIStatus ci_apply_state(const CISMCOps *ops, const CICapabilities *capabilities, CIState wanted, CIState *applied) {
    if ((wanted.chargingInhibited && !capabilities->charging) || (wanted.adapterInhibited && !capabilities->adapter)) {
        return CI_UNSUPPORTED;
    }
    CIStatus status = CI_OK;
    // Turn things off first so a partial failure never leaves more inhibited than requested.
    if (capabilities->adapter && !wanted.adapterInhibited && ci_write_channel(ops, capabilities->adapter, 0)) status = CI_FAILED;
    if (capabilities->charging && !wanted.chargingInhibited && ci_write_channel(ops, capabilities->charging, 0)) status = CI_FAILED;
    if (status == CI_OK && capabilities->charging && wanted.chargingInhibited && ci_write_channel(ops, capabilities->charging, 1)) status = CI_FAILED;
    if (status == CI_OK && capabilities->adapter && wanted.adapterInhibited && ci_write_channel(ops, capabilities->adapter, 1)) status = CI_FAILED;
    if (status != CI_OK) {
        if (capabilities->adapter) (void)ci_write_channel(ops, capabilities->adapter, 0);
        if (capabilities->charging) (void)ci_write_channel(ops, capabilities->charging, 0);
    }
    CIState readBack = {0, 0};
    if (ci_read_state(ops, capabilities, &readBack)) status = CI_FAILED; else *applied = readBack;
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
    case CI_REASON_REQUEST: return "request"; case CI_REASON_VERIFY_FAILED: return "verify-failed";
    }
    return "?";
}
