# BLACKOUT v3.1 regulator — dry run and permissionless execution

`python3 tools/regulator.py state.json` prints proposals and operational observations. `--example` uses synthetic local values. It has no RPC, key, signature or transaction path. Numeric authority belongs only to the configured swarm; the public bot needs none of that authority.

## Available funds and bounded policy

Read `RewardPool.available()`, `reserved()`, `lockedEndowment()`, `dripStart()` and `dripPeriod()`. Available excludes both reserved player obligations and locked endowment; do not count the team remainder, unactivated principal, or token mark-to-market as spendable ETH. Drip starts only on the public Endowed event, at the current Params duration 14–56 days, default 42. That schedule is then frozen; governance cannot accelerate existing vesting. Instant release is a simulation comparator only.

Inputs retain v3 `timestamp`, `epoch`, `availableTokens`, `dailyOutflowTokens`, `medianPaybackDays`, `weeklyEventLossBps`, `params` and `lastChanged`. Optional `pacePolicy` is reduce/hold/adaptive. Optional v3.1 observations are `lockedEndowmentTokens`, `heartbeatBalanceETH`, `dailyKeeperCostETH`, `scheduleRunsRemaining` and `packSalePausedUntil`. All token amounts use like units. Include referrals, season funding and gross commitments in outflow. Positive idle funds with zero outflow report null runway; an empty pool reports zero.

| Observation | Numeric proposal | Constraint |
|---|---|---|
| Available / daily commitments below 14 days | Reduce emission, raise tariff, reduce pace | At most 10% per key per 24 hours, hard bounds, public letter |
| Runway at least 14 days and realized whole-cohort payback above 10 days | Raise emission, lower tariff; reduce pace under baseline policy | Do not substitute only-repaid median or price-based projections for realized ETH |
| Weekly causal event loss above 8% | Favor Green/Cheap and increase positive weight | Leave margin under 10%; maintain rolling event quotas |
| Keeper deficit | Compare gas/roster/transaction volume to heartbeat revenue, propose bounded share change if needed | Params heartbeat 200–5000 bps; team 13% unchanged, incremental share comes from reward buys |
| Unsafe/stale TWAP or high price impact | Defer that buy, maintain observations and try an adequately sized slippage-safe buy | No zero minimum or owner bypass |

`hold` retains healthy pace. `adaptive` increases pace for payback above 30 days; all policies reduce pace during a runway emergency. Emission remains 2–6% per day, default 3.5%. The 116% reservation allowance limits current gross commitments but does not establish future ETH liquidity or investment returns. Existing funded-v3 sweeps are historical, not resources available to this launch.

## Bot loop

1. Verify all ten module enrollments and the hook binding. Flush held hook project fees into FeeRouter. Flushing transfers existing fees and has no separate bounty.
2. Call `advanceEpoch()` when due. It advances one actual six-hour epoch, with no accrual across inactive gaps. First startup may pay zero because the initial heartbeat is empty. The fixed advance bounty remains up to 0.001 ETH, bounded by funds.
3. Capture native-block entropy promptly: `GridOperator.resolve(epoch)`, `PackSale.captureEntropy(receipt)`, `StarterClaim.captureEntropy(tokenId)`. Grid waits for its target; paid/starter purchases use future native block targets. Capture is independent of inventory and preserves later item claims. Replay pays nothing. An IMD six-hour policy schedule is too slow to guarantee capture inside 256 native blocks; a public execution bot must follow blocks independently.
4. Complete `FarmRewards.processEpoch(1..8)` until `ready()`. Typical batch 4; measure, top-decile audit and credit phases each pay only for advancing their actual cursors. Do not submit empty transition calls expecting a bounty. Historical active farms may require processing even if their owner has gone offline; cost stress must count them. Reconcile actual roster and measured gas daily.
5. Execute reward-pool buys no larger than BuyBatch (default 0.5 ETH), with a fresh 30-minute quote and minOut at least the configured slippage floor. Buy bounty cap is proportional to ETH bought, so splitting cannot increase the aggregate cap. Very small buys may be uneconomic for a bot. Execute adequate batches and flush resulting hook fees afterward.
6. After calendar week end and settlement, `Season.prepare(week,1..64)` scores actual participants, then `finalize(week)` uses timely future entropy and earns its one nonempty-season bounty. Expired entropy must rearm. There is no bounty for expiration/rearm alone. Winners claim independently when ready.
7. Pull accumulated ETH credit using `FeeRouter.withdraw()`. Claims and this withdrawal are never paused. Races can still make a competing transaction unprofitable; estimate gas and credit immediately before submission.

