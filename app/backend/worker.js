// Queue worker: takes document ids from SQS, analyses the text stored in S3
// and writes the result next to it (results/<id>.json).
import os from 'node:os';
import { ReceiveMessageCommand, DeleteMessageCommand } from '@aws-sdk/client-sqs';
import { BUCKET, sqs, getQueueUrl, getJson, putJson } from './aws.js';

// Simulated processing time, so the UI shows documents waiting in the queue.
const DELAY_MS = Number(process.env.PROCESSING_DELAY_MS ?? 3000);
const STOPWORDS = new Set(('a o e de da do das dos em no na nos nas um uma para por com que se ' +
  'the and of to in is it for on with as was are be this that').split(' '));

let running = true;
process.on('SIGTERM', () => { running = false; });

function analyse(text) {
  const words = text.toLowerCase().match(/[\p{L}\p{N}']+/gu) ?? [];
  const counts = new Map();
  for (const w of words) {
    if (w.length > 2 && !STOPWORDS.has(w)) counts.set(w, (counts.get(w) ?? 0) + 1);
  }
  const topWords = [...counts.entries()]
    .sort((a, b) => b[1] - a[1] || a[0].localeCompare(b[0]))
    .slice(0, 5)
    .map(([word, count]) => ({ word, count }));
  return {
    lines: text.split(/\r?\n/).length,
    words: words.length,
    characters: [...text].length,
    readingTimeSeconds: Math.max(1, Math.round(words.length / 200 * 60)),
    topWords,
  };
}

async function handle(message) {
  const { id } = JSON.parse(message.Body);
  const doc = await getJson(`uploads/${id}.json`);
  if (!doc) {
    console.warn(`document ${id} not found, dropping message`);
    return;
  }
  await new Promise((r) => setTimeout(r, DELAY_MS));
  await putJson(`results/${id}.json`, {
    ...analyse(doc.content),
    processedAt: new Date().toISOString(),
    processedBy: os.hostname(),
  });
  console.log(`processed ${id} (${doc.name})`);
}

async function main() {
  const queueUrl = await getQueueUrl();
  console.log(`doc-insights worker polling ${queueUrl}, bucket ${BUCKET}`);
  while (running) {
    try {
      const { Messages = [] } = await sqs.send(new ReceiveMessageCommand({
        QueueUrl: queueUrl,
        MaxNumberOfMessages: 5,
        WaitTimeSeconds: 10,
      }));
      for (const message of Messages) {
        await handle(message);
        // Only acknowledged after the result is stored; failures are redelivered.
        await sqs.send(new DeleteMessageCommand({ QueueUrl: queueUrl, ReceiptHandle: message.ReceiptHandle }));
      }
    } catch (err) {
      console.error('poll failed:', err.message);
      await new Promise((r) => setTimeout(r, 5000));
    }
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
