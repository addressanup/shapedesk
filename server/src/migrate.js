import { readFile } from 'node:fs/promises';
import pg from 'pg';
const client = new pg.Client({ connectionString: process.env.DATABASE_URL });
try {
  await client.connect();
  await client.query('BEGIN');
  await client.query(await readFile(new URL('../schema.sql', import.meta.url), 'utf8'));
  await client.query('COMMIT');
  console.log('ShapeDesk Pro schema is ready.');
} catch {
  console.error('ShapeDesk migration failed. Check the private database configuration.');
  process.exitCode = 1;
} finally { await client.end(); }
