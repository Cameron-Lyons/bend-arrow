#include "arrow.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    duckdb_result result;
    duckdb_arrow_options options;
    duckdb_logical_type *types;
    const char **names;
    idx_t columns;
    char *error;
    void (*release_connection)(uint32_t);
    uint32_t connection_id;
} BdQueryStream;

static int bd_error(char **out, int code, const char *message) {
    if (out) {
        if (!message) message = "DuckDB Arrow operation failed";
        size_t size = strlen(message) + 1;
        *out = malloc(size);
        if (*out) memcpy(*out, message, size);
    }
    return code;
}

static void bd_release_query(struct ArrowArrayStream *stream) {
    BdQueryStream *q = stream->private_data;
    *stream = (struct ArrowArrayStream){0};
    if (q->types) {
        for (idx_t i = 0; i < q->columns; i++) duckdb_destroy_logical_type(&q->types[i]);
    }
    free(q->types);
    free(q->names);
    free(q->error);
    duckdb_destroy_arrow_options(&q->options);
    duckdb_destroy_result(&q->result);
    if (q->release_connection) q->release_connection(q->connection_id);
    free(q);
}

static int bd_conversion_result(BdQueryStream *q, duckdb_error_data error) {
    free(q->error);
    q->error = NULL;
    if (!error) return 0;
    int status = bd_error(&q->error, EIO, duckdb_error_data_message(error));
    duckdb_destroy_error_data(&error);
    return status;
}

static int bd_query_schema(struct ArrowArrayStream *stream, struct ArrowSchema *out) {
    BdQueryStream *q = stream->private_data;
    *out = (struct ArrowSchema){0};
    return bd_conversion_result(q, duckdb_to_arrow_schema(q->options, q->types, q->names, q->columns, out));
}

static int bd_query_next(struct ArrowArrayStream *stream, struct ArrowArray *out) {
    BdQueryStream *q = stream->private_data;
    *out = (struct ArrowArray){0};
    duckdb_data_chunk chunk = duckdb_fetch_chunk(q->result);
    if (!chunk) {
        free(q->error);
        q->error = NULL;
        const char *error = duckdb_result_error(&q->result);
        return error ? bd_error(&q->error, EIO, error) : 0;
    }
    duckdb_error_data error = duckdb_data_chunk_to_arrow(q->options, chunk, out);
    duckdb_destroy_data_chunk(&chunk);
    return bd_conversion_result(q, error);
}

static const char *bd_query_last_error(struct ArrowArrayStream *stream) {
    return ((BdQueryStream *)stream->private_data)->error;
}

int bd_arrow_query(duckdb_connection con, const char *sql, struct ArrowArrayStream *out, char **error) {
    if (error) *error = NULL;
    if (out) *out = (struct ArrowArrayStream){0};
    if (!con || !sql || !out) return bd_error(error, EINVAL, "Missing Arrow query argument");
    BdQueryStream *q = calloc(1, sizeof(*q));
    if (!q) return bd_error(error, ENOMEM, "Allocating Arrow query stream");
    *out = (struct ArrowArrayStream){bd_query_schema, bd_query_next, bd_query_last_error, bd_release_query, q};
    if (duckdb_query(con, sql, &q->result) == DuckDBError) {
        bd_error(error, EIO, duckdb_result_error(&q->result));
        bd_release_query(out);
        return EIO;
    }
    q->columns = duckdb_column_count(&q->result);
    q->options = duckdb_result_get_arrow_options(&q->result);
    q->names = calloc(q->columns, sizeof(*q->names));
    q->types = calloc(q->columns, sizeof(*q->types));
    if (!q->options || (q->columns && (!q->names || !q->types))) {
        bd_release_query(out);
        return bd_error(error, ENOMEM, "Allocating Arrow query schema");
    }
    for (idx_t i = 0; i < q->columns; i++) {
        q->names[i] = duckdb_column_name(&q->result, i);
        q->types[i] = duckdb_column_logical_type(&q->result, i);
    }
    return 0;
}

