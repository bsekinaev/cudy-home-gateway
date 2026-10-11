/* Linux foreground Xray ownership primitive. Not installed or exposed by Gateway.
 * No PID lookup, shell, provider, MAIN, UCI, nft or service restart interface.
 * Target activation requires a separately audited config/budget adapter. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <linux/filter.h>
#include <linux/audit.h>
#include <linux/sched.h>
#include <linux/seccomp.h>
#include <signal.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/prctl.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef HG_TEST_BUILD
#define XRAY_PATH "/usr/bin/xray"
#define RUN_BASE "/tmp/home-gateway/vtest-runs"
#else
#ifndef XRAY_PATH
#error Test build requires fixed fixture paths
#endif
#endif

static volatile sig_atomic_t cancelled;
static void cancel(int sig) { (void)sig; cancelled = 1; }
static double monotonic(void) {
    struct timespec t;
    if (clock_gettime(CLOCK_MONOTONIC, &t)) _exit(70);
    return t.tv_sec + t.tv_nsec / 1e9;
}
static int fixed(int rc, const char *status) {
    printf("{\"schema_version\":1,\"status\":\"%s\"}\n", status);
    return rc;
}
static int private_fd(int fd, mode_t kind, mode_t mode) {
    struct stat st;
    return fd >= 0 && fstat(fd, &st) == 0 && (st.st_mode & S_IFMT) == kind &&
           st.st_uid == geteuid() && (st.st_mode & 07777) == mode;
}
static int trusted_directory(const char *path) {
    char copy[1024];
    if (strlen(path) >= sizeof(copy) || path[0] != '/') return -1;
    strcpy(copy, path);
    int fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat root;
    if (fd < 0 || fstat(fd, &root) || root.st_uid != 0 || (root.st_mode & 0022)) {
        if (fd >= 0) close(fd);
        return -1;
    }
    char *save = NULL;
    for (char *part = strtok_r(copy, "/", &save); part; part = strtok_r(NULL, "/", &save)) {
        if (!strcmp(part, ".") || !strcmp(part, "..")) { close(fd); return -1; }
        int next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
        struct stat st;
        close(fd);
        if (next < 0 || fstat(next, &st) || (st.st_uid != 0 && st.st_uid != geteuid()) ||
            ((st.st_mode & 0022) && !(st.st_mode & S_ISVTX))) { if (next >= 0) close(next); return -1; }
        fd = next;
    }
    return fd;
}
static int limit(int resource, rlim_t maximum) {
    struct rlimit lim = {maximum, maximum};
    return setrlimit(resource, &lim);
}
static int no_process_forks(void) {
    /* Supported Linux architectures have clone flags in args[0].
     * clone3 cannot inspect pointed-to flags in classic BPF: ENOSYS requests
     * the ordinary clone fallback. Only CLONE_THREAD is permitted. */
#if !defined(__x86_64__) && !defined(__aarch64__) && !defined(__arm__)
#error Unsupported syscall ABI: fail closed until audited
#endif
#if defined(__x86_64__)
#define NATIVE_AUDIT_ARCH AUDIT_ARCH_X86_64
#elif defined(__aarch64__)
#define NATIVE_AUDIT_ARCH AUDIT_ARCH_AARCH64
#elif defined(__arm__) && !defined(__ARMEB__)
#define NATIVE_AUDIT_ARCH AUDIT_ARCH_ARM
#else
#error Unsupported byte order
#endif
    struct sock_filter filter[] = {
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, arch)),
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, NATIVE_AUDIT_ARCH, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, nr)),
#ifdef __x86_64__
        BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, 0x40000000, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_KILL_PROCESS),
