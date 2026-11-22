function native_only() {
  return {$: CID(Fail), error: io_tup(38, "DuckDB requires the Bend native target. Build with make.")};
}

io_eff(CID(open_id), native_only);
io_eff(CID(exec_id), native_only);
io_eff(CID(query_id), native_only);
io_eff(CID(close_id), native_only);
