#include "streams.h"

#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #expr); exit(1); \
} } while (0)

enum { stream_count = 4096 };
static struct ArrowArrayStream sources[stream_count];
static pthread_mutex_t start = PTHREAD_MUTEX_INITIALIZER;

static int schema(struct ArrowArrayStream *stream, struct ArrowSchema *out) {
    (void)stream; (void)out;
    return ENOSYS;
}
static int next(struct ArrowArrayStream *stream, struct ArrowArray *out) {
    (void)stream;
    *out = (struct ArrowArray){0};
    return 0;
}
static const char *last_error(struct ArrowArrayStream *stream) {
    (void)stream;
    return NULL;
}
static void release(struct ArrowArrayStream *stream) { stream->release = NULL; }

static void *put_all(void *arg) {
    uint32_t *ids = arg;
    pthread_mutex_lock(&start);
    pthread_mutex_unlock(&start);
    for (size_t i = 0; i < stream_count; ++i) {
        int status = bd_stream_put(&sources[i], &ids[i]);
        CHECK(!status || status == EINVAL);
        if (status) ids[i] = 0;
    }
    return NULL;
}

int main(void) {
    for (size_t i = 0; i < stream_count; ++i)
        sources[i] = (struct ArrowArrayStream){schema, next, last_error, release, &sources[i]};

    /* Two callers try to move each source. Exactly one may own a token. */
    uint32_t ids[2][stream_count] = {0};
    pthread_t threads[2];
    pthread_mutex_lock(&start);
    for (int i = 0; i < 2; ++i) CHECK(!pthread_create(&threads[i], NULL, put_all, ids[i]));
    pthread_mutex_unlock(&start);
    for (int i = 0; i < 2; ++i) CHECK(!pthread_join(threads[i], NULL));

    for (size_t i = 0; i < stream_count; ++i) {
        CHECK(!sources[i].release);
        CHECK((ids[0][i] == 0) != (ids[1][i] == 0));
        uint32_t id = ids[0][i] ? ids[0][i] : ids[1][i];
        struct ArrowArrayStream moved;
        CHECK(!bd_stream_take(id, &moved));
        CHECK(moved.private_data == &sources[i] && moved.release == release);
        moved.release(&moved);
        CHECK(bd_stream_take(id, &moved) == EBADF);
    }

    /* A new token after a full drain must still reject earlier IDs. */
    struct ArrowArrayStream fresh = {schema, next, last_error, release, NULL};
    uint32_t token;
    CHECK(!bd_stream_put(&fresh, &token));
    for (size_t i = 0; i < stream_count; ++i) {
        uint32_t old = ids[0][i] ? ids[0][i] : ids[1][i];
        CHECK(bd_stream_take(old, &fresh) == EBADF);
    }
    CHECK(!bd_stream_take(token, &fresh));
    fresh.release(&fresh);
    puts("Stream token ownership passed");
    return 0;
}
