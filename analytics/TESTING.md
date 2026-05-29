# Analytics testing (v1.0.0)

Goal:
- Ensure multi-row analytics outputs are correct, stable under pagination, and match the on-chain sources.

Policy:
- No address exclusions are applied in v1.0.0 leaderboards.
- Do not "hide" rows client-side. Compute leaderboards in the query/indexer layer.

## CI gate (REQUIRED)

Run:

```bash
make analytics-lint
```

## Coverage expectations (REQUIRED)

For every multi-row analytics output (Dune leaderboard templates 01-08, the recent reigns list, and every "top N" list in this repo):

- Each output has at least one fixture test that returns `N` rows.
- Each output has at least one fixture test that returns fewer than `N` rows.
- Each output has at least one pagination regression test that checks:
  - no duplicates across pages
  - no missing rows across pages
  - deterministic tie-break (secondary sort by address)


## Backend/indexer tests (REQUIRED)

For every multi-row endpoint that returns addresses:
- Dune leaderboard templates 01-08
- recent reigns list
- any "top N" lists in this repo

Add tests that assert:

- **Row count behavior**
  - When at least N eligible addresses exist, the endpoint returns exactly N rows.
  - When fewer than N eligible addresses exist, the endpoint returns all eligible rows.

- **Sorting behavior**
  - The endpoint is sorted as defined by the leaderboard spec.
  - Ties are deterministically broken (example: secondary sort by address).

- **Source correctness**
  - Aggregations are derived from events (or other declared canonical sources).
  - If you cache snapshots, they reflect the same logic as the raw-event query.

Note:
- The Dune template numbering (`01`-`08`) matches the spec leaderboard numbering 1:1.

## Pagination regression test

If your endpoint supports pagination:
- test multiple offsets/cursors
- confirm no duplicates across pages
- confirm no missing rows across pages
- confirm page sizes remain consistent

Rule:
- Aggregation must happen before pagination (never paginate raw event rows and then aggregate).

## Dune sanity checks (REQUIRED)

- Build a small "known address" set of fixtures (addresses with obvious activity).
- Verify each leaderboard includes those addresses with expected ordering.

## Known lint coverage gaps (manual review required)

`analytics/scripts/lint_sql.sh` does not yet catch the following classes of issues.
Until automated checks are added, these must be verified manually during code review.

1. **Unquoted SQL reserved words** -- `user` is a reserved word in Trino (Dune's
   SQL engine). All bare `user` column references should be quoted as `"user"`.
   Regressions in this area would be silent without the lint gate.

2. **Non-deterministic ORDER BY with LIMIT/OFFSET** -- Any query using `LIMIT` +
   `OFFSET` for pagination must have a fully deterministic `ORDER BY` clause
   (e.g. append `evt_block_number DESC, evt_tx_hash` or a unique column). This
   class is prone to regressions in ops panels, so manual review is still required.

3. **Time-window syntax inconsistency** -- Dune (Trino) supports both
   `NOW() - INTERVAL '30' DAY` and `date_add('day', -30, now())`. The project
   standardized on `date_add()`. New templates should follow suit.

4. **Column naming conventions** -- Output column aliases should use `snake_case`
   (e.g. `ve_balance`, not `veBalance`). D1 consumers are decoupled from Dune
   column names via generic `value_wei`/`value_int` columns, but consistency
   aids readability and reduces confusion.
