import { readFileSync, writeFileSync } from 'node:fs';

// Tapflow 0.20.1 binds to all interfaces and exposes no host option.
// Keep this pilot accessible only on this Mac until remote access is configured.
const file = new URL('./node_modules/@tapflowio/relay/dist/RelayServer.js', import.meta.url);
const original = "this.httpServer.listen({ port: this.options.port, host: '::', ipv6Only: false }, resolve);";
const local = "this.httpServer.listen({ port: this.options.port, host: '127.0.0.1' }, resolve);";
const source = readFileSync(file, 'utf8');
if (source.includes(local)) {
  console.log('Tapflow already binds to loopback only.');
} else if (source.split(original).length === 2) {
  writeFileSync(file, source.replace(original, local));
  console.log('Configured Tapflow to bind to 127.0.0.1 only.');
} else {
  throw new Error('Tapflow listener changed; inspect it before starting the host.');
}
