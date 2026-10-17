#include <sys/socket.h>
#include <sys/un.h>
#include <sys/wait.h>
#include <signal.h>
#include <errno.h>
#include "ClientSignature.h"
#define LED_SOCKET "/var/run/io.github.berkinefeavci.cellkeep.led.sock"
#define LED_HELPER "/Library/PrivilegedHelperTools/io.github.berkinefeavci.cellkeep.led"

static int authorizeUID(uid_t uid) {
    if (geteuid() != 0) return 4;
    // The state directory may not exist yet on a first install; it must be root-owned and not writable by others.
    if (mkdir("/Library/Application Support", 0755) && errno != EEXIST) return 4;
    if (mkdir(POLICY_DIR, 0755) && errno != EEXIST) return 4;
    struct stat directory;
    if (lstat(POLICY_DIR, &directory) || !S_ISDIR(directory.st_mode) || directory.st_uid != 0 || (directory.st_mode & 022)) return 4;
    int fd = open(POLICY_DIR "/client", O_CREAT | O_WRONLY | O_TRUNC | O_NOFOLLOW, 0600);
    if (fd < 0) return 4;
    int ok = write(fd, &uid, sizeof(uid)) == sizeof(uid) && !fsync(fd);
    close(fd);
    return ok ? 0 : 4;
}

static int trustedClient(int socketFD) {
    uid_t uid; gid_t gid;
    if (getpeereid(socketFD, &uid, &gid)) return 0;
    int fd = open(POLICY_DIR "/client", O_RDONLY | O_NOFOLLOW);
    if (fd < 0) return 0;
    struct stat st;
    uid_t expected;
    int valid = !fstat(fd, &st) && S_ISREG(st.st_mode) && st.st_uid == 0 && !(st.st_mode & 022) &&
        st.st_size == (off_t)sizeof(expected) && read(fd, &expected, sizeof(expected)) == sizeof(expected) && expected == uid;
    close(fd);
    return valid && cs_client_ok(socketFD);
}

static int openServer(void) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return -1;
    fcntl(fd, F_SETFD, FD_CLOEXEC);
    struct sockaddr_un address = {0};
    address.sun_family = AF_UNIX;
    strlcpy(address.sun_path, LED_SOCKET, sizeof(address.sun_path));
    unlink(LED_SOCKET); // Fixed root-owned /var/run endpoint only.
    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) || chmod(LED_SOCKET, 0666) || listen(fd, 8)) { close(fd); return -1; }
    signal(SIGPIPE, SIG_IGN);
    return fd;
}

// Only processes running as the registered user (UID written by --authorize-uid) can call this endpoint,
// and a Developer ID helper also requires the caller to be the app signed by its own team (ClientSignature.h).
// Commands map to fixed argv; neither shell strings nor arbitrary paths are accepted.
static void serveIPC(int server) {
    fd_set ready; FD_ZERO(&ready); FD_SET(server, &ready);
    struct timeval timeout = {5, 0};
    if (select(server + 1, &ready, NULL, NULL, &timeout) <= 0) return;
    int client = accept(server, NULL, NULL);
    if (client < 0) return;
    fcntl(client, F_SETFD, FD_CLOEXEC);
    struct timeval limit = {2, 0};
    setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &limit, sizeof(limit));
    if (!trustedClient(client)) { dprintf(client, "4\n"); close(client); return; }
    char request[96] = {0}; size_t length = 0;
    while (length < sizeof(request) - 1) {
        ssize_t n = read(client, request + length, 1);
        if (n != 1 || request[length++] == '\n') break;
    }
    if (!length || request[length - 1] != '\n') { close(client); return; }
    if (!strcmp(request, "PING\n")) { dprintf(client, "0\n"); close(client); return; }
    char *arguments[6] = {(char *)LED_HELPER, NULL, NULL, NULL, NULL, NULL};
    char modeText[8], startText[8], endText[8], extra;
    int mode, start, end, value;
    if (sscanf(request, "P %d %d %d %c", &mode, &start, &end, &extra) == 3 &&
        mode >= 0 && mode <= 2 && start >= 0 && start < 1440 && end >= 0 && end < 1440) {
        snprintf(modeText, sizeof(modeText), "%d", mode); snprintf(startText, sizeof(startText), "%d", start); snprintf(endText, sizeof(endText), "%d", end);
        arguments[1] = "--policy"; arguments[2] = modeText; arguments[3] = startText; arguments[4] = endText;
    } else if (sscanf(request, "W %d %c", &value, &extra) == 1 && (value == 0 || value == 1 || value == 3 || value == 4)) {
        arguments[1] = value == 0 ? "--set-system" : value == 1 ? "--set-off" : value == 3 ? "--set-green" : "--set-orange";
    } else { dprintf(client, "2\n"); close(client); return; }
    pid_t child = fork();
    if (child == 0) {
        int sink = open("/dev/null", O_RDWR);
        if (sink >= 0) { dup2(sink, STDOUT_FILENO); dup2(sink, STDERR_FILENO); }
        execv(LED_HELPER, arguments); _exit(127);
    }
    int result = 4, childStatus = 0;
    if (child > 0) {
        pid_t waited;
        do { waited = waitpid(child, &childStatus, 0); } while (waited < 0 && errno == EINTR);
        if (waited == child && WIFEXITED(childStatus)) result = WEXITSTATUS(childStatus);
    }
    dprintf(client, "%d\n", result); close(client);
}
