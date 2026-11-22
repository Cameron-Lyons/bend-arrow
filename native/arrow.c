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
        if (!q->names[i] || !q->types[i]) {
            bd_release_query(out);
            return bd_error(error, ENOMEM, "Reading Arrow query schema");
        }
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
    int error_code;
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

/* Count only bits in the requested window. Arrow validity is LSB first and
 * a missing bitmap denotes an all-valid array. */
static int64_t bd_bitmap_null_count(const struct ArrowArray *array) {
    if (!array->buffers || !array->buffers[0]) return 0;
    const uint8_t *valid = array->buffers[0];
    int64_t bit = array->offset, end = bit + array->length, nulls = 0;
    while (bit < end && bit % 8) {
        nulls += !(valid[bit / 8] & (1u << (bit % 8)));
        bit++;
    }
    for (; end - bit >= 8; bit += 8)
        nulls += 8 - __builtin_popcount(valid[bit / 8]);
    for (; bit < end; bit++)
        nulls += !(valid[bit / 8] & (1u << (bit % 8)));
    return nulls;
}

/* DuckDB expects the root window on each top-level column, and a known
 * null count on dictionary indices, including those nested in other types.
 * Most batches already have that layout. Count descriptors while checking
 * for adaptations so a batch needing a view can allocate them together. */
static int bd_inspect_array(const struct ArrowArray *array, size_t *count, int *needs_view) {
    if (!array || !array->release || array->offset < 0 || array->length < 0 ||
        array->offset > INT64_MAX - array->length || array->n_children < 0 ||
        (array->n_children && !array->children)) return EINVAL;
    if (*count == SIZE_MAX) return ENOMEM;
    ++*count;
    for (int64_t i = 0; i < array->n_children; i++) {
        int rc = bd_inspect_array(array->children[i], count, needs_view);
        if (rc) return rc;
    }
    if (array->dictionary) {
        if (array->null_count < 0) *needs_view = 1;
        return bd_inspect_array(array->dictionary, count, needs_view);
    }
    return 0;
}

typedef struct {
    struct ArrowArray original;
    struct ArrowArray **pointers;
    struct ArrowArray arrays[];
} BdBatchView;

static void bd_view_release(struct ArrowArray *out) {
    BdBatchView *view = out->private_data;
    out->release = NULL;
    view->original.release(&view->original);
    free(view->pointers);
    free(view);
}

typedef struct {
    struct ArrowArray *arrays;
    struct ArrowArray **pointers;
} BdViewCursor;

static struct ArrowArray *bd_copy_column(BdViewCursor *cursor, const struct ArrowArray *source,
                                         int64_t skip, int64_t length) {
    struct ArrowArray *column = cursor->arrays++;
    *column = *source;
    column->offset += skip;
    column->length = length;
    if (length != source->length && column->null_count > 0) column->null_count = -1;
    if (source->n_children) {
        column->children = cursor->pointers;
        cursor->pointers += source->n_children;
        for (int64_t i = 0; i < source->n_children; i++) {
            const struct ArrowArray *child = source->children[i];
            column->children[i] = bd_copy_column(cursor, child, 0, child->length);
        }
    }
    if (source->dictionary) {
        if (column->null_count < 0) column->null_count = bd_bitmap_null_count(column);
        column->dictionary = bd_copy_column(cursor, source->dictionary, 0, source->dictionary->length);
    }
    return column;
}

static int bd_make_batch_view(struct ArrowArray *out, size_t count) {
    if (count > (SIZE_MAX - sizeof(BdBatchView)) / sizeof(struct ArrowArray)) return ENOMEM;
    BdBatchView *view = malloc(sizeof(*view) + count * sizeof(*view->arrays));
    if (!view) return ENOMEM;
    view->pointers = malloc(count * sizeof(*view->pointers));
    if (!view->pointers) {
        free(view);
        return ENOMEM;
    }
    view->original = *out;
    BdViewCursor cursor = {view->arrays, view->pointers + out->n_children};
    for (int64_t i = 0; i < out->n_children; i++)
        view->pointers[i] = bd_copy_column(&cursor, out->children[i], out->offset, out->length);
    out->offset = 0;
    out->null_count = 0;
    out->children = view->pointers;
    out->release = bd_view_release;
    out->private_data = view;
    return 0;
}

