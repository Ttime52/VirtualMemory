#define _GNU_SOURCE

#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/types.h>
#include <unistd.h>

#define FILE_SIZE (64UL * 1024UL * 1024UL)
#define WRITE_BUFFER_SIZE (1024UL * 1024UL)

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

static int write_all(int fd, const unsigned char *buffer, size_t length)
{
    size_t written = 0;

    while (written < length) {
        ssize_t count = write(fd, buffer + written, length - written);

        if (count == -1) {
            if (errno == EINTR) {
                continue;
            }
            return -1;
        }

        if (count == 0) {
            errno = EIO;
            return -1;
        }

        written += (size_t)count;
    }

    return 0;
}

int main(void)
{
    char path[] = "/tmp/vm-major-XXXXXX";
    unsigned char buffer[WRITE_BUFFER_SIZE];
    volatile const unsigned char *mapping = NULL;
    struct rusage before;
    struct rusage after;
    unsigned long long checksum = 0;
    size_t offset;
    size_t pages_read = 0;
    long page_size;
    int fd = -1;
    int mapped = 0;
    int path_exists = 0;
    int result = 1;
    int advice_result;

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

    printf("Major page fault test process PID: %ld\n", (long)getpid());
    printf("System page size: %ld bytes\n", page_size);
    printf("Preparing a %lu-byte temporary file (64 MiB).\n", FILE_SIZE);

    fd = mkstemp(path);
    if (fd == -1) {
        perror("mkstemp");
        return 1;
    }
    path_exists = 1;

    /* Initialize real file contents so the mapping is not a sparse zero file. */
    for (offset = 0; offset < sizeof(buffer); ++offset) {
        buffer[offset] = (unsigned char)((offset * 131U + 17U) & 0xffU);
    }

    for (offset = 0; offset < FILE_SIZE; offset += sizeof(buffer)) {
        if (write_all(fd, buffer, sizeof(buffer)) == -1) {
            perror("write temporary file");
            goto cleanup;
        }
    }

    if (fdatasync(fd) == -1) {
        perror("fdatasync temporary file");
        goto cleanup;
    }

    /* This is advisory: the kernel may retain the file in its page cache. */
    advice_result = posix_fadvise(fd, 0, (off_t)FILE_SIZE, POSIX_FADV_DONTNEED);
    if (advice_result != 0) {
        fprintf(stderr, "posix_fadvise(DONTNEED): %s; continuing best-effort.\n",
                strerror(advice_result));
    }

    mapping = mmap(NULL, FILE_SIZE, PROT_READ, MAP_PRIVATE, fd, 0);
    if (mapping == MAP_FAILED) {
        perror("mmap temporary file");
        mapping = NULL;
        goto cleanup;
    }
    mapped = 1;

    if (madvise((void *)mapping, FILE_SIZE, MADV_RANDOM) == -1) {
        perror("madvise(MADV_RANDOM)");
        fprintf(stderr, "Continuing without the random-access hint.\n");
    }

    printf("File-backed mapping size: %lu bytes (64 MiB)\n", FILE_SIZE);
    printf("Temporary file: %s\n", path);
    puts("The test requested cache eviction; this is best-effort.");

    if (pause_for_enter("Before scanning the mapping: take a baseline snapshot now.") != 0) {
        goto cleanup;
    }

    if (getrusage(RUSAGE_SELF, &before) == -1) {
        perror("getrusage before file accesses");
        goto cleanup;
    }

    /* Volatile reads force one file-backed access per system page. */
    for (offset = 0; offset < FILE_SIZE; offset += (size_t)page_size) {
        checksum += mapping[offset];
        ++pages_read;
    }

    if (getrusage(RUSAGE_SELF, &after) == -1) {
        perror("getrusage after file accesses");
        goto cleanup;
    }

    printf("Read %zu pages; checksum: %llu\n", pages_read, checksum);
    printf("Page-fault counter deltas from getrusage(RUSAGE_SELF):\n");
    printf("  minor faults: %ld\n", after.ru_minflt - before.ru_minflt);
    printf("  major faults: %ld\n", after.ru_majflt - before.ru_majflt);
    if (after.ru_majflt > before.ru_majflt) {
        puts("Major page faults were observed during the scan.");
    } else {
        puts("No major page fault increase was observed during the scan.");
        puts("The file may have remained in cache; this run did not demonstrate major faults.");
    }

    if (pause_for_enter("After scanning: inspect /proc/<pid>/stat and the module snapshot now.") != 0) {
        goto cleanup;
    }

    result = 0;

cleanup:
    if (mapped && munmap((void *)mapping, FILE_SIZE) == -1) {
        perror("munmap file mapping");
        result = 1;
    }

    if (fd != -1 && close(fd) == -1) {
        perror("close temporary file");
        result = 1;
    }

    if (path_exists && unlink(path) == -1) {
        perror("unlink temporary file");
        result = 1;
    }

    return result;
}
