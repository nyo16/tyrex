// Test Node.js API compatibility
import { join, basename } from "node:path";
import { Buffer } from "node:buffer";

globalThis.testNodePath = () => {
  return join("foo", "bar", "baz.js");
};

globalThis.testNodeBasename = () => {
  return basename("/path/to/file.txt");
};

globalThis.testNodeBuffer = () => {
  const buf = Buffer.from("hello tyrex");
  return buf.toString("base64");
};
