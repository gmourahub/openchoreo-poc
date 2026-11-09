// HTTP API: stores submitted documents in S3 and enqueues them for analysis.
//   GET  /api/health
//   GET  /api/docs        -> latest documents with their analysis (if done)
//   POST /api/docs        -> { name, content } ; 202 + { id }
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { ListObjectsV2Command } from '@aws-sdk/client-s3';
import { SendMessageCommand } from '@aws-sdk/client-sqs';
import { BUCKET, s3, sqs, getQueueUrl, getJson, putJson } from './aws.js';

const PORT = Number(process.env.PORT ?? 8080);
const MAX_BYTES = 256 * 1024;
const LIST_LIMIT = 30;

function send(res, status, body) {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(body));
}

async function readJson(req) {
  let size = 0;
  const chunks = [];
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BYTES) throw Object.assign(new Error('document too large (max 256 KB)'), { status: 413 });
    chunks.push(chunk);
  }
  try {
    return JSON.parse(Buffer.concat(chunks).toString('utf8'));
  } catch {
    throw Object.assign(new Error('body must be JSON'), { status: 400 });
  }
}

async function createDoc(req, res) {
  const { name, content } = await readJson(req);
  if (typeof content !== 'string' || !content.trim()) {
    return send(res, 400, { error: 'content is required' });
  }
  const doc = {
    id: randomUUID(),
    name: (typeof name === 'string' && name.trim()) ? name.trim().slice(0, 120) : 'sem-titulo.txt',
    content,
    uploadedAt: new Date().toISOString(),
  };
  await putJson(`uploads/${doc.id}.json`, doc);
  await sqs.send(new SendMessageCommand({
    QueueUrl: await getQueueUrl(),
    MessageBody: JSON.stringify({ id: doc.id }),
  }));
  console.log(`stored and enqueued ${doc.id} (${doc.name})`);
  send(res, 202, { id: doc.id });
}

async function listDocs(res) {
  const listing = await s3.send(new ListObjectsV2Command({ Bucket: BUCKET, Prefix: 'uploads/' }));
  const keys = (listing.Contents ?? [])
    .sort((a, b) => b.LastModified - a.LastModified)
    .slice(0, LIST_LIMIT)
    .map((o) => o.Key);
  const docs = await Promise.all(keys.map(async (key) => {
    const doc = await getJson(key);
    if (!doc) return null;
    const result = await getJson(`results/${doc.id}.json`);
    return {
      id: doc.id,
      name: doc.name,
      uploadedAt: doc.uploadedAt,
      bytes: Buffer.byteLength(doc.content),
      status: result ? 'processed' : 'pending',
      result,
    };
  }));
  send(res, 200, docs.filter(Boolean));
}

const server = http.createServer(async (req, res) => {
  try {
    const { pathname } = new URL(req.url, 'http://local');
    if (req.method === 'GET' && pathname === '/api/health') return send(res, 200, { ok: true, bucket: BUCKET });
    if (req.method === 'GET' && pathname === '/api/docs') return await listDocs(res);
    if (req.method === 'POST' && pathname === '/api/docs') return await createDoc(req, res);
    send(res, 404, { error: 'not found' });
  } catch (err) {
    if (!err.status) console.error(`error: ${req.method} ${req.url} failed: ${err.name}: ${err.message}`);
    send(res, err.status ?? 500, { error: err.status ? err.message : 'internal error' });
  }
});

server.listen(PORT, () => console.log(`doc-insights api on :${PORT}, bucket ${BUCKET}`));
process.on('SIGTERM', () => server.close(() => process.exit(0)));
