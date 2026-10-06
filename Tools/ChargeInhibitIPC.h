// Wire protocol shared by the helper and (as text, mirrored in ChargeInhibitHelperBackend.swift)
// the app. One request line per connection; the reply is "<status>[ <values>]\n".
//   R\n        -> 0 <chargingInhibited> <adapterInhibited>   read verified state
//   C\n        -> 0 <chargingKeyVerified> <adapterKeyVerified>
//   S c a\n    -> 0 <c> <a>   set (c, a in {0,1}); read-back verified; 2 bad, 3 refused, 4 failed, 5 unsupported
//   H\n        -> 0           heartbeat
// Nothing else is accepted: no key names, no raw bytes, no paths.
#ifndef CHARGE_INHIBIT_IPC_H
#define CHARGE_INHIBIT_IPC_H
#include <stdio.h>
#include <string.h>
#include "ChargeInhibitSafety.h"

#define CI_LABEL "io.github.berkinefeavci.cellkeep.chargeinhibit"
#define CI_HELPER_PATH "/Library/PrivilegedHelperTools/" CI_LABEL
#define CI_SOCKET_PATH "/var/run/" CI_LABEL ".sock"
#define CI_STATE_DIR "/Library/Application Support/CellkeepChargeInhibit"
#define CI_CLIENT_FILE CI_STATE_DIR "/client"
#define CI_HELPER_VERSION 1

typedef enum { CI_CMD_INVALID = 0, CI_CMD_READ, CI_CMD_CAPABILITIES, CI_CMD_SET, CI_CMD_HEARTBEAT } CICommand;

static inline CICommand ci_parse_request(const char *line, CIState *state) {
    size_t length = strlen(line);
    if (length == 0 || length > 16 || line[length - 1] != '\n') return CI_CMD_INVALID;
    if (!strcmp(line, "R\n")) return CI_CMD_READ;
    if (!strcmp(line, "C\n")) return CI_CMD_CAPABILITIES;
    if (!strcmp(line, "H\n")) return CI_CMD_HEARTBEAT;
    if (length == 6 && line[0] == 'S' && line[1] == ' ' && (line[2] == '0' || line[2] == '1') && line[3] == ' ' &&
        (line[4] == '0' || line[4] == '1')) {
        state->chargingInhibited = line[2] - '0';
        state->adapterInhibited = line[4] - '0';
        return CI_CMD_SET;
    }
    return CI_CMD_INVALID;
}
#endif
