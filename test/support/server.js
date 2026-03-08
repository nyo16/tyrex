// Simple HTTP server for testing Deno.serve
const port = parseInt(Deno.args[0] || "8765");

globalThis.startServer = () => {
  return Deno.serve({ port }, (req) => {
    const url = new URL(req.url);
    if (url.pathname === "/json") {
      return new Response(JSON.stringify({ status: "ok" }), {
        headers: { "content-type": "application/json" },
      });
    }
    return new Response("Hello from Tyrex!");
  });
};
