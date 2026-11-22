#include "arrow.h"

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(expr) do { if (!(expr)) { \
    fprintf(stderr, "line %d: %s\n", __LINE__, #expr); exit(1); \
} } while (0)

static struct ArrowArrayStream query(duckdb_connection con, const char *sql) {
    struct ArrowArrayStream stream;
    char *error = NULL;
    int rc = bd_arrow_query(con, sql, &stream, &error);
    if (rc) fprintf(stderr, "%s\n", error ? error : "unknown query error");
    free(error);
    CHECK(!rc);
    return stream;
}

static int64_t scalar(duckdb_connection con, const char *sql) {
    duckdb_result result = {0};
    if (duckdb_query(con, sql, &result)) {
        fprintf(stderr, "%s\n", duckdb_result_error(&result));
        exit(1);
    }
    int64_t value = duckdb_value_int64(&result, 0, 0);
    duckdb_destroy_result(&result);
    return value;
}

static void import(duckdb_connection con, const char *name, struct ArrowArrayStream *stream) {
    char *error = NULL;
    int rc = bd_arrow_import(con, name, stream, &error);
    if (rc) fprintf(stderr, "%s\n", error ? error : "unknown import error");
    free(error);
    CHECK(!rc);
}

static void check_exports(duckdb_connection con) {
    struct ArrowArrayStream stream = query(con,
        "SELECT i AS id, [i::INTEGER] xs FROM range(10000) t(i)");
    struct ArrowSchema schema = {0};
    struct ArrowArray first = {0}, batch = {0};
    CHECK(!stream.get_schema(&stream, &schema));
    CHECK(!stream.get_next(&stream, &first) && first.release);
    int batches = 1;
    int64_t count = first.length;
    while (1) {
        CHECK(!stream.get_next(&stream, &batch));
        if (!batch.release) break;
        count += batch.length;
        batches++;
        batch.release(&batch);
    }
    CHECK(count == 10000 && batches > 1);
    stream.release(&stream);
    CHECK(!stream.release && !strcmp(schema.children[1]->children[0]->format, "i"));
    CHECK(((const int64_t *)first.children[0]->buffers[1])[3] == 3);
    CHECK(((const int32_t *)first.children[1]->children[0]->buffers[1])[2] == 2);
    first.release(&first);
    schema.release(&schema);

    char *error = NULL;
    CHECK(bd_arrow_query(con, "SELECT bad_column", &stream, &error));
    CHECK(!stream.release && error && strstr(error, "bad_column"));
    free(error);
}

typedef struct { struct ArrowArrayStream source; unsigned yielded; } TestProducer;
static int test_schema(struct ArrowArrayStream *s, struct ArrowSchema *out) {
    TestProducer *p = s->private_data;
    return p->source.get_schema(&p->source, out);
}
static int broken_next(struct ArrowArrayStream *s, struct ArrowArray *out) {
    TestProducer *p = s->private_data;
    if (p->yielded++ == 1) return ECANCELED;
    return p->source.get_next(&p->source, out);
}
static int sliced_next(struct ArrowArrayStream *s, struct ArrowArray *out) {
    TestProducer *p = s->private_data;
    int rc = p->source.get_next(&p->source, out);
    if (!rc && out->release) {
        out->offset = 3;
        out->length = 4;
    }
    return rc;
}
static void omit_dictionary_counts(struct ArrowArray *array) {
    if (array->dictionary) array->null_count = -1;
    for (int64_t i = 0; i < array->n_children; i++) omit_dictionary_counts(array->children[i]);
}
static int unknown_count_next(struct ArrowArrayStream *s, struct ArrowArray *out) {
    TestProducer *p = s->private_data;
    int rc = p->source.get_next(&p->source, out);
    if (!rc && out->release) omit_dictionary_counts(out);
    return rc;
}
static const char *broken_error(struct ArrowArrayStream *s) { (void)s; return "source stopped"; }
static void test_release(struct ArrowArrayStream *s) {
    TestProducer *p = s->private_data;
    p->source.release(&p->source);
    s->release = NULL;
}

static void check_imports(duckdb_connection con) {
    const char *sql = "SELECT i, CASE WHEN i%2=0 THEN 'hello' END AS s, "
                      "[i::INTEGER] AS xs, i::DECIMAL(16,3) AS d FROM range(10000) t(i)";
    struct ArrowArrayStream stream = query(con, sql);
    import(con, "target \" quoted", &stream);
    CHECK(stream.release);
    stream.release(&stream);
    CHECK(scalar(con, "SELECT COUNT(s) FROM \"target \"\" quoted\"") == 5000);
    CHECK(scalar(con, "SELECT SUM(xs[1]) FROM \"target \"\" quoted\"") == 49995000);
    CHECK(scalar(con, "SELECT COUNT(*) FROM \"target \"\" quoted\" WHERE typeof(d)='DECIMAL(16,3)'") == 10000);

    stream = query(con, "SELECT 1 AS x WHERE FALSE");
    import(con, "empty", &stream);
    stream.release(&stream);
    CHECK(scalar(con, "SELECT COUNT(x) FROM empty") == 0);

    char *error = NULL;
    stream = query(con, "SELECT 1 AS col");
    CHECK(bd_arrow_import(con, "empty", &stream, &error) && error);
    free(error);
    stream.release(&stream);
    CHECK(scalar(con, "SELECT COUNT(x) FROM empty") == 0);

    TestProducer window = {.source = query(con, "SELECT i FROM range(10) t(i)")};
    struct ArrowArrayStream sliced = {test_schema, sliced_next, broken_error, test_release, &window};
    import(con, "sliced", &sliced);
    sliced.release(&sliced);
    CHECK(scalar(con, "SELECT sum(i) FROM sliced") == 18);

    const char *enums = "SELECT CASE WHEN i%2=0 THEN 'a'::ENUM('a','b') END AS e FROM range(17) t(i)";
    TestProducer sliced_enum = {.source = query(con, enums)};
    struct ArrowArrayStream enum_window = {test_schema, sliced_next, broken_error, test_release, &sliced_enum};
    import(con, "sliced_enums", &enum_window);
    enum_window.release(&enum_window);
    CHECK(scalar(con, "SELECT count(e) FROM sliced_enums") == 2);

    const char *nested_enums = "SELECT e, {'f': e} AS s, [e] AS xs FROM "
                               "(SELECT CASE WHEN i%2=0 THEN 'a'::ENUM('a','b') END AS e FROM range(17) t(i))";
    TestProducer unknown = {.source = query(con, nested_enums)};
    struct ArrowArrayStream dictionary = {test_schema, unknown_count_next, broken_error, test_release, &unknown};
    import(con, "nullable_enums", &dictionary);
    dictionary.release(&dictionary);
    CHECK(scalar(con, "SELECT count(e) FROM nullable_enums") == 9);
    CHECK(scalar(con, "SELECT count(s.f) FROM nullable_enums") == 9);
    CHECK(scalar(con, "SELECT count(xs[1]) FROM nullable_enums") == 9);

    TestProducer nested_window = {.source = query(con, nested_enums)};
    struct ArrowArrayStream list_window = {test_schema, sliced_next, broken_error, test_release, &nested_window};
    CHECK(bd_arrow_import(con, "sliced_lists", &list_window, &error) == EINVAL);
    CHECK(error && strstr(error, "dictionary nulls"));
    free(error);
    list_window.release(&list_window);
    CHECK(!scalar(con, "SELECT count(*) FROM duckdb_tables() WHERE table_name='sliced_lists'"));

    TestProducer aligned = {.source = query(con, "SELECT [CASE WHEN i%3=0 THEN 'a'::ENUM('a','b') END] AS xs "
                                                 "FROM range(17) t(i)")};
    struct ArrowArrayStream aligned_window = {test_schema, sliced_next, broken_error, test_release, &aligned};
    import(con, "aligned_lists", &aligned_window);
    aligned_window.release(&aligned_window);
    CHECK(scalar(con, "SELECT count(xs[1]) FROM aligned_lists") == 2);

    CHECK(!duckdb_query(con, "CREATE TABLE marker(n INT); BEGIN; INSERT INTO marker VALUES (5)", NULL));
    TestProducer bad = {.source = query(con, sql)};
    struct ArrowArrayStream broken = {test_schema, broken_next, broken_error, test_release, &bad};
    CHECK(bd_arrow_import(con, "incomplete", &broken, &error) == ECANCELED);
    CHECK(error && strstr(error, "source stopped"));
    free(error);
    broken.release(&broken);
    CHECK(!scalar(con, "SELECT COUNT(*) FROM duckdb_tables() WHERE table_name='incomplete'"));
    CHECK(scalar(con, "SELECT COUNT(*) FROM marker") == 1);
    stream = query(con, "SELECT 2 AS x");
    import(con, "transient", &stream);
    stream.release(&stream);
    CHECK(!duckdb_query(con, "ROLLBACK", NULL));
    CHECK(!scalar(con, "SELECT COUNT(*) FROM marker"));
    CHECK(!scalar(con, "SELECT COUNT(*) FROM duckdb_tables() WHERE table_name='transient'"));
}

int main(void) {
    duckdb_database db = NULL;
    duckdb_connection con = NULL;
    CHECK(!duckdb_open(NULL, &db) && !duckdb_connect(db, &con));
    check_exports(con);
    check_imports(con);
    duckdb_disconnect(&con);
    duckdb_close(&db);
    puts("Arrow C stream tests passed");
    return 0;
}
