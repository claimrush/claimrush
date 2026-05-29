-- ClaimRush v1.0.0 Panel
-- Furnace bonus split (24h, single row)

-- Data source:
-- - Uses Furnace_evt_BonusPaid for exact split of gross bonus -> user vs LP.
-- - Under LP streaming (v1.0.0+), `lpTopupClaim` is CLAIM funded into the Furnace LP stream
--   (it is streamed to stakers over time, not necessarily transferred immediately).

-- Outputs:
--   user_bonus_24h:      user portion of gross bonus (headline / UI number)
--   lp_topup_24h:        LP portion of gross bonus (funded into LP stream)
--   gross_spent_24h:     gross bonus drawn from reserve (user + LP)

-- Parameters:
--   {{FURNACE_START_BLOCK}} (integer)
-- Replace <DUNE_SCHEMA> with your decoded contract schema.

SELECT
  COALESCE(SUM(userBonusClaim), 0) AS user_bonus_24h,
  COALESCE(SUM(lpTopupClaim), 0) AS lp_topup_24h,
  COALESCE(SUM(grossBonusClaim), 0) AS gross_spent_24h
FROM <DUNE_SCHEMA>.Furnace_evt_BonusPaid
WHERE evt_block_number >= {{FURNACE_START_BLOCK}}
  AND evt_block_time >= date_add('hour', -24, now());
