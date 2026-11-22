#include "engine.h"

#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

struct bd_entry {
    uint32_t id;
    size_t borrows;
    bool open;
    bool cached;
    duckdb_database database;
    duckdb_connection connection;
    struct bd_entry *next;
};

/* Only live connections use registry memory. Monotonic tokens prevent an old
 * copy of a closed handle from ever selecting a newly opened database. */
static pthread_mutex_t bd_gate = PTHREAD_MUTEX_INITIALIZER;
static struct bd_entry *bd_connections;
static uint64_t bd_next_id = 1;

/* All overlapping opens of a file must share the same database instance.
 * Keep the cache alive through outstanding open calls and borrowed streams. */
static duckdb_instance_cache bd_file_cache;
static size_t bd_cache_users;

static struct bd_entry **bd_find(uint32_t id) {
    struct bd_entry **slot = &bd_connections;
    while (*slot && (*slot)->id != id) {
        slot = &(*slot)->next;
    }
    return slot;
}

static void bd_destroy(struct bd_entry *entry) {
    if (entry->connection) duckdb_disconnect(&entry->connection);
    if (entry->database) duckdb_close(&entry->database);
    if (entry->cached) {
        pthread_mutex_lock(&bd_gate);
        if (--bd_cache_users == 0) duckdb_destroy_instance_cache(&bd_file_cache);
        pthread_mutex_unlock(&bd_gate);
    }
    free(entry);
}

static int bd_open_database(struct bd_entry *entry, const char *path, char **error) {
    if (!path || !*path || strcmp(path, ":memory:") == 0) {
        return duckdb_open_ext(path, &entry->database, NULL, error) == DuckDBSuccess ? 0 : EIO;
    }
    pthread_mutex_lock(&bd_gate);
    if (!bd_file_cache) bd_file_cache = duckdb_create_instance_cache();
    duckdb_instance_cache cache = bd_file_cache;
    if (cache) {
        ++bd_cache_users;
        entry->cached = true;
    }
    pthread_mutex_unlock(&bd_gate);
    if (!cache) return ENOMEM;
    return duckdb_get_or_create_from_cache(cache, path, &entry->database, NULL, error)
               == DuckDBSuccess ? 0 : EIO;
}

int bd_open(const char *path, uint32_t *out, char **error) {
    if (error) *error = NULL;
    if (!out) return EINVAL;
    *out = 0;
    struct bd_entry *entry = calloc(1, sizeof *entry);
    if (!entry) return ENOMEM;

    int error_code = bd_open_database(entry, path, error);
    if (error_code || duckdb_connect(entry->database, &entry->connection) == DuckDBError) {
        bd_destroy(entry);
        return error_code ? error_code : EIO;
    }

    pthread_mutex_lock(&bd_gate);
    if (bd_next_id > UINT32_MAX) {
        pthread_mutex_unlock(&bd_gate);
        bd_destroy(entry);
        return EOVERFLOW;
    }
    entry->id = (uint32_t)bd_next_id++;
    entry->open = true;
    entry->next = bd_connections;
    bd_connections = entry;
    *out = entry->id;
    pthread_mutex_unlock(&bd_gate);
    return 0;
}

duckdb_connection bd_connection(uint32_t id) {
    pthread_mutex_lock(&bd_gate);
    struct bd_entry *entry = *bd_find(id);
    duckdb_connection con = entry && entry->open ? entry->connection : NULL;
    pthread_mutex_unlock(&bd_gate);
    return con;
}

int bd_connection_acquire(uint32_t id, duckdb_connection *out) {
    if (!out) return EINVAL;
    *out = NULL;
    pthread_mutex_lock(&bd_gate);
    struct bd_entry *entry = *bd_find(id);
    int status = EBADF;
    if (entry && entry->open) {
        status = entry->borrows == SIZE_MAX ? EOVERFLOW : 0;
        if (!status) {
            ++entry->borrows;
            *out = entry->connection;
        }
    }
    pthread_mutex_unlock(&bd_gate);
    return status;
}

/* Unlink under the mutex, destroy outside it: DuckDB cleanup can run
 * callbacks belonging to consumers of the Arrow interface. */
static struct bd_entry *bd_retire(struct bd_entry **slot) {
    struct bd_entry *entry = *slot;
    if (entry->open || entry->borrows != 0) return NULL;
    *slot = entry->next;
    return entry;
}

void bd_connection_release(uint32_t id) {
    pthread_mutex_lock(&bd_gate);
    struct bd_entry **slot = bd_find(id);
    struct bd_entry *retired = NULL;
    if (*slot && (*slot)->borrows) {
        --(*slot)->borrows;
        retired = bd_retire(slot);
    }
    pthread_mutex_unlock(&bd_gate);
    if (retired) bd_destroy(retired);
}

int bd_close(uint32_t id) {
    pthread_mutex_lock(&bd_gate);
    struct bd_entry **slot = bd_find(id);
    if (!*slot || !(*slot)->open) {
        pthread_mutex_unlock(&bd_gate);
        return EBADF;
    }
    (*slot)->open = false;
    struct bd_entry *retired = bd_retire(slot);
    pthread_mutex_unlock(&bd_gate);
    if (retired) bd_destroy(retired);
    return 0;
}
