#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "../Tools/ChargeInhibitIPC.h"

// ---- fake SMC ----
typedef struct { char name[5]; int size; char type[5]; uint8_t bytes[4]; int present; } FakeKey;
typedef struct { FakeKey keys[8]; int count; int writes; int failWrites; int ignoreWrites; char lastWritten[8][5]; } FakeSMC;

static FakeKey *fake_find(FakeSMC *smc, const char *key) {
    for (int i = 0; i < smc->count; i++) if (!strcmp(smc->keys[i].name, key)) return &smc->keys[i];
    return NULL;
}
static void fake_add(FakeSMC *smc, const char *name, int size, const char *type) {
    FakeKey *key = &smc->keys[smc->count++];
    strcpy(key->name, name); key->size = size; strcpy(key->type, type); key->present = 1; memset(key->bytes, 0, 4);
}
static int fake_info(void *c, const char *key, int *size, char type[5]) {
    FakeKey *k = fake_find(c, key); if (!k) return 0x84; *size = k->size; strcpy(type, k->type); return 0;
}
static int fake_read(void *c, const char *key, int size, uint8_t *bytes) {
    FakeKey *k = fake_find(c, key); if (!k || k->size != size) return 0x84; memcpy(bytes, k->bytes, (size_t)size); return 0;
}
static int fake_write(void *c, const char *key, int size, const uint8_t *bytes) {
    FakeSMC *smc = c; FakeKey *k = fake_find(smc, key);
    assert(ci_write_allowed(key, size, bytes)); // the helper must never ask for anything else
    if (smc->failWrites) return 0xff;
    if (!k || k->size != size) return 0x84;
    smc->writes++;
    if (!smc->ignoreWrites) memcpy(k->bytes, bytes, (size_t)size);
    return 0;
}
static CISMCOps ops_for(FakeSMC *smc) { CISMCOps ops = {fake_info, fake_read, fake_write, smc}; return ops; }

static CIInputs inputs(double now, int percent) { CIInputs i = {now, percent, 1, 0, 0}; return i; }
static CIState state(int c, int a) { CIState s = {c, a}; return s; }
static CICapabilities both(void) { CICapabilities c = {&CI_CHARGING_VARIANTS[0], &CI_ADAPTER_VARIANTS[0]}; return c; }

