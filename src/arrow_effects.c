#include "engine.h"
#include "streams.h"
#include <errno.h>

static Term bd_arrow_effect_result(Env e, int code, char *error, Term value) {
    Term result = code ? io_fail(e, code, error) : io_done(e, value);
    free(error);
    return result;
}

#ifdef CID(query_id)
static Term bd_export_run(Env e, Term *f, IoWork *w) {
    (void)w;
    uint32_t id = (uint32_t)f[0], token = 0;
    uint64_t length;
    char *sql = io_cstr(e, f[1], &length);
    char *error = NULL;
    duckdb_connection db = NULL;
    int code = io_nul(sql, length) ? EINVAL : bd_connection_acquire(id, &db);
    if (!code) {
        struct ArrowArrayStream stream = {0};
        code = bd_arrow_query(db, sql, &stream, &error);
        if (!code) {
            bd_arrow_on_release(&stream, bd_connection_release, id);
            code = bd_stream_put(&stream, &token);
            if (code) stream.release(&stream);
        } else {
            bd_connection_release(id);
        }
    }
    free(sql);
    return bd_arrow_effect_result(e, code, error, token);
}
#endif

#ifdef CID(import_id)
static Term bd_import_run(Env e, Term *f, IoWork *w) {
    (void)w;
    struct ArrowArrayStream stream = {0};
    uint64_t length;
    char *name = io_cstr(e, f[1], &length);
    char *error = NULL;
    int code = bd_stream_take((uint32_t)f[2], &stream);
    if (!code) {
        uint32_t id = (uint32_t)f[0];
        duckdb_connection db = NULL;
        code = io_nul(name, length) ? EINVAL : bd_connection_acquire(id, &db);
        if (!code) {
            code = bd_arrow_import(db, name, &stream, &error);
            bd_connection_release(id);
        }
        stream.release(&stream);
    }
    free(name);
    return bd_arrow_effect_result(e, code, error, term_pak(CID(Unit), 0));
}
#endif

#ifdef CID(close_id)
static Term bd_stream_close_run(Env e, Term *f, IoWork *w) {
    (void)w;
    struct ArrowArrayStream stream = {0};
    int code = bd_stream_take((uint32_t)f[0], &stream);
    if (!code) stream.release(&stream);
    return bd_arrow_effect_result(e, code, NULL, term_pak(CID(Unit), 0));
}
#endif

static void __attribute__((constructor)) bd_register_arrow_effects(void) {
#ifdef CID(query_id)
    io_eff(CID(query_id), bd_export_run);
#endif
#ifdef CID(import_id)
    io_eff(CID(import_id), bd_import_run);
#endif
#ifdef CID(close_id)
    io_eff(CID(close_id), bd_stream_close_run);
#endif
}
