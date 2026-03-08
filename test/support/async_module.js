// Module testing async/promise functionality
globalThis.asyncAdd = (a, b) => {
  return new Promise((resolve) => {
    setTimeout(() => resolve(a + b), 10);
  });
};

globalThis.asyncFail = () => {
  return new Promise((_, reject) => {
    setTimeout(() => reject("intentional error"), 10);
  });
};

globalThis.fetchJson = async (url) => {
  const response = await fetch(url);
  return await response.json();
};
