// Narrow ACLC-only helper. Built into the app, installed root-owned after authorization.
// Never writes any charge-control key; output selection is a fixed allowlist.
#include <IOKit/IOKitLib.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <stdlib.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <sys/file.h>
#include <time.h>
#include <libproc.h>
#include "LEDTimeWindow.h"
#include "LEDControllers.h"

#define POLICY_DIR "/Library/Application Support/CellkeepLED"
#define POLICY_FILE POLICY_DIR "/policy"
#include "LEDIPC.h"
static int otherControllerRunning(void) {
    pid_t processes[8192];
    int bytes = proc_listpids(PROC_ALL_PIDS, 0, processes, sizeof(processes));
    if (bytes <= 0 || bytes >= (int)sizeof(processes)) return 1;
    for (int index = 0; index < bytes / (int)sizeof(pid_t); index++) {
        char name[256] = {0};
        if (proc_name(processes[index], name, sizeof(name)) > 0 && isOtherControllerName(name)) return 1;
    }
    return 0;
}
static int lockController(void) {
    int fd = open("/var/run/io.github.berkinefeavci.cellkeep.led.lock", O_CREAT | O_RDWR | O_NOFOLLOW, 0600);
    struct stat st;
    if (fd < 0) return -1;
    if (fstat(fd, &st) || st.st_uid != 0 || !S_ISREG(st.st_mode) || (st.st_mode & 022) || flock(fd, LOCK_EX)) { close(fd); return -1; }
    return fd;
}
// mode: 0 system, 1 always off, 2 daily time window, 3 manual (daemon idle).
static int readPolicy(int *mode, int *start, int *end) {
    int fd = open(POLICY_FILE, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 0;
    struct stat st;
    if (fstat(fd, &st) || st.st_uid != 0 || !S_ISREG(st.st_mode) || (st.st_mode & 022)) { close(fd); return 0; }
    FILE *file = fdopen(fd, "r");
    if (!file) { close(fd); return 0; }
    int valid = fscanf(file, "%d %d %d", mode, start, end) == 3;
    fclose(file);
    return valid && *mode >= 0 && *mode <= 3 && *start >= 0 && *start < 1440 && *end >= 0 && *end < 1440;
}

static int savePolicy(int mode, int start, int end) {
    if (geteuid() != 0) return 0;
    mkdir(POLICY_DIR, 0755);
    struct stat st;
    if (lstat(POLICY_DIR, &st) || !S_ISDIR(st.st_mode) || st.st_uid != 0 || (st.st_mode & 022)) return 0;
    char temporary[] = POLICY_DIR "/policy.XXXXXX";
    int fd = mkstemp(temporary);
    if (fd < 0) return 0;
    int ok = dprintf(fd, "%d %d %d\n", mode, start, end) > 0;
    ok = !fchmod(fd, 0644) && !fsync(fd) && ok;
    close(fd);
    if (ok) ok = rename(temporary, POLICY_FILE) == 0;
    if (!ok) unlink(temporary);
    return ok;
}

static io_connect_t connection = 0;

static int call(uint8_t command, uint8_t size, uint8_t value, uint8_t output[80]) {
    uint8_t input[80] = {0};
    // SMC key is a four-character big-endian code in a little-endian UInt32.
    memcpy(input, "CLCA", 4);
    input[28] = size;
    input[42] = command;
    input[48] = value;
    size_t outputSize = 80;
    memset(output, 0, 80);
    kern_return_t result = IOConnectCallStructMethod(connection, 2, input, 80, output, &outputSize);
    if (result != KERN_SUCCESS || outputSize != 80 || output[40] != 0) {
        fprintf(stderr, "SMC command %u: transport=0x%08x size=%zu result=0x%02x\n",
                command, result, outputSize, output[40]);
        return 0;
    }
    return 1;
}

static int readLED(uint8_t *value) {
    uint8_t response[80];
    if (!call(5, 1, 0, response)) return 0;
    *value = response[48];
    return 1;
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--version")) { printf("%d\n", LED_HELPER_VERSION); return 0; }
    if (argc == 2 && !strcmp(argv[1], "--self-test")) {
        if (cs_self_test()) return 1;
        puts("LED helper: caller-requirement assertions passed; no SMC access.");
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "--authorize-uid")) {
        char *tail; long uid = strtol(argv[2], &tail, 10);
        return *argv[2] && !*tail && uid >= 0 && uid <= INT_MAX ? authorizeUID((uid_t)uid) : 2;
    }
    if (argc == 5 && strcmp(argv[1], "--policy") == 0) {
        char *tail1, *tail2, *tail3;
        long mode = strtol(argv[2], &tail1, 10), start = strtol(argv[3], &tail2, 10), end = strtol(argv[4], &tail3, 10);
        if (!*argv[2] || !*argv[3] || !*argv[4] || *tail1 || *tail2 || *tail3 || mode < 0 || mode > 3 || start < 0 || start >= 1440 || end < 0 || end >= 1440) return 2;
        if (geteuid() != 0) return 4;
        int lock = lockController();
        if (lock < 0) return 4;
        int result = savePolicy((int)mode, (int)start, (int)end) ? 0 : 4;
        close(lock);
        return result;
    }
    int daemon = argc == 2 && strcmp(argv[1], "--daemon") == 0;
    int readOnly = argc == 2 && strcmp(argv[1], "--read") == 0;
    int restoreGreen = argc == 2 && strcmp(argv[1], "--restore-03") == 0;
    int sameValue = argc == 2 && strcmp(argv[1], "--same-value-write") == 0;
    int setSystem = argc == 2 && strcmp(argv[1], "--set-system") == 0;
    int setGreen = argc == 2 && strcmp(argv[1], "--set-green") == 0;
    int setOrange = argc == 2 && strcmp(argv[1], "--set-orange") == 0;
    int setOff = argc == 2 && strcmp(argv[1], "--set-off") == 0;
    if (argc != 2 || (!daemon && !readOnly && !restoreGreen && !sameValue &&
                      !setSystem && !setGreen && !setOrange && !setOff)) {
        fprintf(stderr, "Usage: magsafe-led-probe --read | --same-value-write | --restore-03 | --set-system/green/orange/off\n");
        return 2;
    }
    if (!readOnly && !sameValue && geteuid() != 0) {
        fprintf(stderr, "LED changes require administrator authorization\n");
        return 4;
    }
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) { fprintf(stderr, "AppleSMC unavailable\n"); return 3; }
    kern_return_t opened = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    if (opened != KERN_SUCCESS) { fprintf(stderr, "AppleSMC open: 0x%08x\n", opened); return 3; }

    int status = 3;
    uint8_t info[80], value[80], after[80];
    if (!call(9, 0, 0, info)) goto done;
    // SMC reports data size little-endian and type reversed in this ABI.
    if (info[28] != 1 || info[29] || info[30] || info[31] ||
        memcmp(info + 32, " 8iu", 4) != 0) {
        fprintf(stderr, "ACLC is not ui8 size 1; refusing write\n");
        goto done;
    }
    if (!call(5, 1, 0, value)) goto done;
    uint8_t baseline = value[48];
    printf("ACLC baseline: %02x\n", baseline);
    fflush(stdout);
    if (readOnly) { status = 0; goto done; }
    if (baseline != 3 && baseline != 4 && baseline != 1 && baseline != 0) {
        fprintf(stderr, "Unrecognized ACLC value; refusing write\n");
        goto done;
    }
    if (daemon) {
        cs_load_requirement("led");
        int server = openServer();
        if (server < 0) return 4;
        int previousDesired = -1;
        for (;;) {
            int lock = lockController();
            if (lock < 0) return 4;
            int mode, start, end;
            if (!readPolicy(&mode, &start, &end)) { close(lock); serveIPC(server); continue; }
            if (mode == 3) { previousDesired = -1; close(lock); serveIPC(server); continue; }
            if (otherControllerRunning()) { previousDesired = -1; close(lock); serveIPC(server); continue; }
            time_t now = time(NULL);
            struct tm local;
            tzset();
            localtime_r(&now, &local);
            int desired = mode == 1 || (mode == 2 && ledWindowContains(local.tm_hour * 60 + local.tm_min, start, end)) ? 1 : 0;
            uint8_t current;
            if (!readLED(&current)) { close(lock); IOServiceClose(connection); return 3; }
            if (current != 0 && current != 1 && current != 3 && current != 4) { close(lock); serveIPC(server); continue; }
            // System mode may read back a color; hand ownership back once per transition.
            if ((desired == 1 && current != 1) || desired != previousDesired) {
                if (call(6, 1, (uint8_t)desired, after)) previousDesired = desired;
            }
            close(lock);
            serveIPC(server);
        }
    }
    // Manual tests pause automation explicitly so two owners never race.
    if (!sameValue && otherControllerRunning()) { status = 4; goto done; }
    if (!sameValue && lockController() < 0) { status = 4; goto done; }
    if (!sameValue && !savePolicy(3, 0, 0)) { status = 4; goto done; }
    if (restoreGreen) {
        if (baseline != 3 && baseline != 4 && baseline != 1) {
            fprintf(stderr, "Unexpected value; refusing restoration write\n");
            status = 6;
            goto done;
        }
        if (baseline != 3 && !call(6, 1, 3, after)) {
            status = 7;
            goto done;
        }
        status = 8;
        for (int attempt = 0; attempt < 8; attempt++) {
            sleep(1);
            uint8_t observed;
            if (!readLED(&observed)) break;
            printf("ACLC restoration sample %d: %02x\n", attempt + 1, observed);
            fflush(stdout);
            if (observed == 3 && attempt >= 2) status = 0;
            else if (observed != 3) status = 8;
        }
        goto done;
    }
    if (!sameValue) {
        uint8_t requested = setSystem ? 0 : setGreen ? 3 : setOrange ? 4 : 1;
        if (baseline != requested && !call(6, 1, requested, after)) {
            status = 7;
            goto done;
        }
        // The physical controller can apply a successful command seconds after
        // the first read. Require eight settled samples, never instant success.
        int consecutive = 0;
        status = 8;
        for (int attempt = 0; attempt < 16; attempt++) {
            sleep(1);
            uint8_t observed;
            if (!readLED(&observed)) break;
            printf("ACLC sample %d: %02x\n", attempt + 1, observed);
            fflush(stdout);
            consecutive = observed == requested ? consecutive + 1 : 0;
            if (consecutive >= 8) { status = 0; break; }
        }
        goto done;
    }
    // First test only whether this process may write. It re-sends the exact
    // value just read, so no color change is requested.
    if (!call(6, 1, baseline, after)) {
        fprintf(stderr, "Same-value write denied or failed; no color test attempted\n");
        status = 4;
        goto done;
    }
    if (!call(5, 1, 0, after)) goto done;
    printf("ACLC readback: %02x\n", after[48]);
    status = after[48] == baseline ? 0 : 5;
    if (status) {
        fprintf(stderr, "Readback differs from baseline; stop and inspect manually\n");
        goto done;
    }
done:
    IOServiceClose(connection);
    return status;
}
