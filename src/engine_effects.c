#include "engine.h"

#ifdef CID(open_id)
static Term bd_effect_open(Env e, Term *args, IoWork *work) {
    (void)work;
    u64 n;
    char *path = io_cstr(e, args[0], &n);
    uint32_t id;
    char *message = NULL;
    int status = io_nul(path, n) ? EINVAL : bd_open(path, &id, &message);
    free(path);
    Term answer = status ? io_fail(e, status, message) : io_done(e, (Term)id);
    if (message) duckdb_free(message);
    return answer;
}
#endif

#ifdef CID(close_id)
static Term bd_effect_close(Env e, Term *args, IoWork *work) {
    (void)work;
    int status = bd_close((uint32_t)args[0]);
    return status ? io_fail(e, status, NULL) : io_done(e, term_pak(CID(Unit), 0));
}
#endif

#ifdef CID(query_id)
struct bd_column_data {
    duckdb_type type;
    void *values;
    uint64_t *validity;
};

static const char *bd_sql_type(duckdb_type t) {
    switch (t) {
    case DUCKDB_TYPE_BOOLEAN:  return "BOOLEAN";
    case DUCKDB_TYPE_TINYINT:  return "TINYINT";
    case DUCKDB_TYPE_SMALLINT: return "SMALLINT";
    case DUCKDB_TYPE_INTEGER:  return "INTEGER";
    case DUCKDB_TYPE_BIGINT:   return "BIGINT";
    case DUCKDB_TYPE_UTINYINT: return "UTINYINT";
    case DUCKDB_TYPE_USMALLINT:return "USMALLINT";
    case DUCKDB_TYPE_UINTEGER: return "UINTEGER";
    case DUCKDB_TYPE_UBIGINT:  return "UBIGINT";
    case DUCKDB_TYPE_HUGEINT:  return "HUGEINT";
    case DUCKDB_TYPE_UHUGEINT: return "UHUGEINT";
    case DUCKDB_TYPE_FLOAT:    return "FLOAT";
    case DUCKDB_TYPE_DOUBLE:   return "DOUBLE";
    case DUCKDB_TYPE_VARCHAR:  return "VARCHAR";
    case DUCKDB_TYPE_BLOB:     return "BLOB";
    case DUCKDB_TYPE_SQLNULL:  return "SQLNULL";
    default: return NULL;
    }
}

static Term bd_words(Env e, u64 tag, uint64_t bits) {
    return io_node(e, tag, (uint32_t)(bits >> 32), (uint32_t)bits);
}

static Term bd_wide_words(Env e, u64 tag, uint64_t upper, uint64_t lower) {
    u64 loc = heap_alloc(e, cls_fit(4));
    e.mem[loc] = (uint32_t)(upper >> 32);
    e.mem[loc + 1] = (uint32_t)upper;
    e.mem[loc + 2] = (uint32_t)(lower >> 32);
    e.mem[loc + 3] = (uint32_t)lower;
    return term_ctr(tag, loc);
}

static Term bd_cell(Env e, const struct bd_column_data *column, idx_t row) {
    if (column->validity && !duckdb_validity_row_is_valid(column->validity, row)) {
        return term_pak(CID(Null), 0);
    }
    void *values = column->values;
    switch (column->type) {
    case DUCKDB_TYPE_BOOLEAN:
        return term_pak(CID(Boolean), ((bool *)values)[row] ? 1 : 0);
    case DUCKDB_TYPE_TINYINT:   return bd_words(e, CID(Signed), ((int8_t *)values)[row]);
    case DUCKDB_TYPE_SMALLINT:  return bd_words(e, CID(Signed), ((int16_t *)values)[row]);
    case DUCKDB_TYPE_INTEGER:   return bd_words(e, CID(Signed), ((int32_t *)values)[row]);
    case DUCKDB_TYPE_BIGINT:    return bd_words(e, CID(Signed), ((int64_t *)values)[row]);
    case DUCKDB_TYPE_UTINYINT:  return bd_words(e, CID(Unsigned), ((uint8_t *)values)[row]);
    case DUCKDB_TYPE_USMALLINT: return bd_words(e, CID(Unsigned), ((uint16_t *)values)[row]);
    case DUCKDB_TYPE_UINTEGER:  return bd_words(e, CID(Unsigned), ((uint32_t *)values)[row]);
    case DUCKDB_TYPE_UBIGINT:   return bd_words(e, CID(Unsigned), ((uint64_t *)values)[row]);
    case DUCKDB_TYPE_HUGEINT: {
        duckdb_hugeint n = ((duckdb_hugeint *)values)[row];
        return bd_wide_words(e, CID(WideSigned), (uint64_t)n.upper, n.lower);
    }
    case DUCKDB_TYPE_UHUGEINT: {
        duckdb_uhugeint n = ((duckdb_uhugeint *)values)[row];
        return bd_wide_words(e, CID(WideUnsigned), n.upper, n.lower);
    }
    case DUCKDB_TYPE_FLOAT:
        return term_pak(CID(Float), f32_rewrap(((float *)values)[row]));
    case DUCKDB_TYPE_DOUBLE: {
        uint64_t bits;
        memcpy(&bits, (double *)values + row, sizeof bits);
        return bd_words(e, CID(Double), bits);
    }
    case DUCKDB_TYPE_VARCHAR:
    case DUCKDB_TYPE_BLOB: {
        duckdb_string_t *s = (duckdb_string_t *)values + row;
        const char *p = duckdb_string_t_data(s);
        uint32_t length = duckdb_string_t_length(*s);
        return column->type == DUCKDB_TYPE_VARCHAR
            ? io_box(e, CID(Utf8), io_str(e, p, length))
            : io_box(e, CID(Bytes), io_list(e, p, length));
    }
    default: return term_pak(CID(Null), 0); /* SQLNULL; all other types checked up front. */
    }
}

