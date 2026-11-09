// AWS clients configured from the env vars OpenChoreo injects from the
// aws-s3-bucket and aws-sqs-queue Resources (see openchoreo/components.yaml).
import { S3Client, GetObjectCommand, PutObjectCommand } from '@aws-sdk/client-s3';
import { SQSClient, GetQueueUrlCommand } from '@aws-sdk/client-sqs';

function required(name) {
  const value = process.env[name];
  if (!value) throw new Error(`missing env var ${name}`);
  return value;
}

const credentials = {
  accessKeyId: required('AWS_ACCESS_KEY_ID'),
  secretAccessKey: required('AWS_SECRET_ACCESS_KEY'),
};

export const BUCKET = required('S3_BUCKET');
export const QUEUE_NAME = required('SQS_QUEUE_NAME');

export const s3 = new S3Client({
  endpoint: required('S3_ENDPOINT'),
  region: required('AWS_REGION'),
  credentials,
  forcePathStyle: true, // emulated endpoints have no per-bucket DNS
});

export const sqs = new SQSClient({
  endpoint: required('SQS_ENDPOINT'),
  region: required('AWS_REGION'),
  credentials,
  // Keep requests on the configured endpoint; the queue URL's host is the
  // emulator's own name, which pods cannot resolve.
  useQueueUrlAsEndpoint: false,
});

let queueUrl;
export async function getQueueUrl() {
  queueUrl ??= (await sqs.send(new GetQueueUrlCommand({ QueueName: QUEUE_NAME }))).QueueUrl;
  return queueUrl;
}

export async function getJson(key) {
  try {
    const res = await s3.send(new GetObjectCommand({ Bucket: BUCKET, Key: key }));
    return JSON.parse(await res.Body.transformToString());
  } catch (err) {
    if (err.name === 'NoSuchKey' || err.$metadata?.httpStatusCode === 404) return null;
    throw err;
  }
}

export function putJson(key, value) {
  return s3.send(new PutObjectCommand({
    Bucket: BUCKET,
    Key: key,
    Body: JSON.stringify(value),
    ContentType: 'application/json',
  }));
}
