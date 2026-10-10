int harness_fork_append(const char *path, const char *line, unsigned long length, int workers, int records);
int harness_fork_hold_lock(const char *path, unsigned int microseconds);
int harness_wait_for_lock_child(int pid);
