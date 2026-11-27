#define _GNU_SOURCE

#include <errno.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>

#define MAPPING_SIZE (16UL * 1024UL * 1024UL)

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
    void *mapping = MAP_FAILED;
    int result = 0;

    printf("VMA test process PID: %ld\n", (long)getpid());
    printf("Mapping size: %lu bytes (16 MiB)\n", MAPPING_SIZE);

    if (pause_for_enter("Before mmap(): inspect the process baseline now.") != 0) {
        return 1;
    }

    mapping = mmap(NULL, MAPPING_SIZE, PROT_READ | PROT_WRITE,
                   MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (mapping == MAP_FAILED) {
        perror("mmap");
        return 1;
    }

    printf("mmap() created a mapping at %p (%lu bytes).\n",
           mapping, MAPPING_SIZE);
    printf("The mapping is reserved but its pages are not deliberately touched.\n");
    puts("Adjacent compatible mappings can be merged, so maps line counts may vary.");

    if (pause_for_enter("After mmap(): inspect /proc/<pid>/maps and status now.") != 0) {
        result = 1;
        goto cleanup;
    }

    if (munmap(mapping, MAPPING_SIZE) == -1) {
        perror("munmap");
        result = 1;
        goto cleanup;
    }
    mapping = MAP_FAILED;
    puts("munmap() released the mapping.");

    if (pause_for_enter("After munmap(): confirm the mapping is gone.") != 0) {
        result = 1;
    }

cleanup:
    if (mapping != MAP_FAILED && munmap(mapping, MAPPING_SIZE) == -1) {
        perror("munmap during cleanup");
        result = 1;
    }

    return result;
}
