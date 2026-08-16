// Allocates without bound at module-evaluation time, so a :max_heap_mb trip
// happens inside `worker::new` (before the runtime is ever handed to the
// caller) rather than inside a later `Tyrex.eval`. Used to pin the startup
// heap-trip attribution; nothing else should import it.
const chunks = [];
for (;;) {
  chunks.push(new Array(1_000_000).fill(7));
}
