// Example: Data processing utilities loaded as main module
// Demonstrates using JS libraries for data transformation

// CSV parser (simple)
globalThis.parseCSV = (csv) => {
  const lines = csv.trim().split("\n");
  const headers = lines[0].split(",").map((h) => h.trim());
  return lines.slice(1).map((line) => {
    const values = line.split(",").map((v) => v.trim());
    return Object.fromEntries(headers.map((h, i) => [h, values[i]]));
  });
};

// JSON transformer
globalThis.transformData = (data, mapping) => {
  if (typeof data === "string") data = JSON.parse(data);
  if (typeof mapping === "string") mapping = JSON.parse(mapping);

  return data.map((item) => {
    const result = {};
    for (const [newKey, oldKey] of Object.entries(mapping)) {
      result[newKey] = item[oldKey];
    }
    return result;
  });
};

// Statistics
globalThis.stats = (numbers) => {
  if (typeof numbers === "string") numbers = JSON.parse(numbers);
  const sorted = [...numbers].sort((a, b) => a - b);
  const sum = sorted.reduce((a, b) => a + b, 0);
  const mean = sum / sorted.length;
  const median =
    sorted.length % 2 === 0
      ? (sorted[sorted.length / 2 - 1] + sorted[sorted.length / 2]) / 2
      : sorted[Math.floor(sorted.length / 2)];
  const variance =
    sorted.reduce((acc, val) => acc + Math.pow(val - mean, 2), 0) /
    sorted.length;
  return {
    count: sorted.length,
    sum,
    mean,
    median,
    min: sorted[0],
    max: sorted[sorted.length - 1],
    stddev: Math.sqrt(variance),
  };
};

// String sanitization
globalThis.sanitizeHtml = (html) => {
  return html
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#039;");
};

// URL parsing
globalThis.parseUrl = (url) => {
  const parsed = new URL(url);
  return {
    protocol: parsed.protocol,
    host: parsed.host,
    pathname: parsed.pathname,
    search: parsed.search,
    params: Object.fromEntries(parsed.searchParams),
  };
};