int main(void) {
    // Allowlist: exact keys, sizes and byte patterns only.
    const uint8_t on4[] = {1, 0, 0, 0}, off4[] = {0, 0, 0, 0}, bad4[] = {2, 0, 0, 0}, on1[] = {8}, off1[] = {0}, bad1[] = {9};
    assert(ci_write_allowed("CHTE", 4, on4) && ci_write_allowed("CHTE", 4, off4) && !ci_write_allowed("CHTE", 4, bad4));
    assert(!ci_write_allowed("CHTE", 1, on1) && ci_write_allowed("CHIE", 1, on1) && ci_write_allowed("CHIE", 1, off1));
    assert(!ci_write_allowed("CHIE", 1, bad1) && !ci_write_allowed("CHIE", 4, on4));
    const uint8_t legacyOn[] = {2}; assert(ci_write_allowed("CH0B", 1, legacyOn) && ci_write_allowed("CH0C", 1, off1));
    assert(!ci_write_allowed("BCLM", 1, off1) && !ci_write_allowed("CH0J", 1, off1) && !ci_write_allowed("ACLC", 1, off1));
    assert(!ci_write_allowed(NULL, 1, off1) && !ci_write_allowed("CHIE", 1, NULL));

    // IPC parsing: strict allowlist of commands.
    CIState parsed = {-1, -1};
    assert(ci_parse_request("R\n", &parsed) == CI_CMD_READ);
    assert(ci_parse_request("C\n", &parsed) == CI_CMD_CAPABILITIES);
    assert(ci_parse_request("H\n", &parsed) == CI_CMD_HEARTBEAT);
    assert(ci_parse_request("S 1 0\n", &parsed) == CI_CMD_SET && parsed.chargingInhibited == 1 && parsed.adapterInhibited == 0);
    assert(ci_parse_request("S 0 1\n", &parsed) == CI_CMD_SET && parsed.chargingInhibited == 0 && parsed.adapterInhibited == 1);
    assert(ci_parse_request("S 2 0\n", &parsed) == CI_CMD_INVALID && ci_parse_request("S 1 0", &parsed) == CI_CMD_INVALID);
    assert(ci_parse_request("S 1 0 1\n", &parsed) == CI_CMD_INVALID && ci_parse_request("W CHIE 08\n", &parsed) == CI_CMD_INVALID);
    assert(ci_parse_request("", &parsed) == CI_CMD_INVALID && ci_parse_request("R\nR\n", &parsed) == CI_CMD_INVALID);
    assert(ci_parse_request("S 1 -1\n", &parsed) == CI_CMD_INVALID && ci_parse_request("PING\n", &parsed) == CI_CMD_INVALID);

    // Capability resolution mirrors what this Mac reports: CHIE present, CHTE absent.
    FakeSMC smc = {0};
    fake_add(&smc, "CHIE", 1, "hex_");
    CISMCOps ops = ops_for(&smc);
    CICapabilities caps = ci_resolve_capabilities(&ops);
    assert(!caps.charging && caps.adapter == &CI_ADAPTER_VARIANTS[0]);
    fake_add(&smc, "CHTE", 4, "hex_");
    caps = ci_resolve_capabilities(&ops);
    assert(caps.charging == &CI_CHARGING_VARIANTS[0]);
    // Wrong size or float type: not trusted.
    FakeSMC odd = {0}; fake_add(&odd, "CHTE", 1, "ui8 "); fake_add(&odd, "CHIE", 1, "flt ");
    CISMCOps oddOps = ops_for(&odd); caps = ci_resolve_capabilities(&oddOps);
    assert(!caps.charging && !caps.adapter);
    // Legacy pair needs both keys.
    FakeSMC legacy = {0}; fake_add(&legacy, "CH0B", 1, "hex_");
    CISMCOps legacyOps = ops_for(&legacy); caps = ci_resolve_capabilities(&legacyOps); assert(!caps.charging);
    fake_add(&legacy, "CH0C", 1, "hex_"); caps = ci_resolve_capabilities(&legacyOps);
    assert(caps.charging == &CI_CHARGING_VARIANTS[1]);

    // Apply + read-back verification.
    caps = ci_resolve_capabilities(&ops);
    CIState applied = {9, 9};
    assert(ci_apply_state(&ops, &caps, state(1, 0), &applied) == CI_OK && applied.chargingInhibited == 1 && !applied.adapterInhibited);
    assert(!memcmp(fake_find(&smc, "CHTE")->bytes, on4, 4) && fake_find(&smc, "CHIE")->bytes[0] == 0);
    assert(ci_apply_state(&ops, &caps, state(0, 1), &applied) == CI_OK && !applied.chargingInhibited && applied.adapterInhibited);
    assert(fake_find(&smc, "CHIE")->bytes[0] == 8);
    assert(ci_apply_state(&ops, &caps, state(0, 0), &applied) == CI_OK && ci_state_is_released(applied));
    // Unsupported request is refused before any write.
    FakeSMC onlyAdapter = {0}; fake_add(&onlyAdapter, "CHIE", 1, "hex_");
    CISMCOps onlyOps = ops_for(&onlyAdapter); CICapabilities onlyCaps = ci_resolve_capabilities(&onlyOps);
    assert(ci_apply_state(&onlyOps, &onlyCaps, state(1, 0), &applied) == CI_UNSUPPORTED && onlyAdapter.writes == 0);
    // Write that does not stick (verify fails) reports failure and rolls back.
    smc.ignoreWrites = 1; smc.writes = 0;
    assert(ci_apply_state(&ops, &caps, state(1, 1), &applied) == CI_FAILED);
    smc.ignoreWrites = 0;
    fake_find(&smc, "CHIE")->bytes[0] = 8; // stuck inhibited, e.g. after a crash
    assert(ci_apply_state(&ops, &caps, state(0, 0), &applied) == CI_OK && fake_find(&smc, "CHIE")->bytes[0] == 0);
    // Write errors fail closed.
    smc.failWrites = 1; assert(ci_apply_state(&ops, &caps, state(1, 0), &applied) == CI_FAILED); smc.failWrites = 0;
    // Unknown byte patterns read back as an error, never as "released".
    fake_find(&smc, "CHIE")->bytes[0] = 0x55;
    CIState readState; assert(ci_read_state(&ops, &caps, &readState) == CI_FAILED);
    fake_find(&smc, "CHIE")->bytes[0] = 0;

    CICapabilities B = both();
    // Engine: request, heartbeat, watchdog.
    CIEngine engine; ci_engine_init(&engine);
    assert(ci_state_is_released(engine.requested));
    CIInputs now = inputs(100, 85);
    assert(ci_request(&engine, &now, &B, state(1, 0)) == CI_OK && engine.requested.chargingInhibited);
    now = inputs(159.9, 85); assert(ci_tick(&engine, &now) == CI_REASON_NONE);
    now = inputs(150, 85); ci_heartbeat(&engine, &now);
    now = inputs(209.9, 85); assert(ci_tick(&engine, &now) == CI_REASON_NONE); // 59.9 s after the heartbeat
    now = inputs(210.1, 85); assert(ci_tick(&engine, &now) == CI_REASON_WATCHDOG && ci_state_is_released(engine.requested));
    now = inputs(211, 85); assert(ci_tick(&engine, &now) == CI_REASON_NONE); // sticky release, nothing more to do
    ci_heartbeat(&engine, &now); assert(ci_state_is_released(engine.requested)); // heartbeat does not revive
    // Clock going backwards counts as a watchdog failure.
    now = inputs(1000, 85); ci_request(&engine, &now, &B, state(0, 1));
    now = inputs(900, 85); assert(ci_tick(&engine, &now) == CI_REASON_WATCHDOG);

    // Battery rules.
    now = inputs(0, 85); assert(ci_request(&engine, &now, &B, state(1, 0)) == CI_OK);
    now = inputs(1, 9); assert(ci_tick(&engine, &now) == CI_REASON_LOW_BATTERY && ci_state_is_released(engine.requested));
    now = inputs(2, 9); assert(ci_request(&engine, &now, &B, state(1, 0)) == CI_REFUSED);
    now = inputs(2, 10); assert(ci_request(&engine, &now, &B, state(0, 1)) == CI_OK); // 10 % is allowed, 9 % is not
    now = inputs(3, -1); assert(ci_tick(&engine, &now) == CI_REASON_UNKNOWN_BATTERY);
    now = inputs(3, -1); assert(ci_request(&engine, &now, &B, state(1, 0)) == CI_REFUSED);
    now = inputs(3, 9); assert(ci_request(&engine, &now, &B, state(0, 0)) == CI_OK); // release is always allowed

    // Unplug, sleep, shutdown.
    now = inputs(10, 80); ci_request(&engine, &now, &B, state(1, 1));
    now.adapterPresent = 0; assert(ci_tick(&engine, &now) == CI_REASON_UNPLUGGED && ci_state_is_released(engine.requested));
    assert(ci_request(&engine, &now, &B, state(1, 0)) == CI_REFUSED);
    now = inputs(20, 80); ci_request(&engine, &now, &B, state(1, 0));
    now.sleeping = 1; assert(ci_tick(&engine, &now) == CI_REASON_SLEEP && ci_state_is_released(engine.requested));
    assert(ci_request(&engine, &now, &B, state(1, 0)) == CI_REFUSED);
    now = inputs(30, 80); ci_request(&engine, &now, &B, state(0, 1));
    now.shuttingDown = 1; assert(ci_tick(&engine, &now) == CI_REASON_SHUTDOWN && ci_state_is_released(engine.requested));
    assert(ci_request(&engine, &now, &B, state(0, 1)) == CI_REFUSED);

    // Capability gating and malformed requests.
    CICapabilities none = {NULL, NULL}; now = inputs(40, 80);
    assert(ci_request(&engine, &now, &none, state(1, 0)) == CI_UNSUPPORTED && ci_state_is_released(engine.requested));
    assert(ci_request(&engine, &now, &none, state(0, 1)) == CI_UNSUPPORTED);
    assert(ci_request(&engine, &now, &B, state(2, 0)) == CI_BAD_REQUEST);
    assert(ci_request(&engine, &now, &B, state(0, -1)) == CI_BAD_REQUEST);

    // Watchdog constant matches the Swift contract (ChargeInhibitSafety.watchdogTimeout / criticalPercent).
    assert(CI_WATCHDOG_SECONDS == 60.0 && CI_CRITICAL_PERCENT == 10);
    puts("Charge inhibit helper: allowlist, IPC, verify, watchdog, battery, unplug, sleep, shutdown assertions passed; no hardware touched.");
}
