// Minimal HTTP API. Port and health route must match the empresa-service component
// (defaults: 8080 and /health).
const http = require('node:http');

const PORT = Number(process.env.PORT) || 8080;

const routes = {
  'GET /health': (req, res) => send(res, 200, { status: 'ok' }),
  'GET /': (req, res) => send(res, 200, { app: '${{ values.name }}', message: 'Olá da Empresa!' }),
};

function send(res, status, body) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(body));
}

http
  .createServer((req, res) => {
    const handler = routes[`${req.method} ${req.url.split('?')[0]}`];
    if (handler) return handler(req, res);
    send(res, 404, { error: 'not found' });
  })
  .listen(PORT, () => console.log(`listening on ${PORT}`));
