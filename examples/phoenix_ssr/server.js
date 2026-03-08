// Example: Simple SSR-like template rendering
// This demonstrates how you might use Tyrex for server-side rendering

// Simple template engine
globalThis.renderTemplate = (template, data) => {
  return template.replace(/\{\{(\w+)\}\}/g, (match, key) => {
    return data[key] !== undefined ? String(data[key]) : match;
  });
};

// HTML component rendering
globalThis.renderComponent = (component, props) => {
  const components = {
    greeting: (p) => `<div class="greeting"><h1>Hello, ${p.name}!</h1><p>Welcome to ${p.app}</p></div>`,
    card: (p) => `<div class="card"><h2>${p.title}</h2><p>${p.body}</p></div>`,
    list: (p) => `<ul>${p.items.map(i => `<li>${i}</li>`).join("")}</ul>`,
    page: (p) => `<!DOCTYPE html>
<html>
<head><title>${p.title}</title></head>
<body>${p.content}</body>
</html>`,
  };

  const renderer = components[component];
  if (!renderer) throw new Error(`Unknown component: ${component}`);
  return renderer(typeof props === "string" ? JSON.parse(props) : props);
};

// Markdown-like to HTML converter
globalThis.markdownToHtml = (markdown) => {
  return markdown
    .replace(/^### (.+)$/gm, "<h3>$1</h3>")
    .replace(/^## (.+)$/gm, "<h2>$1</h2>")
    .replace(/^# (.+)$/gm, "<h1>$1</h1>")
    .replace(/\*\*(.+?)\*\*/g, "<strong>$1</strong>")
    .replace(/\*(.+?)\*/g, "<em>$1</em>")
    .replace(/`(.+?)`/g, "<code>$1</code>")
    .replace(/\n/g, "<br>");
};
