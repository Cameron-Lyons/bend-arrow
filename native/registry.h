#ifndef BEND_ARROW_REGISTRY_H
#define BEND_ARROW_REGISTRY_H

#include <errno.h>
#include <stdint.h>
#include <stdlib.h>

/* Embed this as the first member of a token's owner. The caller serializes
 * operations and owns the entries. A zero-initialized registry is empty. */
struct bd_handle {
    uint32_t id;
    struct bd_handle *next;
};

struct bd_registry {
    struct bd_handle **buckets;
    size_t capacity;
    size_t count;
    uint32_t last_id;
    struct bd_handle *small[8];
};

static inline size_t bd_bucket_index(uint32_t id, size_t capacity) {
    /* Mix in the high bits when long-lived tokens are spaced far apart. */
    uint32_t hash = id * UINT32_C(2654435761);
    return (hash ^ (hash >> 16)) & (capacity - 1);
}

static inline struct bd_handle **bd_registry_slot(struct bd_registry *registry, uint32_t id) {
    if (!registry->capacity) return NULL;
    struct bd_handle **slot = &registry->buckets[bd_bucket_index(id, registry->capacity)];
    while (*slot && (*slot)->id != id) slot = &(*slot)->next;
    return slot;
}

static inline struct bd_handle *bd_registry_find(struct bd_registry *registry, uint32_t id) {
    struct bd_handle **slot = bd_registry_slot(registry, id);
    return slot ? *slot : NULL;
}

static inline int bd_registry_grow(struct bd_registry *registry) {
    if (registry->capacity > SIZE_MAX / 2 / sizeof(*registry->buckets)) return EOVERFLOW;
    size_t capacity = registry->capacity * 2;
    struct bd_handle **buckets = calloc(capacity, sizeof(*buckets));
    if (!buckets) return ENOMEM;

    for (size_t i = 0; i < registry->capacity; ++i) {
        struct bd_handle *handle = registry->buckets[i];
        registry->buckets[i] = NULL;
        while (handle) {
            struct bd_handle *next = handle->next;
            size_t index = bd_bucket_index(handle->id, capacity);
            handle->next = buckets[index];
            buckets[index] = handle;
            handle = next;
        }
    }
    if (registry->buckets != registry->small) free(registry->buckets);
    registry->buckets = buckets;
    registry->capacity = capacity;
    return 0;
}

static inline int bd_registry_add(struct bd_registry *registry, struct bd_handle *handle) {
    if (registry->last_id == UINT32_MAX) return EOVERFLOW;
    if (!registry->capacity) {
        registry->buckets = registry->small;
        registry->capacity = sizeof(registry->small) / sizeof(registry->small[0]);
    }
    if (registry->count == registry->capacity) {
        int status = bd_registry_grow(registry);
        if (status) return status;
    }
    handle->id = ++registry->last_id;
    size_t index = bd_bucket_index(handle->id, registry->capacity);
    handle->next = registry->buckets[index];
    registry->buckets[index] = handle;
    ++registry->count;
    return 0;
}

static inline struct bd_handle *bd_registry_remove(struct bd_registry *registry, uint32_t id) {
    struct bd_handle **slot = bd_registry_slot(registry, id);
    if (!slot || !*slot) return NULL;
    struct bd_handle *handle = *slot;
    *slot = handle->next;
    if (--registry->count == 0 && registry->buckets != registry->small) {
        free(registry->buckets);
        registry->buckets = NULL;
        registry->capacity = 0;
        /* Keep last_id so stale tokens cannot select a future entry. */
    }
    return handle;
}

#endif
