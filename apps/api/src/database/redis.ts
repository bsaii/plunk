import {Redis} from 'ioredis';
import type {RedisOptions} from 'ioredis';

import {REDIS_URL} from '../app/constants.js';

/**
 * Forces IPv4 (`family: 4`, ioredis's own default — made explicit here so it can't
 * regress). Providers like Aiven publish both A and AAAA records for their `rediss:`
 * endpoints; Node's Happy Eyeballs dual-stack fallback only applies to plain
 * `net.connect()`, not `tls.connect()`, so a TLSSocket that resolves to an AAAA record
 * on a network without IPv6 egress (e.g. Cloud Run's default networking) just hangs
 * until the OS gives up, surfacing as `connect ETIMEDOUT` minutes later instead of a
 * fast failure.
 */
export const redis = new Redis(REDIS_URL, {family: 4});

/**
 * Builds ioredis connection options for BullMQ (Queue/Worker), which accept a
 * plain options object rather than a URL string. Preserves the `rediss:` TLS
 * scheme, which is otherwise silently dropped and causes the Redis server to
 * reset the connection (ECONNRESET) when the provider requires TLS. Also forces
 * IPv4 — see the comment on `redis` above for why.
 */
export function getBullMqRedisOptions(url: string): RedisOptions {
  const parsed = new URL(url);

  return {
    host: parsed.hostname,
    port: parseInt(parsed.port || '6379', 10),
    password: parsed.password || undefined,
    db: parseInt(parsed.pathname.slice(1) || '0', 10),
    family: 4,
    ...(parsed.protocol === 'rediss:' ? {tls: {}} : {}),
  };
}

export const REDIS_ONE_MINUTE = 60;
export const REDIS_DEFAULT_EXPIRY = REDIS_ONE_MINUTE;
export const TEN_MINUTES_IN_SECONDS = 60 * 10;

/**
 * @param key The key for redis (use Keys#<type>)
 * @param fn The function to return a resource. Can be a promise
 * @param seconds The amount of seconds to hold this resource in redis for. Defaults to 60
 */
export async function wrapRedis<T>(key: string, fn: () => Promise<T>, seconds = REDIS_DEFAULT_EXPIRY): Promise<T> {
  const cached = await redis.get(key);
  if (cached) {
    return JSON.parse(cached);
  }

  const recent = await fn();

  if (recent) {
    await redis.set(key, JSON.stringify(recent), 'EX', seconds);
  }

  return recent;
}

export const cache = {
  set<T>(key: string, value: T, seconds = REDIS_DEFAULT_EXPIRY): Promise<'OK' | null> {
    return redis.set(key, JSON.stringify(value), 'EX', seconds);
  },
  incr(key: string): Promise<number> {
    return redis.incr(key);
  },
  decr(key: string): Promise<number> {
    return redis.decr(key);
  },
};
