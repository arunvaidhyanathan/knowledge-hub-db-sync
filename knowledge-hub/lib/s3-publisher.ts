import fs from 'node:fs';
import { GetObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';

export interface StoreConfig {
  endpoint: string;       // e.g. https://s3.<region>.cloud-object-storage.appdomain.cloud or the on-prem endpoint
  region: string;
  bucket: string;
  prefix: string;         // e.g. knowledge-hub
  publicBaseUrl: string;  // what browsers use to load assets (CDN, proxy or bucket URL)
}

export function storeConfigFromEnv(): StoreConfig {
  const need = (k: string) => {
    const v = process.env[k];
    if (!v) throw new Error(`Missing env ${k}`);
    return v;
  };
  return {
    endpoint: need('KH_S3_ENDPOINT'),
    region: process.env.KH_S3_REGION ?? 'us-east-1',
    bucket: need('KH_S3_BUCKET'),
    prefix: (process.env.KH_S3_PREFIX ?? 'knowledge-hub').replace(/^\/+|\/+$/g, ''),
    publicBaseUrl: need('KH_PUBLIC_BASE_URL').replace(/\/+$/, ''),
  };
}

/** S3-compatible client using HMAC keys (IBM COS supports the S3 API with HMAC credentials). */
export function createClient(cfg: StoreConfig): S3Client {
  const missing = ['KH_S3_ACCESS_KEY_ID', 'KH_S3_SECRET_ACCESS_KEY'].filter((k) => !process.env[k]);
  if (missing.length) throw new Error(`Missing env ${missing.join(', ')}`);
  return new S3Client({
    endpoint: cfg.endpoint,
    region: cfg.region,
    forcePathStyle: true,
    credentials: {
      accessKeyId: process.env.KH_S3_ACCESS_KEY_ID!,
      secretAccessKey: process.env.KH_S3_SECRET_ACCESS_KEY!,
    },
  });
}

export async function putFile(client: S3Client, cfg: StoreConfig, key: string, file: string, contentType: string, immutable: boolean): Promise<string> {
  await client.send(
    new PutObjectCommand({
      Bucket: cfg.bucket,
      Key: key,
      Body: fs.readFileSync(file),
      ContentType: contentType,
      CacheControl: immutable ? 'public, max-age=31536000, immutable' : 'no-cache',
    }),
  );
  return `${cfg.publicBaseUrl}/${key}`;
}

export async function putJson(client: S3Client, cfg: StoreConfig, key: string, value: unknown): Promise<void> {
  await client.send(
    new PutObjectCommand({
      Bucket: cfg.bucket,
      Key: key,
      Body: JSON.stringify(value, null, 2),
      ContentType: 'application/json',
      CacheControl: 'no-cache',
    }),
  );
}

export async function getJson<T>(client: S3Client, cfg: StoreConfig, key: string): Promise<T | undefined> {
  try {
    const res = await client.send(new GetObjectCommand({ Bucket: cfg.bucket, Key: key }));
    const text = await res.Body?.transformToString();
    return text ? (JSON.parse(text) as T) : undefined;
  } catch (err: any) {
    if (err?.name === 'NoSuchKey' || err?.$metadata?.httpStatusCode === 404) return undefined;
    throw err;
  }
}