/* In DuckDB 1.5.6 the LIST dictionary decoder reads indices at the first
 * list offset but validity at the current row offset. Check just these
 * windows before handing over a nullable dictionary. */
static int bd_list_dictionary_mismatch(const struct ArrowSchema *schema,
                                       const struct ArrowArray *list) {
    int64_t rows = list->length;
    if (!rows || !list->n_children) return 0;
    const struct ArrowArray *indices = list->children[0];
    if (!indices->dictionary || !indices->null_count || !indices->buffers || !indices->buffers[0]) return 0;
    int large = !strcmp(schema->format, "+L");
    if (!large && strcmp(schema->format, "+l")) return 0;
    const uint8_t *valid = indices->buffers[0];
    if (list->n_buffers < 2 || !list->buffers || !list->buffers[1]) return 1;
    const void *offsets = list->buffers[1];
    int64_t vector_size = (int64_t)duckdb_vector_size();
    for (int64_t row = 0; row < rows;) {
        int64_t n = rows - row < vector_size ? rows - row : vector_size;
        int64_t i = list->offset + row;
        int64_t first = large ? ((const int64_t *)offsets)[i] : ((const int32_t *)offsets)[i];
        int64_t last = large ? ((const int64_t *)offsets)[i + n] : ((const int32_t *)offsets)[i + n];
        if (first < 0 || last < first || last > indices->length) return 1;
        if (first != row && last > first) {
            if (last - first > indices->length - row) return 1;
            for (int64_t j = 0; j < last - first; j++) {
                int64_t a = indices->offset + first + j, b = indices->offset + row + j;
                if (((valid[a / 8] >> (a % 8)) ^ (valid[b / 8] >> (b % 8))) & 1) return 1;
            }
        }
        row += n;
    }
    return 0;
}

static int bd_scan_next(struct ArrowArrayStream *stream, struct ArrowArray *out) {
    BdScan *scan = stream->private_data;
    *out = (struct ArrowArray){0};
    int rc = scan->input->get_next(scan->input, out);
    if (rc) {
        *out = (struct ArrowArray){0};
        scan->error_code = rc;
        return rc;
    }
    if (!out->release) return 0;
    int needs_view = out->offset != 0;
    size_t count = 0;
    if (out->length < 0 || out->offset < 0 || out->offset > INT64_MAX - out->length ||
        !out->children || out->n_children != scan->schema.n_children) {
        scan->validation_error = "Invalid Arrow record batch";
    } else if (out->null_count > 0 || (out->null_count < 0 && bd_bitmap_null_count(out))) {
        scan->validation_error = "Arrow record batch contains null rows";
    } else {
        for (int64_t i = 0; i < out->n_children; i++) {
            struct ArrowArray *child = out->children[i];
            rc = bd_inspect_array(child, &count, &needs_view);
            if (rc || child->length < out->length + out->offset) {
                scan->validation_error = "Invalid Arrow record batch child";
                break;
            }
            if (child->length != out->length) needs_view = 1;
        }
    }
    if (!scan->validation_error && needs_view && (rc = bd_make_batch_view(out, count)))
        scan->validation_error = "Allocating Arrow batch descriptors";
    if (!scan->validation_error) {
        for (int64_t i = 0; i < out->n_children; i++) {
            if (bd_list_dictionary_mismatch(scan->schema.children[i], out->children[i])) {
                scan->validation_error = "DuckDB cannot preserve this list's dictionary nulls. Decode the dictionary before import.";
                break;
            }
        }
    }
    if (scan->validation_error) {
        out->release(out);
        scan->error_code = rc ? rc : EINVAL;
        return scan->error_code;
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
    if (rc && scan.error_code) rc = scan.error_code;
    duckdb_disconnect(&source);
    duckdb_close(&db);
    free(scan.child_pointers);
    free(scan.children);
    if (scan.schema.release) scan.schema.release(&scan.schema);
    return rc;
}
