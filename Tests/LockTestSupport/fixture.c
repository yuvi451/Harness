#include "LockTestSupport.h"
#include <sys/file.h>
#include <sys/wait.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>

int harness_fork_hold_lock(const char *path, unsigned int microseconds) {
    int ready[2];
    if (microseconds > 5000000 || pipe(ready) != 0) return -1;
    pid_t child = fork();
    if (child < 0) { close(ready[0]); close(ready[1]); return -1; }
    if (child == 0) {
        close(ready[0]);
        int fd = open(path, O_RDWR | O_NOFOLLOW);
        if (fd < 0 || flock(fd, LOCK_EX) != 0) _exit(20);
        char signal = 'r';
        if (write(ready[1], &signal, 1) != 1) _exit(21);
        close(ready[1]);
        usleep(microseconds);
        if (flock(fd, LOCK_UN) != 0) _exit(22);
        close(fd); _exit(0);
    }
    close(ready[1]);
    char signal;
    ssize_t count;
    do { count = read(ready[0], &signal, 1); } while (count < 0 && errno == EINTR);
    close(ready[0]);
    if (count != 1) { int status; waitpid(child, &status, 0); return -1; }
    return child;
}

int harness_wait_for_lock_child(int pid) {
    int status = 0;
    pid_t waited;
    do { waited = waitpid(pid, &status, 0); } while (waited < 0 && errno == EINTR);
    return waited == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? 0 : -1;
}

// Child performs syscall-only append; no Swift runtime after fork.
int harness_fork_append(const char *path, const char *line, unsigned long length, int workers, int records) {
    pid_t pids[8];
    if (workers < 1 || workers > 8) return -1;
    for (int w = 0; w < workers; w++) {
        pids[w] = fork();
        if (pids[w] < 0) return -2;
        if (pids[w] == 0) {
            int fd = open(path, O_WRONLY | O_APPEND | O_NOFOLLOW, 0600);
            if (fd < 0) _exit(10);
            for (int n = 0; n < records; n++) {
                int result;
                do { result = flock(fd, LOCK_EX); } while (result < 0 && errno == EINTR);
                if (result < 0) _exit(11);
                for (unsigned long i = 0; i < length; i++) {
                    ssize_t count;
                    do { count = write(fd, line + i, 1); } while (count < 0 && errno == EINTR);
                    if (count != 1) _exit(12);
                }
                if (flock(fd, LOCK_UN) != 0) _exit(13);
            }
            close(fd); _exit(0);
        }
    }
    int failed = 0;
    for (int w = 0; w < workers; w++) {
        int status = 0;
        if (waitpid(pids[w], &status, 0) != pids[w] || !WIFEXITED(status) || WEXITSTATUS(status)) failed = 1;
    }
    return failed;
}
