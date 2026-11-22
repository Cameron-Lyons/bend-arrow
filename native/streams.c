#include "streams.h"

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>

typedef struct StreamEntry {
    uint32_t id;
    struct ArrowArrayStream stream;
    struct StreamEntry *next;
} StreamEntry;

static pthread_mutex_t stream_lock = PTHREAD_MUTEX_INITIALIZER;
static StreamEntry *streams;
static uint32_t last_id;

int bd_stream_put(struct ArrowArrayStream *input, uint32_t *out_id) {
    if (!input || !input->release || !input->get_schema || !input->get_next ||
        !input->get_last_error || !out_id) {
        return EINVAL;
    }
    StreamEntry *entry = malloc(sizeof(*entry));
    if (!entry) return ENOMEM;

    pthread_mutex_lock(&stream_lock);
    if (last_id == UINT32_MAX) {
        pthread_mutex_unlock(&stream_lock);
        free(entry);
        return EOVERFLOW;
    }
    entry->id = ++last_id;
    entry->stream = *input;
    input->release = NULL;
    entry->next = streams;
    streams = entry;
    *out_id = entry->id;
    pthread_mutex_unlock(&stream_lock);
    return 0;
}

int bd_stream_take(uint32_t id, struct ArrowArrayStream *out) {
    if (!out) return EINVAL;
    pthread_mutex_lock(&stream_lock);
    StreamEntry **link = &streams;
    while (*link && (*link)->id != id) link = &(*link)->next;
    StreamEntry *entry = *link;
    if (entry) {
        *link = entry->next;
        *out = entry->stream;
    }
    pthread_mutex_unlock(&stream_lock);
    if (!entry) return EBADF;
    free(entry);
    return 0;
}