#endif
#ifdef __NR_fork
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_fork, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
#endif
#ifdef __NR_vfork
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_vfork, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
#endif
#ifdef __NR_clone3
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone3, 0, 1),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | ENOSYS),
#endif
        BPF_JUMP(BPF_JMP | BPF_JEQ | BPF_K, __NR_clone, 0, 3),
        BPF_STMT(BPF_LD | BPF_W | BPF_ABS, offsetof(struct seccomp_data, args[0])),
        BPF_JUMP(BPF_JMP | BPF_JSET | BPF_K, CLONE_THREAD, 1, 0),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ERRNO | EPERM),
        BPF_STMT(BPF_RET | BPF_K, SECCOMP_RET_ALLOW)
    };
    struct sock_fprog program = {sizeof(filter) / sizeof(filter[0]), filter};
    return prctl(PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0) ||
           prctl(PR_SET_SECCOMP, SECCOMP_MODE_FILTER, &program);
}
int main(int argc, char **argv) {
    umask(077);
#ifndef HG_TEST_BUILD
    if (geteuid() != 0 || !getenv("HG_VTEST_NATIVE_AUTHORIZED") ||
        strcmp(getenv("HG_VTEST_NATIVE_AUTHORIZED"), "1")) return fixed(77, "DISABLED");
#endif
    if (argc != 3 || strlen(argv[1]) != 32 || strspn(argv[1], "0123456789abcdef") != 32 ||
        !*argv[2] || strlen(argv[2]) > 3 || strspn(argv[2], "0123456789") != strlen(argv[2]))
        return fixed(2, "USAGE");
    unsigned seconds = (unsigned)strtoul(argv[2], NULL, 10);
    if (!seconds || seconds > 600) return fixed(2, "USAGE");
    int base = trusted_directory(RUN_BASE);
    if (!private_fd(base, S_IFDIR, 0700)) return fixed(70, "UNSAFE_RUN_DIRECTORY");
    int guard = openat(base, "supervisor.lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (!private_fd(guard, S_IFREG, 0600)) return fixed(70, "UNSAFE_LOCK");
    if (flock(guard, LOCK_EX | LOCK_NB)) return fixed(73, "BUSY");
    int directory = openat(base, argv[1], O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    if (!private_fd(directory, S_IFDIR, 0700)) return fixed(70, "UNSAFE_RUN_DIRECTORY");
    int config = openat(directory, "config.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK);
    struct stat cs;
    if (!private_fd(config, S_IFREG, 0600) || fstat(config, &cs) || cs.st_nlink != 1 || cs.st_size <= 0 || cs.st_size > 1048576)
        return fixed(70, "UNSAFE_CONFIG");
    char binary_parent[1024];
    if (strlen(XRAY_PATH) >= sizeof(binary_parent)) return fixed(70, "UNSAFE_BINARY");
    strcpy(binary_parent, XRAY_PATH);
    char *binary_name = strrchr(binary_parent, '/');
    if (!binary_name || !binary_name[1]) return fixed(70, "UNSAFE_BINARY");
    *binary_name++ = '\0';
    int executable_dir = trusted_directory(binary_parent);
    int binary = openat(executable_dir, binary_name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
    if (executable_dir >= 0) close(executable_dir);
    struct stat bs;
    unsigned char magic[4];
    if (binary < 0 || fstat(binary, &bs) || !S_ISREG(bs.st_mode) || bs.st_uid != geteuid() ||
        (bs.st_mode & 07022) || !(bs.st_mode & 0100) || pread(binary, magic, 4, 0) != 4 ||
        memcmp(magic, "\177ELF", 4)) return fixed(70, "UNSAFE_BINARY");
    struct sigaction sa = {.sa_handler = cancel};
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGTERM, &sa, NULL) || sigaction(SIGINT, &sa, NULL)) return fixed(70, "SIGNAL_FAILED");
    struct stat prior_active;
    if (fstatat(base, "active", &prior_active, AT_SYMLINK_NOFOLLOW) == 0)
        return fixed(70, "RECOVERY_REQUIRED");
    if (errno != ENOENT) return fixed(70, "UNSAFE_FENCE");
    struct stat prior_intent;
    if (fstatat(directory, "execution.intent", &prior_intent, AT_SYMLINK_NOFOLLOW) == 0)
        return fixed(75, "RUN_ALREADY_CONSUMED");
    if (errno != ENOENT) return fixed(70, "UNSAFE_INTENT");
    /* Global RAM fence precedes durable run consumption and fork. A crash
     * leaves it in place; a new engine cannot overlap an orphan's death. */
    int active = openat(base, "active", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (active < 0) return fixed(70, "RECOVERY_REQUIRED");
    if (write(active, argv[1], 32) != 32 || fsync(active) || fsync(base)) return fixed(70, "WRITE_FAILED");
    close(active);
    int intent = openat(directory, "execution.intent", O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (intent < 0) return fixed(75, "RUN_ALREADY_CONSUMED");
    if (write(intent, "EXECUTING\n", 10) != 10 || fsync(intent) || fsync(directory)) return fixed(70, "WRITE_FAILED");
    close(intent);
    pid_t parent = getpid(), child = fork();
    if (child < 0) return fixed(70, "FORK_FAILED");
    if (child == 0) {
        /* Close parent-death race before touching the executable. */
        if (prctl(PR_SET_PDEATHSIG, SIGKILL) || getppid() != parent) _exit(70);
        if (setsid() < 0 || limit(RLIMIT_CORE, 0) || limit(RLIMIT_NOFILE, 256) ||
            limit(RLIMIT_FSIZE, 1048576) || limit(RLIMIT_CPU, seconds + 2)) _exit(70);
        int config_copy = fcntl(config, F_DUPFD_CLOEXEC, 5);
        int binary_copy = fcntl(binary, F_DUPFD_CLOEXEC, 5);
        if (config_copy < 0 || binary_copy < 0 || dup2(config_copy, 3) < 0 || dup2(binary_copy, 4) < 0 ||
            fcntl(4, F_SETFD, FD_CLOEXEC)) _exit(70);
#ifdef __NR_close_range
        if (syscall(__NR_close_range, 5U, ~0U, 0U)) _exit(70);
#else
#error close_range support is required; no inherited-descriptor fallback
#endif
        int nullfd = open("/dev/null", O_RDWR);
        if (nullfd < 0 || dup2(nullfd, 0) < 0 || dup2(nullfd, 1) < 0 || dup2(nullfd, 2) < 0) _exit(70);
        if (nullfd > 2) close(nullfd);
        config = 3; binary = 4;
        if (no_process_forks()) _exit(70); /* no insecure fallback */
        char config_path[64];
        snprintf(config_path, sizeof(config_path), "/proc/self/fd/%d", config);
        char *args[] = {"xray", "run", "-c", config_path, NULL};
        char *env[] = {"PATH=/usr/bin:/bin", "LANG=C", NULL};
        fexecve(binary, args, env);
        _exit(70);
    }
    close(config); close(binary); close(directory);
    double deadline = monotonic() + seconds, kill_at = 0;
    int status, stopping = 0, why = 0;
    for (;;) {
        /* The child remains ours and unreaped until this call returns its PID.
         * Never signal any PID after it has been reaped: no PID reuse race. */
        pid_t ended = waitpid(child, &status, WNOHANG);
        if (ended == child) break;
        if (ended < 0 && errno != EINTR) return fixed(70, "WAIT_FAILED");
        double now = monotonic();
        if (!stopping && (cancelled || now >= deadline)) {
            why = cancelled ? 130 : 124;
            kill(child, SIGTERM); stopping = 1; kill_at = now + 1;
        } else if (stopping == 1 && now >= kill_at) {
            kill(child, SIGKILL); stopping = 2;
        }
        struct timespec pause = {0, 10000000};
        nanosleep(&pause, NULL);
    }
    if (unlinkat(base, "active", 0) || fsync(base)) return fixed(70, "WRITE_FAILED");
    close(base); close(guard);
    if (why) return fixed(why, why == 124 ? "TIMEOUT" : "CANCELLED");
    return WIFEXITED(status) && WEXITSTATUS(status) == 0 ? fixed(0, "DONE") : fixed(70, "FAILED");
}