## Keeper compensation and cash budget

Other work pays `min(unitCap × units, (measuredGas + 80000) × min(tx.gasprice,gasPriceCeiling) ×1.25, heartbeatBalance)`. Measured work excludes the payment itself;80k covers the transaction and credit overhead. Each authorized producer records work before requesting credit. The gas-price ceiling defaults 0.05 gwei; observed RPC base price for the simulation was 0.02 gwei. This is a capped reimbursement, not guaranteed profit at arbitrary gas prices. Include calldata/L1 posting, claim transaction and race costs when running a bot. Recheck live estimates before launch.

| Work | Default maximum ETH |
|---|---:|
| advanceEpoch |0.001 per successful shift |
| measure |0.000060 per actual farm cursor |
| credit |0.000040 per actual farm cursor |
| audit selection |0.000010 per actual selected farm |
| buy |0.000150 per 0.5 ETH, proportionally smaller |
| plan/paid/starter entropy |0.000010 per resolution/receipt |
| season scoring |0.000010 per participant cursor |
| season finalization |0.000040 per nonempty week |

No bounty can overdraw the heartbeat; there is no unpaid debt. If the balance is exhausted, work still completes with a partial or zero credit and cannot claim the difference later. Track **due**, **paid**, earliest shortfall and per-prefix headroom, not just ending balance. The baseline 1 ETH balance cap routes overflow to reward buys. Increasing that cap cannot cure an operating cash-flow deficit.

The report compares the 2% share with the smallest tested covering share/cap combination, 31% / 4.5 ETH, and quantifies the effect on rewards. This is not a global minimum. The research candidate uses 20% endowment and a 42-day drip; its unattended weak event-loss case exceeds 10%, so no all-target launch pass is claimed. A larger initial share can be selected in the three-argument Params constructor, within 200–5000 bps and 1–10 ETH. Existing deployments must use the ordinary 10%-per-day path. Team routing remains 13%; pack/lobby/sell-surcharge rewards receive `87% - heartbeat share`, plus any cap overflow. Project base fees remain 50/50 team/rewards and do not fund heartbeat.

## IMD schedules and pause responsibility

Heartbeat ETH pays on-chain bounties only. Current IMD schedule API top-ups cost 0.5 IMD/run, supplied by the payer on Ethereum. A35-day policy schedule with four runs/day needs 70 IMD, modeled at 0.24157 ETH plus external payment/acquisition costs. No contract path withdraws heartbeat ETH or purchases those runs. The team or another volunteer must acquire IMD and pay `schedule.topup`, publish receipts and keep at least one week of runs ahead. Budget reports show the run cost separately and subtract it from team proceeds when the team pays. Extra/minutely swarm jobs multiply this expense and are not free.

Only the swarm can pause new paid PackSale purchases for 1second to 72 hours. Expiry auto-unpauses. The next pause must wait an additional 72 hours after the original expiry, even after an early manual unpause. Entropy capture, existing receipts, free rewards, all keeper calls, claims and withdrawals remain live throughout. Pausing creates no upgrade or asset recovery power.

The modeled policy case assumes timely swarm plans at minimum negative severity 5000. If the swarm is absent, automatic v3 fallback and full negative severity apply; keepers preserve execution, not the policy-case loss/payback outcome. Monitor separate unattended sensitivities. Future-block hashes remain sequencer-influenced randomness, not verifiable randomness. No autonomous contract can guarantee submissions when no public operator finds the bounded bounty profitable.
