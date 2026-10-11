# BLACKOUT v3 regulator — dry run only

`python3 tools/regulator.py state.json` prints proposals; `--example` uses a synthetic local example. It has no RPC client, key handling, signing or transaction path. `artifacts/regulator-example.json` records its example output. A human/swarm process verifies and signs permitted proposals separately.

Input fields: UTC `timestamp`, current `epoch`, unreserved `availableTokens`, measured conservative `dailyOutflowTokens`, `medianPaybackDays`, `weeklyEventLossBps`, optional `pacePolicy` (`reduce`, `hold`, or `adaptive`, default `reduce`), and dictionaries `params`/`lastChanged` keyed by EmissionBps, TariffBps, DemandTarget, PositiveWeight. Use like-for-like token units; include all outstanding committed emission, referral and season funding when estimating outflow. Use at least a trailing day and a projected next-day commitment estimate, taking the larger. Do not count reserved player credits as runway. An empty available pool with zero outflow has zero runway; a positive idle pool with no outflow has an unbounded ratio, reported as null. Neither creates initial mining funding.

| Observation | Proposed action | Limits / rationale |
|---|---|---|
| Available / daily outflow below 14 days | Reduce emission 10%, raise tariff 10%, reduce pace up to 10% | First protect pool liquidity; bounds still apply. |
| Runway at least 14, median payback above 10 days | Raise emission up to 10%, reduce tariff up to 10%, reduce target pace up to 10% | More mining and less electricity; slower item supply reduces dilution. Demand feedback must be simulated before signing. |
| Event losses above 8% of counterfactual weekly yield | Raise positive weight up to 10%; next plans Green/Cheap at severity 5000 | Leave margin below 10% loss target. |
| Healthy state | Keep numbers; propose Calm/Green | Avoid changing numbers without an observed reason. |
| Stale/missing TWAP or unsafe price impact | Do not execute buys/token-price operations; repair observation/keeper coverage | No owner bypass or zero-minimum buy path exists. |

The `hold` policy retains the current pace when runway is healthy. The `adaptive` policy raises pace up to 10% when payback exceeds 30 days; otherwise it follows the reduction rule. All policies reduce pace on a runway emergency. The model compares all three explicitly; the funded `hold` scenario needs actual external capital and is not an automatic launch recommendation.

All numeric changes clamp to both Params hard bounds and `old ± floor(old/10)`. Each key's output includes `eligibleAt=lastChanged+86400` and `ready`; a proposed value is not transaction authorization. On-chain Params independently checks caller, cooldown, bounds, nonzero change and herald letter. Default emission 3.5%/day, maximum 6%/day keeps 116% gross commitments below 7%/day; conservative instantaneous runway at the maximum is 14.37 days. Percent-of-remaining emissions mathematically decay; this ratio alone does not establish economic health.

The simulation uses the same numeric policy and a fallback-shaped, planned mix: permitted negative severity 5000, positive severity 10000, minimum positive quotas and negative/cooldown caps. Real dry-run outputs are more conservative on a loss alert. The simulation's low-severity case presumes the swarm submits plans on time; absent plans revert to full-severity autonomous table behavior. The contract remains live without swarm plans, but model loss targets then need a separate stress assessment.

The operator supplies unpredictable plan numbers before shift for only the next two epochs and publishes a letter for each. Random numbers are not district/player choices, and letters do not execute code. Prefer Calm/Green/Cheap while investigating loss, falling demand or poor oracle liquidity. The chain caps each negative to four per rolling 20 and requires four positives. Lobby effects cannot lower a district's negative weight below 0.40, have a 3-day half-life, and affect district weights rather than letting the swarm target farms.

## Permissionless operating loop

1. At launch/end, call `advanceEpoch`. Gaps earn no emission. The successful caller receives a pull bounty up to the actual heartbeat balance.
2. Resolve the shifted event after target native block N+1 and before its 256-block history expires. Resolve paid/starter packs after N+2. Robinhood native L2 blocks may pass much faster than six hours; an epoch-only cron is insufficient for entropy preservation.
3. Complete `processEpoch` until `ready()`, normally in batches 1–4;8 is a ceiling. On audit epochs there are measurement, top-decile and credit phases. New claims then become available. Existing pull balances do not depend on this loop.
4. Execute pool buys in transactions no larger than BuyBatch with a fresh thirty-minute quote and minimum received output. A small slippage-safe buy is valid; no shared cooldown can be griefed. Check available liquidity and gas before choosing size.
5. After calendar week end and settlement, call `Season.prepare(week,limit)` until ready, preserve its future hash by finalizing promptly, and rearm only if expired. Winners claim separately, making inventory room as needed.
6. Record pool available/reserved, sales pace, active farms, causal event loss, realized payback with censored fractions, both fee-path assumptions, heartbeat credit and keeper cost. Re-run the 35-day scenarios before changing the policy.

Only shifting has a protocol bounty; settlement/entropy/buyback/week work needs a funded keeper operation or participating users. Heartbeat cannot be withdrawn administratively. Independent operators should monitor one another because delayed settlement pauses new gameplay and a depleted heartbeat can make the next shift's bounty zero. No transaction in this assignment performed any of these live operations.
