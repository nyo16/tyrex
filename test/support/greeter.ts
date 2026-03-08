// Simple TypeScript module for testing TS support
interface Greeting {
  message: string;
  timestamp: number;
}

export function greet(name: string): Greeting {
  return {
    message: `Hello, ${name}!`,
    timestamp: Date.now(),
  };
}

export function greetAll(names: string[]): string[] {
  return names.map((name) => `Hello, ${name}!`);
}

export const VERSION: string = "1.0.0";
