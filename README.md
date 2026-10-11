# BLACKOUT v3

Immutable, ownerless game contracts for the existing IMD launch token. **No deployment, broadcast, token creation, replacement, or ERC-20 mint occurred in this assignment.** The build configuration and vendored dependencies are unchanged.

Read [report.md](report.md) for implementation changes, parameters, economic outcomes and remaining launch decisions; [regulator.md](regulator.md) for operating rules; [design](docs/design.md) for accounting and gameplay; and [security review](docs/security-review.md) for the independent contributor's findings and repairs.

## Reproduce

Foundry uses the existing pinned Solidity **0.8.26**, Cancun, optimizer and via-IR configuration. Dependencies are already ordinary repository files; no network is needed for the default checks once that compiler is installed.

```sh
forge build
forge test
forge fmt --check
python3 sim/blackout_sim_v3.py --check
python3 -m unittest discover -s test/python -v
python3 sim/blackout_sim_v3.py
python3 tools/regulator.py --example
```

The optional live Robinhood smoke test uses the public RPC explicitly:

```sh
forge test --fork-url https://rpc.mainnet.chain.robinhood.com --match-contract RobinhoodForkTest -vv
```

It is skipped in the offline suite on other chains. It reads native ArbSys block numbering/hash on chain 4663, then replays those results into Foundry's EVM, which does not implement ArbOS. This is a chain primitive smoke test, not a deployment or a full test against the future token/pool. Real vendored Uniswap v4 PoolManager integration is tested locally for both market paths.

## Immutable application graph

`script/Deploy.s.sol:deploy(Config)` is a **local construction helper**, tested with explicit inputs. It does not read the environment or broadcast. Its eleven deployments, in order, are Params, RewardPool, FarmRewards, FarmCore, FarmItems, PackSale, StarterClaim, FeeRouter, GridOperator, Season, FarmEngine. The helper predicts its own CREATE nonces so circular immutable references agree. It is not a deployable on-chain factory; its large script bytecode is not an application contract. A launch system must reproduce its own complete creator/nonce address plan.

The six required configuration fields are:

| Field | Supplied by launch operator |
|---|---|
| `token` | Actual existing launch ERC-20; 18 decimals, plain transfers, no rebasing or transfer tax. |
| `swarmWallet` | Actual immutable Grid Operator address. It controls bounded numbers and event plans only. |
| `market` | Verified custom `V4Market`, or `StandardAdapter` for the actual standard IMD hook and oracle. |
| `launchTime` | Actual token-launch timestamp, used for starter window, VRGDA and calendar seasons. |
| `starterRoot` | Root of actual Identity MD tokenId/holder snapshot at launch; publish source and proofs. |
| `snapshotBlock` | Actual snapshot block represented by that root; reconcile chain/time if collection and token differ in chain. |

No addresses, roots, keys or IDs for the eventual deployment are guessed. Tests contain explicitly test-only mocks and identities. The fixed team is `0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007`; there is no team-change setter. Heartbeat ETH funds permissionless epoch callers, rather than a configured recipient.

Application constructors have at most eleven inputs, check missing inputs locally, and do not call external contracts. All external services and immutable wiring must be validated before launch; no owner can repair configuration afterward. The engine is a separate immutable calculation contract, not a delegatecall module or upgrade point.

## Choose exactly one swap-fee integration

| Path | Project fee | Network | Progressive surcharge | Required integration |
|---|---:|---:|---|---|
| Preferred custom | 2%: 1% team, 1% pool-buy | 0.25% | Sell only; total fee capped at 15% | Launch explicitly supports `V4Market` as its combined hook. |
| Standard fallback | 1%: 0.5% team, 0.5% pool-buy | 0.25% | None | Existing IMD hook forwards its 1% project ETH to `FeeRouter`; `StandardAdapter` buys through that exact hook. |

`StandardMarket` is an executable reference implementation for the fallback fee schedule, including tests. It is **not** a replacement for a platform hook when custom hooks are disallowed. `StandardAdapter` is the actual integration adapter for that situation. Its constructor takes manager, token, 30-minute oracle, FeeRouter, existing standard hook and tick spacing. The oracle implements `consult(poolId)` with token units per ETH, last observation time and observation window; the adapter rejects zero, stale, future or short-window results. The real oracle implementation/address is a launch prerequisite and must be checked independently.

