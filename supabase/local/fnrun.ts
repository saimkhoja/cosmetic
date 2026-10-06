// Runs one Edge Function locally on a given port: deno run -A fnrun.ts <name> <port>
const [name, port] = Deno.args;
const serve = Deno.serve.bind(Deno);
// deno-lint-ignore no-explicit-any
(Deno as any).serve = (h: Deno.ServeHandler) => serve({ port: Number(port), onListen: () => console.log(`${name} on ${port}`) }, h);
await import(`../functions/${name}/index.ts`);
