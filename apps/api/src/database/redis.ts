import {Redis} from 'ioredis';
import type {RedisOptions} from 'ioredis';

import {REDIS_URL} from '../app/constants.js';

export const redis = new Redis(REDIS_URL + '?family=0');

/**
 * Builds ioredis connection options for BullMQ (Queue/Worker), which accept a
 * plain options object rather than a URL string. Preserves the `rediss:` TLS
 * scheme, which is otherwise silently dropped and causes the Redis server to
 * reset the connection (ECONNRESET) when the provider requires TLS.
 */
export function getBullMqRedisOptions(url: string): RedisOptions {
  const parsed = new URL(url);

  return {
    host: parsed.hostname,
    port: parseInt(parsed.port || '6379', 10),
    password: parsed.password || undefined,
    db: parseInt(parsed.pathname.slice(1) || '0', 10),
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
