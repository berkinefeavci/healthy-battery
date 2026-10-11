// Caller check shared by the three root helpers (charge inhibit, power mode, MagSafe LED).
//
// On top of the "registered user id" check, a Developer ID helper answers only the Healthy Battery app
// signed by its own team: another program of the same user cannot drive the hardware through it.
// A local ad-hoc helper has no team and keeps the uid check alone. A team without a usable requirement
// refuses everyone (fail closed). The helper reads its own signature once at start; the install step has
// already pinned the copied helper to the app's Team ID (HelperInstallState.signatureCheckCommand).
//
// Include after <Security/Security.h>-capable headers; link with -framework Security -framework CoreFoundation.
#ifndef CLIENT_SIGNATURE_H
#define CLIENT_SIGNATURE_H
#include <CoreFoundation/CoreFoundation.h>
#include <Security/Security.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/un.h>

#define CS_APP_IDENTIFIER "io.github.berkinefeavci.cellkeep"

static SecRequirementRef csRequirement;
static int csMode; // 0 ad-hoc helper: uid only · 1 enforce · -1 broken: refuse

// The designated requirement a caller must satisfy. Team IDs are 10 upper-case letters/digits; anything else
// is refused so a malformed value can never widen the requirement.
static inline CFStringRef cs_requirement_text(CFTypeRef team) {
    if (!team || CFGetTypeID(team) != CFStringGetTypeID()) return NULL;
    CFStringRef value = (CFStringRef)team;
    if (CFStringGetLength(value) != 10) return NULL;
    for (CFIndex i = 0; i < 10; i++) {
        UniChar c = CFStringGetCharacterAtIndex(value, i);
        if (!((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))) return NULL;
    }
    return CFStringCreateWithFormat(NULL, NULL,
        CFSTR("identifier \"" CS_APP_IDENTIFIER "\" and anchor apple generic and certificate leaf[subject.OU] = \"%@\""), value);
}

static inline void cs_load_requirement(const char *tag) {
    SecCodeRef self = NULL; SecStaticCodeRef staticSelf = NULL; CFDictionaryRef info = NULL;
    csMode = -1;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &self) == errSecSuccess &&
        SecCodeCopyStaticCode(self, kSecCSDefaultFlags, &staticSelf) == errSecSuccess &&
        SecCodeCopySigningInformation(staticSelf, kSecCSSigningInformation, &info) == errSecSuccess) {
        CFTypeRef team = CFDictionaryGetValue(info, kSecCodeInfoTeamIdentifier);
        if (!team) csMode = 0;
        else {
            CFStringRef text = cs_requirement_text(team);
            if (text && SecRequirementCreateWithString(text, kSecCSDefaultFlags, &csRequirement) == errSecSuccess) csMode = 1;
            if (text) CFRelease(text);
        }
    }
    if (info) CFRelease(info);
    if (staticSelf) CFRelease(staticSelf);
    if (self) CFRelease(self);
    if (csMode < 0) fprintf(stderr, "%s: own signature unreadable; refusing all clients\n", tag);
}

static inline int cs_client_ok(int socketFD) {
    if (csMode == 0) return 1;
    if (csMode < 0 || !csRequirement) return 0;
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
        SecCodeCheckValidity(code, kSecCSDefaultFlags, csRequirement) == errSecSuccess;
    if (code) CFRelease(code);
    if (attributes) CFRelease(attributes);
    return ok;
}

// --self-test helper: the requirement text must compile for a well-formed team and be refused otherwise.
static inline int cs_self_test(void) {
    CFStringRef good = CFSTR("A7V9NP35W2");
    CFStringRef text = cs_requirement_text(good);
    SecRequirementRef requirement = NULL;
    int ok = text && SecRequirementCreateWithString(text, kSecCSDefaultFlags, &requirement) == errSecSuccess;
    if (requirement) CFRelease(requirement);
    if (text) CFRelease(text);
    if (!ok) return 1;
    CFStringRef bad[] = {CFSTR(""), CFSTR("a7v9np35w2"), CFSTR("A7V9NP35W2X"), CFSTR("A7V9NP35W\""), CFSTR("A7V9NP35W2\" or anchor")};
    for (size_t i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
        CFStringRef refused = cs_requirement_text(bad[i]);
        if (refused) { CFRelease(refused); return 1; }
    }
    return cs_requirement_text(NULL) == NULL ? 0 : 1;
}
#endif
