#include "engine.h"

#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #expr); exit(1); \
} } while (0)

enum { worker_count = 6 };
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t changed = PTHREAD_COND_INITIALIZER;
static bool closing;
static unsigned opening;

static void scalar(duckdb_function_info info, duckdb_data_chunk in, duckdb_vector out) {
    (void)info; (void)in; (void)out;
}

/* The catalog releases this function during the last database close. Let
 * the workers start reopening the file while its old instance still exists. */
static void during_shutdown(void *unused) {
    (void)unused;
    pthread_mutex_lock(&mutex);
    closing = true;
    pthread_cond_broadcast(&changed);
    while (opening != worker_count) pthread_cond_wait(&changed, &mutex);
    pthread_mutex_unlock(&mutex);
}

struct worker {
    const char *path;
    uint32_t id;
};

static void *reopen(void *arg) {
    struct worker *worker = arg;
    pthread_mutex_lock(&mutex);
    while (!closing) pthread_cond_wait(&changed, &mutex);
    ++opening;
    pthread_cond_broadcast(&changed);
    pthread_mutex_unlock(&mutex);

    char *error = NULL;
    int status = bd_open(worker->path, &worker->id, &error);
    if (status) fprintf(stderr, "open failed: %s\n", error ? error : "unknown error");
    duckdb_free(error);
    CHECK(!status);
    CHECK(!duckdb_query(bd_connection(worker->id), "BEGIN; INSERT INTO counts VALUES (1); COMMIT", NULL));
    return NULL;
}

int main(int argc, char **argv) {
    CHECK(argc == 2);
    uint32_t id;
    CHECK(!bd_open(argv[1], &id, NULL));
    duckdb_connection con = bd_connection(id);
    CHECK(!duckdb_query(con, "CREATE TABLE counts(i INTEGER)", NULL));
    duckdb_scalar_function fn = duckdb_create_scalar_function();
    duckdb_logical_type type = duckdb_create_logical_type(DUCKDB_TYPE_INTEGER);
    duckdb_scalar_function_set_name(fn, "on_shutdown");
    duckdb_scalar_function_set_return_type(fn, type);
    duckdb_scalar_function_set_function(fn, scalar);
    duckdb_scalar_function_set_extra_info(fn, &closing, during_shutdown);
    CHECK(!duckdb_register_scalar_function(con, fn));
    duckdb_destroy_logical_type(&type);
    duckdb_destroy_scalar_function(&fn);

    struct worker workers[worker_count];
    pthread_t threads[worker_count];
    for (unsigned i = 0; i < worker_count; ++i) {
        workers[i].path = argv[1];
        CHECK(!pthread_create(&threads[i], NULL, reopen, &workers[i]));
    }
    CHECK(!bd_close(id));
    for (unsigned i = 0; i < worker_count; ++i) CHECK(!pthread_join(threads[i], NULL));
    duckdb_result result = {0};
    CHECK(!duckdb_query(bd_connection(workers[0].id), "SELECT count(*) FROM counts", &result));
    CHECK(duckdb_value_int64(&result, 0, 0) == worker_count);
    duckdb_destroy_result(&result);
    for (unsigned i = 0; i < worker_count; ++i) CHECK(!bd_close(workers[i].id));
    puts("Concurrent database reopen passed");
    return 0;
}
