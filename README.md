# BLACKOUT v3.4

Source-only continuation of v3.3. Nothing was deployed, broadcast, or minted. Project: [@IMDBlackout](https://x.com/IMDBlackout), public site: [playblackout.xyz](https://playblackout.xyz).

Paid and starter receipts retain their rarity draws when entropy expires: they re-arm, then capture a fresh future block. The hook accepts initialization only from the immutable official launcher, charges 90% / 50% / 25% buy tax for the first three ten-minute periods, sends **all** of that stepped tax to reward buys, and imposes no buy-size limit. Normal fees and progressive sell surcharges remain unchanged. Packs open at the authenticated hook timestamp plus one hour, only after endowment funding and verified router binding.

Binding is permissionless and one-time. The hook pins the application factory and a commitment to the intended game configuration and registry coordinates. It verifies exact registry creation code/address, the registry's hook back-reference, and enrollment of the exact pinned FeeRouter. The hook has no owner or upgrade path. Contracts are not proxies. Only new PackSale purchases may be paused by the swarm, for at most 72 hours, followed by at least 72 live hours; other operations remain callable.

Best-farm prizes require 20 active epochs and rank absolute weekly spend capped at 1 ETH. Lottery tickets accumulate committed hash capped at 100,000 per active epoch and 2.8 million per week. District scoring averages active paying farms only; each wallet contributes at most 10% of that district's uncapped paying spend. Free district packs require positive paid spend in the competition week. Referrals are unchanged.

A farm's first installed productive snapshot can mine the current epoch for its remaining time. Subsequent edits still apply next epoch. Idle commitments still expire after 12 epochs. The default endowment remains 20% of supply, dripped over 42 days. The regulator proposal now follows a seven-day cash pack-sales trend within existing daily step limits. Simulation compares 42/56 days and reports poor payback outcomes explicitly; this is not a promise of returns.

- [Finding-by-finding report](report.md)
- [Current launch steps and required parameters](docs/launch-v34.md)
- [Independent contributor review](docs/review-v34.md)
- [Simulation results: five seeds per case](artifacts/v34/simulation.md)
- [Simulation assumptions and limitations](docs/simulation-v34.md)
- [Entropy keeper and one-click reveal integration](docs/entropy-v34.md)
- Historical [v3.3 report](docs/report-v33.md), [v3.2 report](docs/report-v32.md)

## Local verification

The existing Foundry configuration and vendored dependencies are unchanged. Solidity is pinned to 0.8.26. No network or environment variables are required for default tests.

```sh
forge build
python3 tools/pin_module_code.py --check
forge test
forge fmt --check
python3 -m unittest discover -s test/python
node test/reveal.test.mjs
python3 sim/run_v34.py
```

After any Solidity implementation change, format first, build, regenerate module pins using `python3 tools/pin_module_code.py`, and rebuild/check. The pins authenticate compiler-specific creation code, including metadata. Do not use stale bytecode or pins. The historical fork test requires a separately supplied RPC and is skipped in offline default execution; real local v4 PoolManager integration runs offline.

## After launch

This assignment does not authorize a launch. The separately authorized deployer supplies and verifies the token, official PoolManager, launcher, immutable application factory, network recipient, swarm role, starter root/snapshot and reserved deployment coordinates. No address is guessed. There are no owner setters for these immutable security identities; freeze the accepted configuration before deployment. Publish all predictions, compiled hashes and the binding commitment.

Use the predicted RewardPool as `remainderTo`. After actual token delivery, anyone calls `fundEndowment()` to account for the transferred principal and freeze its drip schedule. Ordinary donations, core spending and buybacks cannot substitute for that principal. The permissionless funding fallback transfers only missing principal with exact approval. See the launch guide for platform prediction dependencies and the public fallback procedure if predeployment allocation is unavailable.

Anyone may enroll modules, bind the intended router, flush escrow, advance epochs, capture/re-arm entropy, settle farms, execute bounded buybacks and finalize seasons. The public keeper follows native blocks every two seconds; an occasional policy job is insufficient for a 256-block entropy window. The swarm proposes numeric policy and funds any external scheduling service from its own resources; heartbeat ETH has no administrative exit. Future blockhash randomness remains sequencer-influenced, as in v3.3; it is not VRF randomness.
