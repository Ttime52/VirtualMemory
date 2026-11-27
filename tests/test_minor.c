#define _GNU_SOURCE

#include <errno.h>
#include <stdio.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <unistd.h>

#define ALLOCATION_SIZE (64UL * 1024UL * 1024UL)

static int pause_for_enter(const char *message)
{
    int ch;

    printf("\n%s\nPress Enter to continue... ", message);
    if (fflush(stdout) == EOF) {
        perror("fflush");
        return -1;
    }

    while ((ch = getchar()) != '\n' && ch != EOF) {
    }

    if (ferror(stdin)) {
        perror("getchar");
        return -1;
    }

    if (ch == EOF) {
        fprintf(stderr, "Input closed before the test could continue.\n");
        return -1;
    }

    return 0;
}

int main(void)
{
    volatile unsigned char *memory = NULL;
    struct rusage before;
    struct rusage after;
    long page_size;
    size_t offset;
    size_t pages_touched = 0;
    unsigned long checksum = 0;
    int mapped = 0;
    int result = 0;

    errno = 0;
    page_size = sysconf(_SC_PAGESIZE);
    if (page_size <= 0) {
        if (errno != 0) {
            perror("sysconf(_SC_PAGESIZE)");
        } else {
            fprintf(stderr, "sysconf(_SC_PAGESIZE) returned an invalid value.\n");
        }
        return 1;
    }

    printf("Minor page fault test process PID: %ld\n", (long)getpid());
    printf("System page size: %ld bytes\n", page_size);
    printf("Anonymous allocation size: %lu bytes (64 MiB)\n", ALLOCATION_SIZE);

    memory = mmap(NULL, ALLOCATION_SIZE, PROT_READ | PROT_WRITE,
                  MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (memory == MAP_FAILED) {
        perror("mmap");
        return 1;
    }
    mapped = 1;
    puts("Anonymous memory allocated; no pages have been deliberately touched yet.");

    if (pause_for_enter("Before touching pages: inspect the process now.") != 0) {
        result = 1;
        goto cleanup;
    }

    if (getrusage(RUSAGE_SELF, &before) == -1) {
        perror("getrusage before page accesses");
        result = 1;
        goto cleanup;
    }

    /* Volatile loads and stores keep one access per system page observable. */
    for (offset = 0; offset < ALLOCATION_SIZE; offset += (size_t)page_size) {
        unsigned char value = (unsigned char)((pages_touched % 251U) + 1U);

        memory[offset] = value;
        checksum += memory[offset];
        ++pages_touched;
    }

    if (getrusage(RUSAGE_SELF, &after) == -1) {
        perror("getrusage after page accesses");
        result = 1;
        goto cleanup;
    }

    printf("Touched %zu pages; checksum: %lu\n", pages_touched, checksum);
    printf("Page-fault counter deltas from getrusage(RUSAGE_SELF):\n");
    printf("  minor faults: %ld\n", after.ru_minflt - before.ru_minflt);
    printf("  major faults: %ld\n", after.ru_majflt - before.ru_majflt);

    if (pause_for_enter("After page accesses: inspect /proc/<pid>/status and stat now.") != 0) {
        result = 1;
    }

cleanup:
    if (mapped && munmap((void *)memory, ALLOCATION_SIZE) == -1) {
        perror("munmap");
        result = 1;
    }

    return result;
}
