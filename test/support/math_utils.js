// Simple JS module for testing imports
export function add(a, b) {
  return a + b;
}

export function multiply(a, b) {
  return a * b;
}

export function fibonacci(n) {
  if (n <= 1) return n;
  let a = 0, b = 1;
  for (let i = 2; i <= n; i++) {
    [a, b] = [b, a + b];
  }
  return b;
}

export const PI = 3.14159265358979;
