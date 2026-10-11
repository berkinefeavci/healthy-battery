#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <unistd.h>
#include "ClientSignature.h"

// Bumped whenever the installed root helper must be replaced; the app compares `--version`.
// 3: a Developer ID helper answers only the app signed by its own team (ClientSignature.h).
#define POWER_MODE_HELPER_VERSION 3

#define HELPER_PATH "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.powermode"
#define SOCKET_PATH "/var/run/io.github.berkinefeavci.cellkeep.powermode.sock"
#define STATE_DIR "/Library/Application Support/CellkeepPowerMode"
#define CLIENT_FILE STATE_DIR "/client"

static int valid_mode(int mode) { return mode >= 0 && mode <= 2; }
static int valid_source(char source) { return source == 'A' || source == 'B' || source == 'C'; }
static char *source_flag(char source) {
    if (source == 'B') return "-b";
    if (source == 'C') return "-c";
    if (source == 'A') return "-a";
    return NULL;
}

static int valid_request(const char *request, char *source, int *mode) {
    char extra;
    return sscanf(request, "M %c %d %c", source, mode, &extra) == 2 && valid_source(*source) && valid_mode(*mode);
}

static int authorize_uid(uid_t uid) {
    if (geteuid() != 0) return 4;
    if (mkdir("/Library/Application Support", 0755) && errno != EEXIST) return 4;
    if (mkdir(STATE_DIR, 0755) && errno != EEXIST) return 4;
    struct stat state;
    if (lstat(STATE_DIR, &state) || !S_ISDIR(state.st_mode) || state.st_uid != 0 || (state.st_mode & 022)) return 4;
    int fd = open(CLIENT_FILE, O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0) return 4;
    int result = write(fd, &uid, sizeof(uid)) == sizeof(uid) && !fsync(fd) ? 0 : 4;
    close(fd);
    return result;
}

static int trusted_client(int socket_fd) {
    uid_t uid = 0, gid = 0, expected = 0;
    if (getpeereid(socket_fd, &uid, &gid)) return 0;
    int fd = open(CLIENT_FILE, O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 0;
    struct stat state;
    int trusted = !fstat(fd, &state) && S_ISREG(state.st_mode) && state.st_uid == 0 && !(state.st_mode & 022) &&
        state.st_size == (off_t)sizeof(expected) && read(fd, &expected, sizeof(expected)) == sizeof(expected) && expected == uid;
    close(fd);
    return trusted && cs_client_ok(socket_fd);
}

static int apply_mode(char source, int mode) {
    if (geteuid() != 0 || !valid_source(source) || !valid_mode(mode)) return 4;
    char *flag = source_flag(source);
    char mode_text[2] = {(char)('0' + mode), '\0'};
    char *arguments[] = {"/usr/bin/pmset", flag, "powermode", mode_text, NULL};
    pid_t child = fork();
    if (child == 0) {
        int sink = open("/dev/null", O_RDWR);
        if (sink >= 0) { dup2(sink, STDOUT_FILENO); dup2(sink, STDERR_FILENO); }
        execv(arguments[0], arguments);
        _exit(127);
    }
    int status = 4;
    if (child > 0 && waitpid(child, &status, 0) == child && WIFEXITED(status)) return WEXITSTATUS(status);
    return 4;
}

static int open_server(void) {
    int server = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server < 0) return -1;
    fcntl(server, F_SETFD, FD_CLOEXEC);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    if (strlen(SOCKET_PATH) >= sizeof(address.sun_path)) { close(server); return -1; }
    memcpy(address.sun_path, SOCKET_PATH, strlen(SOCKET_PATH) + 1);
    unlink(SOCKET_PATH);
    if (bind(server, (struct sockaddr *)&address, sizeof(address)) || chmod(SOCKET_PATH, 0666) || listen(server, 4)) {
        close(server); return -1;
    }
    signal(SIGPIPE, SIG_IGN);
    return server;
}

static void serve(int server) {
    int client = accept(server, NULL, NULL);
    if (client < 0) return;
    fcntl(client, F_SETFD, FD_CLOEXEC);
    struct timeval limit = {2, 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
    if (!trusted_client(client)) { dprintf(client, "4\n"); close(client); return; }
    char request[8] = {0};
    ssize_t count = read(client, request, sizeof(request) - 1);
    char source = '\0';
    int mode = -1;
    int result = count > 0 && valid_request(request, &source, &mode) ? apply_mode(source, mode) : 2;
    dprintf(client, "%d\n", result);
    close(client);
}

int main(int argc, char **argv) {
    if (argc == 2 && !strcmp(argv[1], "--version")) {
        printf("%d\n", POWER_MODE_HELPER_VERSION);
        return 0;
    }
    if (argc == 2 && !strcmp(argv[1], "--self-test")) {
        char source = '\0';
        int mode = -1;
        if (!valid_request("M B 0\n", &source, &mode) || source != 'B' || mode != 0 ||
            !valid_request("M C 2\n", &source, &mode) || source != 'C' || mode != 2 ||
            !valid_request("M A 1\n", &source, &mode) || source != 'A' || mode != 1 ||
            valid_request("M X 1\n", &source, &mode) || valid_request("M B 3\n", &source, &mode) ||
            valid_request("M 1\n", &source, &mode) || valid_request("M B 1 extra\n", &source, &mode) ||
            strcmp(source_flag('B'), "-b") || strcmp(source_flag('C'), "-c") ||
            strcmp(source_flag('A'), "-a") || source_flag('X')) return 1;
        if (cs_self_test()) return 1;
        puts("Power mode helper: fixed allowlist and caller-requirement assertions passed; no system write.");
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "--authorize-uid")) {
        char *tail = NULL;
        long uid = strtol(argv[2], &tail, 10);
        return *argv[2] && !*tail && uid >= 0 && uid <= INT_MAX ? authorize_uid((uid_t)uid) : 2;
    }
    if (argc != 2 || strcmp(argv[1], "--daemon") || geteuid() != 0) return 2;
    cs_load_requirement("power-mode");
    int server = open_server();
    if (server < 0) return 4;
    for (;;) serve(server);
}