Custom `V4Market` requires PoolManager, token, Params, FeeRouter, actual network recipient, zero LP fee and tick spacing. `MarketFactory` is a permissionless CREATE2 helper for address flags `0x10cc`; `script/DeployMarket.s.sol` takes explicit arguments and has no broadcast path. Only exact-input swaps are supported. PoolManager protocol/LP fees must not add fees outside the disclosed cap. Do not layer project fees on another fee-charging hook.

Resolve custom market/game address dependencies before deployment; initialize native ETH/token liquidity and allow **31 minutes** of observed history before its 30-minute TWAP quotes. The standard path requires an independently verified 30-minute source for the exact pool. No live hook support or final market address has been asserted here.

## Client sequence

1. Anyone calls `FarmRewards.advanceEpoch()` at launch, then at/after each six-hour end. It closes at most one epoch and starts the next at the call time; gaps do not earn mining. Finish the previous epoch with `processEpoch(1..8)` until `ready()` before farm loadout/spending changes or another advance.
2. Buy `PackSale.openPack(n)` with exactly `quote(n)` ETH. There are no wallet, daily, token-pack or total sales caps. Resolve after native block N+2 using `resolve(id,1..8)`, making room for three items per pack. A large receipt can be opened over multiple calls.
3. Equip `FarmCore.place(id,room,slot)`, with zero-based room 0–3 and slot 0–5. Each room accepts any types without duplicates. Query `roomUnlocked(player,index)` for each independent gate; paid XP can unlock a later room before the age-gated room, so the unlocked count is not a contiguous prefix. Approvals are unnecessary and disabled: Core alone moves items between a player and that player's farm.
4. Loadout, ordinary repairs, overclock and paid-account status are snapshotted per epoch; changes take effect for the next epoch. Cable repair restores only the remaining portion of an ongoing theft epoch. Equip or buy before the first active epoch to establish a farm.
5. Spend with Core's `buyTokenPack`, `repair`, `repairCable`, `overclock`, `expand`, `merge`, or `lobby`. `wallet=true` uses approved ERC-20; `false` uses internal rewards with 5% additional purchasing power. Every consumed token goes to the pool. Electricity is automatically recycled from mining.
6. `FarmRewards.claim(amount)` withdraws already credited rewards at any time, subject to each credit's age tax. New credits appear after each epoch's bounded settlement. Full inventory does not stop mining or pull payments. `scrap(id,minimum)` permits an unequipped, unlocked item exit with a slippage-protected, allowance-capped reward.
7. Resolve supply drops and weekly entitlements when inventory has space. `Season.prepare(week,1..64)` and `finalize(week)` are permissionless; expired lottery entropy requires `rearm(week)` and a new future block, rather than a predictable prize seed.

Snapshot tooling is retained: `python3 tools/starter_merkle.py owners.csv --snapshot-block BLOCK --collection ADDRESS`. Leaves are `keccak256(abi.encode(uint256 tokenId,address holder))`, with sorted pairs. This attests snapshot ownership; it does not bridge collection state on demand. Publish the actual collection identity and snapshot provenance with the root.

## After launch

The launch operator verifies external contracts, hook policy, immutable graph, pool fees/liquidity, snapshot and runtime hashes. The swarm runs the dry-run regulator, supplies plans for the next two epochs with letters, and signs only bounded Params changes. Permissionless keepers promptly preserve event/pack entropy, settle batches, perform slippage-protected pool buys and finalize weeks. Team and bounty recipients pull their own ETH. There are no owner setters, upgrades, administrative token withdrawals, room keys, Generator or BurnVault.

Operational availability still matters: epoch bounties reward shifting, while batch settlement requires keepers/players to submit transactions. Future block hashes are sequencer-influenced randomness; they are not a VRF. See the review and report for this limitation and the economic targets that the unfunded simulation does not meet.
