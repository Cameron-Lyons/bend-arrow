function nativeOnly() {
  return { $: CID(Fail), error: io_tup(38, "Arrow streams require the native Bend build (scripts/build).") };
}
io_eff(CID(query_id), nativeOnly);
io_eff(CID(import_id), nativeOnly);
io_eff(CID(close_id), nativeOnly);
