# BLACKOUT v3.1

Immutable token-endowed mining game on the existing v3 codebase. No deployment, broadcast, token creation/replacement or live spending occurred. Build settings and dependencies are unchanged.

[Report](report.md) contains the endowment comparison, target misses and recommended parameters. [Launch procedure](docs/launch-v31.md) specifies the custom hook followed by two application launches of 8+4 contracts. [Regulator](regulator.md) describes keeper and manual IMD responsibilities. [Fresh review](docs/review-v31.md) records findings and repairs. Historical v3 results are preserved in [docs/report-v3.md](docs/report-v3.md), not the v3.1 economic baseline.

## Reproduce offline

```sh
forge build
forge test
forge fmt --check
python3 tools/pin_module_code.py --check
python3 -m unittest discover -s test/python -v
python3 sim/blackout_sim_v3.py --check
python3 sim/blackout_sim_v31.py --output artifacts/v31/final
python3 sim/heartbeat_sweep_v31.py --bps 3100 --cap 4.5 --all --stress --output artifacts/v31/funded
python3 sim/candidate_stress_v31.py
python3 sim/heartbeat_boundaries_v31.py
python3 tools/report_v31.py
python3 tools/regulator.py --example
```

The compiler is the existing pinned 0.8.26, viaIR, Cancun. Vendored dependencies are ordinary files. No RPC or environment variables are needed by the default suite. The optional Robinhood smoke test skips offline and can be run separately with the explicit public RPC; no live deployment is performed by it.

## Accounting and authority

The one-time endowment is 100–250 million of the existing billion tokens. The pool locks it before activation and then releases principal linearly over 14–56 days (default 42). Activation fixes the period permanently. Released funds remain subject to ordinary mining reservations and player claims. No donor, owner, team or swarm withdrawal exists.

Ten modules use a permanent `GameRegistry`. Anyone can register exact, compiler-pinned module bytecode deployed with that registry constructor argument by the verified application factory; each role is write-once. There is no replaceable implementation, delegatecall or upgrade. Constructors make no external calls. `Params(swarmWallet,initialHeartbeatBps,initialHeartbeatCapWei)` allows only bounded numeric changes after deployment, with 10% maximum movement per key per 24 hours and a public letter.

The custom hook is a standalone five-argument source at `launch/V4Market.sol`. It escrows ETH fees before the game exists. Only the fixed team address `0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007` may bind FeeRouter, once. Flushing fees afterward is permissionless. This is the hook's only privileged action. Network and project credits remain separate.

Only new paid purchases in PackSale may be paused by the swarm, at most 72 hours per pause, with automatic timestamp expiry and a 72 hour live interval before another pause. Existing pack resolutions, claims, withdrawals, epoch advancement and all keeper work remain callable.

Keepers earn pull credits for useful epoch, settlement, audit, entropy, buyback and weekly work. Measured gas reimbursement has a 25% margin, a gas-price ceiling, per-unit hard caps and a heartbeat-balance cap. Empty/replayed work earns nothing. ETH cannot directly buy IMD heartbeat runs; an external payer tops those up and public bots monitor fast entropy deadlines.

## Client sequence

1. Anyone calls `FarmRewards.advanceEpoch()` at launch, then at/after each six-hour end. It closes at most one epoch and starts the next at the call time; gaps do not earn mining. Finish the previous epoch with `processEpoch(1..8)` until `ready()` before farm loadout/spending changes or another advance.
2. Buy `PackSale.openPack(n)` with exactly `quote(n)` ETH. There are no wallet, daily, token-pack or total sales caps. Resolve after native block N+2 using `resolve(id,1..8)`, making room for three items per pack. A large receipt can be opened over multiple calls.
3. Equip `FarmCore.place(id,room,slot)`, with zero-based room 0–3 and slot 0–5. Each room accepts any types without duplicates. Query `roomUnlocked(player,index)` for each independent gate; paid XP can unlock a later room before the age-gated room, so the unlocked count is not a contiguous prefix. Approvals are unnecessary and disabled: Core alone moves items between a player and that player's farm.
4. Loadout, ordinary repairs, overclock and paid-account status are snapshotted per epoch; changes take effect for the next epoch. Cable repair restores only the remaining portion of an ongoing theft epoch. Equip or buy before the first active epoch to establish a farm.
5. Spend with Core's `buyTokenPack`, `repair`, `repairCable`, `overclock`, `expand`, `merge`, or `lobby`. `wallet=true` uses approved ERC-20; `false` uses internal rewards with 5% additional purchasing power. Every consumed token goes to the pool. Electricity is automatically recycled from mining.
6. `FarmRewards.claim(amount)` withdraws already credited rewards at any time, subject to each credit's age tax. New credits appear after each epoch's bounded settlement. Full inventory does not stop mining or pull payments. `scrap(id,minimum)` permits an unequipped, unlocked item exit with a slippage-protected, allowance-capped reward.
7. Resolve supply drops and weekly entitlements when inventory has space. `Season.prepare(week,1..64)` and `finalize(week)` are permissionless; expired lottery entropy requires `rearm(week)` and a new future block, rather than a predictable prize seed.

Snapshot tooling is retained: `python3 tools/starter_merkle.py owners.csv --snapshot-block BLOCK --collection ADDRESS`. Leaves are `keccak256(abi.encode(uint256 tokenId,address holder))`, with sorted pairs. This attests snapshot ownership; it does not bridge collection state on demand. Publish the actual collection identity and snapshot provenance with the root.


All future launch addresses, snapshot data, chain contracts and swarm role come from the accepted launch configuration. Follow the exact verification, binding and public team-to-pool transfer steps in [launch-v31.md](docs/launch-v31.md). No test identities or guessed production addresses are supplied. Future-block randomness retains the v3 sequencer influence and timeout limitations; it is not a VRF.
