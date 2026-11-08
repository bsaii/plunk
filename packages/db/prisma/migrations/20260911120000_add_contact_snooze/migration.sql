-- Snoozing: a temporary unsubscribe that ends by itself.
--
-- A snooze is deliberately NOT a third subscription state. It is the existing
-- `subscribed = false` plus a date saying when to undo it. That choice is the whole
-- design: every send path already filters `subscribed = true` (campaign recipient
-- selection, the transactional marketing-template guard, the workflow send guard), so a
-- snoozed contact is suppressed correctly and completely without a single one of those
-- paths learning that this column exists. A third enum state would have required auditing
-- and changing all of them, and any path missed would have mailed someone who asked not to
-- be mailed.
--
-- The inverse obligation is that `snoozedUntil` must be cleared by every other write to
-- `subscribed` -- most importantly the bounce and complaint paths in the SES webhook.
-- Without that, a hard-bounced address that happened to be snoozed would be resubscribed by
-- the sweep and mailed again, which is exactly the reputation damage suppression exists to
-- prevent. That is enforced in application code; this migration only adds the column.
--
-- No backfill migration accompanies this one. NULL is correct for every existing row by
-- definition -- nobody has snoozed yet -- which is also why the column is nullable rather
-- than NOT NULL with a default.
--
-- Adding a nullable column with no default is catalog-only on PostgreSQL: no table rewrite
-- and no row-level work, so the ALTER takes milliseconds on a contacts table with millions
-- of rows.

-- No lock_timeout here on purpose, matching the campaign migrations. Fail-fast is the wrong
-- trade for this deployment model: the container entrypoint runs `migrate deploy` at start
-- and refuses to boot on failure, so a migration that gives up on a lock does not degrade
-- gracefully, it crash-loops the service until a human clears the failed row by hand.

-- AlterTable
ALTER TABLE "contacts"
  ADD COLUMN "snoozedUntil" TIMESTAMP(3);

-- Serves the only query that reads this column in bulk: the snooze sweep's
-- "WHERE snoozedUntil <= now() ORDER BY snoozedUntil ASC LIMIT n", which runs every five
-- minutes and must not degrade into a sequential scan of the contacts table.
--
-- A partial index (WHERE "snoozedUntil" IS NOT NULL) would be far smaller, since snoozed
-- contacts are a tiny minority of rows. It is not used here because Prisma cannot express a
-- partial index in the schema, so the next `migrate dev` diff would see it as drift and
-- generate a migration dropping it. A plain index that Prisma can model is worth more than
-- the bytes saved.
--
-- Plain CREATE INDEX rather than CONCURRENTLY: Prisma wraps a migration in a single
-- transaction and CONCURRENTLY is illegal inside one.

-- CreateIndex
CREATE INDEX "contacts_snoozedUntil_idx" ON "contacts"("snoozedUntil");
