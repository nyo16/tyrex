import { valueA } from "./import_a.js";

export const valueB = `${valueA} and B`;
export function getB() {
  return valueB;
}
