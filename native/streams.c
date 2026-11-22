#include "streams.h"
#include "registry.h"

#include <errno.h>
#include <pthread.h>
#include <stdlib.h>

typedef struct StreamEntry {
    struct bd_handle handle;
    struct ArrowArrayStream stream;
} StreamEntry;

static pthread_mutex_t stream_lock = PTHREAD_MUTEX_INITIALIZER;
static struct bd_registry streams;

int bd_stream_put(struct ArrowArrayStream *input, uint32_t *out_id) {
    if (!input || !out_id) return EINVAL;
    StreamEntry *entry = malloc(sizeof(*entry));
    if (!entry) return ENOMEM;

    pthread_mutex_lock(&stream_lock);
    int status = EINVAL;
    if (input->release && input->get_schema && input->get_next && input->get_last_error) {
        status = bd_registry_add(&streams, &entry->handle);
        if (!status) {
            entry->stream = *input;
            input->release = NULL;
            *out_id = entry->handle.id;
        }
    }
    pthread_mutex_unlock(&stream_lock);
    if (status) free(entry);
    return status;
}

int bd_stream_take(uint32_t id, struct ArrowArrayStream *out) {
    if (!out) return EINVAL;
    pthread_mutex_lock(&stream_lock);
    StreamEntry *entry = (StreamEntry *)bd_registry_remove(&streams, id);
    if (entry) *out = entry->stream;
    pthread_mutex_unlock(&stream_lock);
    if (!entry) return EBADF;
    free(entry);
    return 0;
}
