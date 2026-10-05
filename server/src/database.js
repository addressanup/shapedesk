import pg from 'pg';
import { fail } from './errors.js';

export function database(connectionString) {
  const pool = new pg.Pool({ connectionString, max: 4, idleTimeoutMillis: 10000,
    connectionTimeoutMillis: 5000, statement_timeout: 12000 });
  // Never log the error object: it can contain connection or request details.
  pool.on('error', () => console.error('ShapeDesk database connection failed'));
  // A separate small pool prevents license validation from waiting for the same
  // pool slot held by its enclosing transaction when several Macs activate at once.
  const ratePool = new pg.Pool({ connectionString, max: 2, idleTimeoutMillis: 10000,
    connectionTimeoutMillis: 5000, statement_timeout: 12000 });
  ratePool.on('error', () => console.error('ShapeDesk rate limiter connection failed'));
  return {
    pool,
    async close() { await Promise.all([pool.end(), ratePool.end()]); },
    async rate(bucket, limit, seconds) {
      const { rows } = await ratePool.query(`INSERT INTO rate_limits(bucket, starts_at, hits) VALUES ($1, now(), 1)
        ON CONFLICT (bucket) DO UPDATE SET
        hits = CASE WHEN rate_limits.starts_at <= now() - $2 * interval '1 second' THEN 1 ELSE rate_limits.hits + 1 END,
        starts_at = CASE WHEN rate_limits.starts_at <= now() - $2 * interval '1 second' THEN now() ELSE rate_limits.starts_at END
        RETURNING hits`, [bucket, seconds]);
      if (rows[0].hits > limit) fail(429, 'rate_limited');
    },
    async withLicense(id, operation) {
      const client = await pool.connect();
      try {
        await client.query('BEGIN');
        await client.query('INSERT INTO licenses(id) VALUES ($1) ON CONFLICT DO NOTHING', [id]);
        await client.query('SELECT id FROM licenses WHERE id = $1 FOR UPDATE', [id]);
        const query = (sql, values = []) => client.query(sql, [id, ...values]);
        const result = await operation(query);
        await client.query('COMMIT');
        return result;
      } catch (error) {
        await client.query('ROLLBACK').catch(() => {});
        throw error;
      } finally { client.release(); }
    }
  };
}