void bd_arrow_on_release(struct ArrowArrayStream *stream, void (*release_connection)(uint32_t), uint32_t id) {
    BdQueryStream *q = stream->private_data;
    q->release_connection = release_connection;
    q->connection_id = id;
}

/* DuckDB's scan API borrows a schema, can call get_schema repeatedly and
 * temporarily edits the releases on the schema's immediate children.
 * Supply shallow descriptors owned by this adapter; retain the real schema
 * and delegate data batch ownership directly to the original producer. */
typedef struct {
    struct ArrowArrayStream *input;
    struct ArrowSchema schema;
    struct ArrowSchema *children;
    struct ArrowSchema **child_pointers;
    const char *validation_error;
} BdScan;

static void bd_borrowed_schema_release(struct ArrowSchema *schema) { schema->release = NULL; }
static void bd_borrowed_stream_release(struct ArrowArrayStream *stream) { stream->release = NULL; }

static int bd_scan_schema(struct ArrowArrayStream *stream, struct ArrowSchema *out) {
    BdScan *scan = stream->private_data;
    *out = scan->schema;
    out->children = scan->child_pointers;
    out->release = bd_borrowed_schema_release;
    return 0;
}

/* A sliced Arrow struct can describe its window at the root. DuckDB's
 * scan expects each top-level child to describe that window instead. Move
 * only descriptors, keeping the original arrays and release callback alive. */
typedef struct {
    struct ArrowArray original;
    struct ArrowArray *columns;
    struct ArrowArray **pointers;
} BdSlicedBatch;

static void bd_slice_release(struct ArrowArray *out) {
    BdSlicedBatch *slice = out->private_data;
    out->release = NULL;
    slice->original.release(&slice->original);
    free(slice->columns);
    free(slice->pointers);
    free(slice);
}

static int bd_slice_batch(struct ArrowArray *out) {
    BdSlicedBatch *slice = calloc(1, sizeof(*slice));
    if (!slice) return ENOMEM;
    size_t count = (size_t)out->n_children;
    slice->columns = calloc(count, sizeof(*slice->columns));
    slice->pointers = calloc(count, sizeof(*slice->pointers));
    if (!slice->columns || !slice->pointers) {
        free(slice->columns);
        free(slice->pointers);
        free(slice);
        return ENOMEM;
    }
    slice->original = *out;
    for (size_t i = 0; i < count; i++) {
        slice->columns[i] = *out->children[i];
        slice->columns[i].offset += out->offset;
        slice->columns[i].length = out->length;
        if (slice->columns[i].null_count > 0) slice->columns[i].null_count = -1;
        slice->pointers[i] = &slice->columns[i];
    }
    out->offset = 0;
    out->children = slice->pointers;
    out->release = bd_slice_release;
    out->private_data = slice;
    return 0;
}

static int bd_has_null_rows(const struct ArrowArray *batch) {
    if (batch->null_count >= 0) return batch->null_count != 0;
    if (!batch->buffers || !batch->buffers[0]) return 0;
    const uint8_t *valid = batch->buffers[0];
    for (int64_t i = batch->offset; i < batch->offset + batch->length; i++) {
        if (!(valid[i / 8] & (1u << (i % 8)))) return 1;
    }
    return 0;
}