/* Construct rows in fetch order, including across DuckDB chunk boundaries.
 * The tail hole uses the same heap/sealing convention as Bend's io_str. */
static Term bd_table(Env e, duckdb_result *result) {
    idx_t count = duckdb_column_count(result);
    struct bd_column_data *data = calloc(count, sizeof *data);
    if (count && !data) return io_fail(e, ENOMEM, NULL);

    Term nil = term_pak(CID(Nil), 0);
    Term columns = nil;
    for (idx_t i = count; i > 0; --i) {
        idx_t col = i - 1;
        data[col].type = duckdb_column_type(result, col);
        const char *type = bd_sql_type(data[col].type);
        const char *name = duckdb_column_name(result, col);
        if (!type) {
            char message[384];
            snprintf(message, sizeof message, "Column '%.220s' has an unsupported Bend cell type. Use Arrow.query or an explicit SQL cast.", name);
            term_drop(e, columns);
            free(data);
            return io_fail(e, ENOTSUP, message);
        }
        Term field = io_node(e, CID(Column), io_str(e, name, strlen(name)),
                            io_str(e, type, strlen(type)));
        columns = io_node(e, CID(Con), field, columns);
    }

    Term rows = nil;
    Term *tail = &rows;
    duckdb_data_chunk chunk;
    while ((chunk = duckdb_fetch_chunk(*result)) != NULL) {
        for (idx_t col = 0; col < count; ++col) {
            duckdb_vector v = duckdb_data_chunk_get_vector(chunk, col);
            data[col].values = duckdb_vector_get_data(v);
            data[col].validity = duckdb_vector_get_validity(v);
        }
        idx_t length = duckdb_data_chunk_get_size(chunk);
        for (idx_t row = 0; row < length; ++row) {
            Term cells = nil;
            for (idx_t i = count; i > 0; --i) {
                cells = io_node(e, CID(Con), bd_cell(e, &data[i - 1], row), cells);
            }
            Term node = io_node(e, CID(Con), cells, nil);
            *tail = tail == &rows ? node : io_seal(e, node, CID(Con));
            tail = &e.mem[term_loc(node) + 1];
        }
        duckdb_destroy_data_chunk(&chunk);
    }
    free(data);
    const char *error = duckdb_result_error(result);
    if (error && *error) {
        term_drop(e, rows);
        term_drop(e, columns);
        return io_fail(e, EIO, error);
    }
    return io_done(e, io_node(e, CID(Table), columns, rows));
}
#endif

#if defined(CID(exec_id)) || defined(CID(query_id))
static Term bd_run_sql(Env e, Term *args, bool return_table) {
    (void)return_table; /* Programs using only exec compile out bd_table. */
    u64 length;
    char *sql = io_cstr(e, args[1], &length);
    uint32_t id = (uint32_t)args[0];
    duckdb_connection conn;
    int error = io_nul(sql, length) ? EINVAL : bd_connection_acquire(id, &conn);
    if (error) {
        free(sql);
        return io_fail(e, error, NULL);
    }
    duckdb_result result;
    duckdb_state status = duckdb_query(conn, sql, &result);
    free(sql);
    Term answer;
    if (status == DuckDBError) {
        answer = io_fail(e, EIO, duckdb_result_error(&result));
#ifdef CID(query_id)
    } else if (return_table) {
        answer = bd_table(e, &result);
#endif
    } else {
        answer = io_done(e, term_pak(CID(Unit), 0));
    }
    duckdb_destroy_result(&result);
    bd_connection_release(id);
    return answer;
}
#endif

#ifdef CID(exec_id)
static Term bd_effect_exec(Env e, Term *args, IoWork *work) {
    (void)work;
    return bd_run_sql(e, args, false);
}
#endif

#ifdef CID(query_id)
static Term bd_effect_query(Env e, Term *args, IoWork *work) {
    (void)work;
    return bd_run_sql(e, args, true);
}
#endif

static void __attribute__((constructor)) bd_engine_register(void) {
#ifdef CID(open_id)
    io_eff(CID(open_id), bd_effect_open);
#endif
#ifdef CID(exec_id)
    io_eff(CID(exec_id), bd_effect_exec);
#endif
#ifdef CID(query_id)
    io_eff(CID(query_id), bd_effect_query);
#endif
#ifdef CID(close_id)
    io_eff(CID(close_id), bd_effect_close);
#endif
}
