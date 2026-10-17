#ifndef LED_CONTROLLERS_H
#define LED_CONTROLLERS_H
#include <string.h>
// Bumped whenever the installed root helper must be replaced; the app compares `--version`.
// 3: a Developer ID helper answers only the app signed by its own team (ClientSignature.h).
#define LED_HELPER_VERSION 3
// Process names of other charge tools that may drive the MagSafe LED. Mirrors the running-process
// signals in ChargeControllerDetector.swift. Prefixes, because proc_name truncates long names.
static int isOtherControllerName(const char *name) {
    static const char *prefixes[] = { "AlDente", "me.mhaeuser.batterytoolkitd", "BatFi", "software.micropixels.BatFi" };
    for (size_t index = 0; index < sizeof(prefixes) / sizeof(prefixes[0]); index++)
        if (strncmp(name, prefixes[index], strlen(prefixes[index])) == 0) return 1;
    return strcmp(name, "batt") == 0;
}
#endif