static int bd_scan_next(struct ArrowArrayStream *stream, struct ArrowArray *out) {
    BdScan *scan = stream->private_data;
    *out = (struct ArrowArray){0};
    int rc = scan->input->get_next(scan->input, out);
    if (rc) {
        *out = (struct ArrowArray){0};
        return rc;
    }
    if (!out->release) return 0;
    int sliced = out->offset != 0;
    if (out->length < 0 || out->offset < 0 || out->offset > INT64_MAX - out->length ||
        !out->children || out->n_children != scan->schema.n_children) {
        scan->validation_error = "Invalid Arrow record batch";
    } else if (bd_has_null_rows(out)) {
        scan->validation_error = "Arrow record batch contains null rows";
    } else {
        for (int64_t i = 0; i < out->n_children; i++) {
            struct ArrowArray *child = out->children[i];
            if (!child || !child->release || child->offset < 0 || child->length < out->length + out->offset ||
                child->offset > INT64_MAX - child->length) {
                scan->validation_error = "Invalid Arrow record batch child";
                break;
            }
            if (child->length != out->length) sliced = 1;
        }
    }
    if (!scan->validation_error && sliced && (rc = bd_slice_batch(out)))
        scan->validation_error = "Allocating sliced Arrow batch descriptors";
    if (scan->validation_error) {
        out->release(out);
        return rc ? rc : EINVAL;
    }
    return 0;
}

static const char *bd_scan_error(struct ArrowArrayStream *stream) {
    BdScan *scan = stream->private_data;
    if (scan->validation_error) return scan->validation_error;
    const char *msg = scan->input->get_last_error(scan->input);
    return msg ? msg : "Arrow producer reported an error";
}

static int bd_scan_init(BdScan *scan, char **error) {
    int rc = scan->input->get_schema(scan->input, &scan->schema);
    if (rc) {
        scan->schema = (struct ArrowSchema){0};
        return bd_error(error, rc, scan->input->get_last_error(scan->input));
    }
    struct ArrowSchema *s = &scan->schema;
    if (!s->release || !s->format || strcmp(s->format, "+s") ||
        s->n_children <= 0 || !s->children || s->dictionary)
        return bd_error(error, EINVAL, "Expected an Arrow struct schema with at least one field");
    scan->children = calloc((size_t)s->n_children, sizeof(*scan->children));
    scan->child_pointers = calloc((size_t)s->n_children, sizeof(*scan->child_pointers));
    if (!scan->children || !scan->child_pointers) return bd_error(error, ENOMEM, "Allocating Arrow scan schema");
    for (int64_t i = 0; i < s->n_children; i++) {
        if (!s->children[i] || !s->children[i]->release || !s->children[i]->format)
            return bd_error(error, EINVAL, "Invalid Arrow column schema");
        scan->children[i] = *s->children[i];
        if (!scan->children[i].name) scan->children[i].name = "";
        scan->children[i].release = bd_borrowed_schema_release;
        scan->child_pointers[i] = &scan->children[i];
    }
    return 0;
}

/* The public scan API registers a catalog view that retains raw pointers.
 * Keep that view in a private in-memory database for the duration of the
 * call. One thread also allows input callbacks with thread affinity. */
static int bd_open_scan(duckdb_database *db, duckdb_connection *con, char **error) {
    duckdb_config config = NULL;
    duckdb_state status = duckdb_create_config(&config);
    if (status == DuckDBSuccess) status = duckdb_set_config(config, "threads", "1");
    char *why = NULL;
    if (status == DuckDBSuccess) status = duckdb_open_ext(NULL, db, config, &why);
    duckdb_destroy_config(&config);
    if (status == DuckDBSuccess) status = duckdb_connect(*db, con);
    int rc = status == DuckDBSuccess ? 0 : bd_error(error, EIO, why ? why : "Opening Arrow scan database");
    duckdb_free(why);
    return rc;
}

static int bd_run_sql(duckdb_connection con, const char *sql, char **error) {
    duckdb_result result = {0};
    int rc = 0;
    if (duckdb_query(con, sql, &result) == DuckDBError)
        rc = bd_error(error, EIO, duckdb_result_error(&result));
    duckdb_destroy_result(&result);
    return rc;
}

