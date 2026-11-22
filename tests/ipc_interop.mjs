// Run the pure codecs from Bend's generated module without its native backend.
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { pathToFileURL } from 'node:url';

const [modulePath, format, input, output] = process.argv.slice(2);
if (!output || !['ipc', 'parquet'].includes(format)) {
  throw new Error('usage: node ipc_interop.mjs <compiled.mjs> <ipc|parquet> <input> <output>');
}
const { default: codecs } = await import(pathToFileURL(resolve(modulePath)));

function unwrap(result) {
  if (result.$ === 'Fail') throw new Error(result.error.snd);
  return result.value;
}

let bytes = { $: 'Nil' };
const data = readFileSync(input);
for (let i = data.length - 1; i >= 0; i--) {
  bytes = { $: 'Con', head: data[i], tail: bytes };
}
const table = unwrap(codecs.decode(format, bytes));
for (const [writer, suffix] of [['ipc', '.arrows'], ['parquet', '.parquet']]) {
  let encoded = unwrap(codecs[`../src/${writer}_write:encode`](table));
  const result = [];
  while (encoded.$ === 'Con') {
    result.push(encoded.head);
    encoded = encoded.tail;
  }
  writeFileSync(output + suffix, Buffer.from(result), { flag: 'wx' });
}