static int bd_copy_scan(duckdb_connection source, duckdb_connection dest, const char *name, char **error) {
    /* Build the DDL from DuckDB's resolved SQL types. Bind the destination
     * name as a value when quoting it, including embedded double quotes. */
    const char *ddl =
        "SELECT 'CREATE TEMP TABLE \"' || replace($1, '\"', '\"\"') || '\" (' || "
        "string_agg('\"' || replace(column_name, '\"', '\"\"') || '\" ' || column_type, ', ') || ')', "
        "'DROP TABLE temp.main.\"' || replace($1, '\"', '\"\"') || '\"' FROM (DESCRIBE bd_input)";
    duckdb_prepared_statement metadata = NULL, scan = NULL;
    duckdb_result statements = {0}, rows = {0};
    duckdb_appender appender = NULL;
    char *create = NULL, *drop = NULL;
    int created = 0, rc = EIO;
    if (duckdb_prepare(source, ddl, &metadata) || duckdb_bind_varchar(metadata, 1, name)) {
        bd_error(error, rc, duckdb_prepare_error(metadata));
        goto done;
    }
    if (duckdb_execute_prepared(metadata, &statements)) {
        bd_error(error, rc, duckdb_result_error(&statements));
        goto done;
    }
    create = duckdb_value_varchar(&statements, 0, 0);
    drop = duckdb_value_varchar(&statements, 1, 0);
    if (!create || !drop) {
        rc = bd_error(error, ENOMEM, "Building temporary table definition");
        goto done;
    }
    if (bd_run_sql(dest, create, error)) goto done;
    created = 1;
    if (duckdb_appender_create_ext(dest, "temp", "main", name, &appender)) {
        bd_error(error, rc, duckdb_appender_error(appender));
        goto done;
    }
    if (duckdb_prepare(source, "SELECT * FROM bd_input", &scan)) {
        bd_error(error, rc, duckdb_prepare_error(scan));
        goto done;
    }
    if (duckdb_execute_prepared_streaming(scan, &rows)) {
        bd_error(error, rc, duckdb_result_error(&rows));
        goto done;
    }
    for (;;) {
        duckdb_data_chunk chunk = duckdb_fetch_chunk(rows);
        if (!chunk) break;
        duckdb_state status = duckdb_append_data_chunk(appender, chunk);
        duckdb_destroy_data_chunk(&chunk);
        if (status) {
            bd_error(error, rc, duckdb_appender_error(appender));
            goto done;
        }
    }
    if (duckdb_result_error(&rows)) {
        bd_error(error, rc, duckdb_result_error(&rows));
        goto done;
    }
    if (duckdb_appender_close(appender)) {
        bd_error(error, rc, duckdb_appender_error(appender));
        goto done;
    }
    rc = 0;
done:
    duckdb_appender_destroy(&appender);
    if (rc && created) bd_run_sql(dest, drop, NULL);
    duckdb_destroy_result(&rows);
    duckdb_destroy_prepare(&scan);
    duckdb_free(create);
    duckdb_free(drop);
    duckdb_destroy_result(&statements);
    duckdb_destroy_prepare(&metadata);
    return rc;
}

int bd_arrow_import(duckdb_connection con, const char *table_name, struct ArrowArrayStream *input, char **error) {
    if (error) *error = NULL;
    if (!con || !table_name || !*table_name || !input || !input->release || !input->get_schema ||
        !input->get_next || !input->get_last_error)
        return bd_error(error, EINVAL, "Invalid Arrow stream or destination");
    BdScan scan = {.input = input};
    struct ArrowArrayStream borrowed = {bd_scan_schema, bd_scan_next, bd_scan_error, bd_borrowed_stream_release, &scan};
    duckdb_database db = NULL;
    duckdb_connection source = NULL;
    int rc = bd_scan_init(&scan, error);
    if (!rc) rc = bd_open_scan(&db, &source, error);
    if (!rc && duckdb_arrow_scan(source, "bd_input", (duckdb_arrow_stream)&borrowed))
        rc = bd_error(error, EINVAL, "DuckDB cannot scan the supplied Arrow schema");
    if (!rc) rc = bd_copy_scan(source, con, table_name, error);
    duckdb_disconnect(&source);
    duckdb_close(&db);
    free(scan.child_pointers);
    free(scan.children);
    if (scan.schema.release) scan.schema.release(&scan.schema);
    return rc;
}
