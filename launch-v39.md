# BLACKOUT v3.9/v3.10/v3.11 — final ordered launch runbook

Source only. Nothing in this repository has been deployed, broadcast, bought, signed or minted, and this runbook
authorizes none of it: every paid step below is a separate, requester-approved IMD job. It supersedes
`launch-v38.md`, `launch-v37.md` and older runbooks where they differ.
X: https://x.com/IMDBlackout · Site: https://playblackout.xyz · Free pack: https://playblackout.xyz/freepack

The game chain is **Robinhood Chain (4663)**, called "mainnet" below. The oracle schedules are bought on
**Ethereum (1)**. The rehearsal (v3.11) runs the same sequence on a **local anvil fork of 4663** against the real
platform contracts, impersonating the platform deployer; nothing is broadcast.

## 0. Rules for every step

- **One toolchain.** Every contract is deployed from the IMD verifier build of the accepted commit:
  solc 0.8.26, optimizer 200, cancun, `FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none` (the `out-launch/`
  artifacts). The hook embeds `type(GameRegistry).creationCode` from its own build, so a registry or Params
  built with the repository's via-IR toolchain binds to the Desk but **never** to the hook (review L-1). Before
  each paid step, check the job's attested creation-code hash against `src/lib/SwarmCode.sol`
  (`REGISTRY_LAUNCH`, `PARAMS_LAUNCH`) and `ModuleCode.launchHash(role)`.
- **Keep the game configuration private until `Desk.bind`.** `starterRoot`, `freeRoot`, `snapshotBlock` and the
  eligibility lists stay unpublished until step M7 has passed its check. Anyone who knows them and the token can
  launch a twin registry through the factory and bind the Desk first (review M-2). Publish the free-pack lists
  and proofs only after M7.
- **Stop on any failed check.** Every step has an on-chain check. If it fails, do not run the next paid step.
  In particular, never call `EndowmentEscrow.forward` unless `Desk.registry()` is the job A registry.
- No value below is a guess. `<NAME>` marks a value recorded from an earlier step (from
  `GET /launches/:id`) or supplied by the requester.

## 1. Inputs

| Input | Who | Value / source |
|---|---|---|
| Identity MD snapshot block (Ethereum block number; NFT `0x0000ec93127baa929e58e97dd0095a2bfb38ec1d` on chain 1) | **Requester** | `<SNAPSHOT_BLOCK>` |
| Identity MD starter Merkle root (`tools/starter_merkle.py` over the snapshot) | **Requester** | `<STARTER_ROOT>` |
| Free-pack Merkle root (`tools/freepack_merkle.py`) | **Requester** | `<FREE_ROOT>` |
| Endowment | Fixed | `200000000000000000000000000` (200,000,000e18, 20% of supply) |
| Game configuration hash | Derived | `GAME_CONFIG_HASH = keccak256(abi.encode(STARTER_ROOT, FREE_ROOT, SNAPSHOT_BLOCK, ENDOWMENT))` (`cast keccak $(cast abi-encode "f(bytes32,bytes32,uint256,uint256)" ...)`) |
| Keeper wallet (gas only, no authority) and its RPC | **Requester** | `<KEEPER_WALLET>`; key stays in `/etc/blackout/keeper.env`, never in this repo |
| Paying wallet of the token launch (receives the platform 1%) | Requester, as in earlier briefs | team wallet `0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007` |
| Ethereum IMD for the two schedules (14 IMD event + 2 IMD regulator to start) | **Requester** | paid from the requester's wallet |
| Optional Robinhood IMD donation to the Desk for backups | Requester / anyone | any amount; no withdrawal exists |
| Platform addresses on 4663 | Fixed (research job b94e6839) | ProjectFactory `0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e`, its launch registry `0xf52bbe066b7ad2d28c2195d066ea08dcbca88406`, LaunchFactory `0xa25b02a1e93903b790e6aaf7da1b8b8d50294645` |
| Oracle on 4663 | Fixed (oracle reference) | Intake v2 `0xa43e6f75ee006411f79ac1c84120606c2330de82`, IntakeDelivery `0xce0e6a670aa75e161d02aca3c7f00b94ca428ccb`, attester `0x5598aa9146215bc13eb26f2c692ad1461fd32982`, Robinhood IMD `0x5f7bb59365ce557c26dbcaa4ee9d39a4b95b7127`, action `bytes32("oracle.request@oracle-1")` |
| PoolManager on 4663 | Fixed (`LaunchFactory.poolManager()`, confirmed on the fork) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |
| Platform deployer (the only wallet the factories take a launch from) | Fixed (`ProjectFactory.deployer()` = `LaunchFactory.deployer()`) | `0xcECc29B037f5064fCdF45a5C318F132ef76aA551` |
| Rehearsal RPC for the 4663 fork | Rehearsal operator | any 4663 JSON-RPC (public ones that answered on 2026-10-12: `https://robinhood.drpc.org`, `https://robinhood-rpc.publicnode.com`) |
| Rehearsal game configuration | Rehearsal operator | throw-away test roots, snapshot and attester key (never the production ones, so M-2 stays closed) |

## 2. Fork rehearsal (local anvil fork of 4663) — run in v3.11, passed

`tools/rehearse_v311.sh <4663 rpc>` starts `anvil --fork-url`, builds with the IMD launch toolchain and runs
`test/fork/RehearsalV311.t.sol` against the fork. The test executes M1–M13 in order through the **real**
ProjectFactory `0x9c9d…265e`, its registry `0xf52b…8406`, LaunchFactory `0xa25b…4645` and PoolManager
`0x8366…0951`, impersonating the platform deployer where the platform deploys or initializes, with the real
Intake/IntakeDelivery/IMD addresses in the Desk's oracle config, a test attester key, throw-away roots and
throw-away launch numbers 777001–777005 (asserted unrecorded first). Nothing is broadcast. The committed log is
`artifacts/v311/rehearsal.log` (every address, call and check); the result is summarised in `report.md`.

What the fork proved (2026-10-12, fork block 86865884, basefee 0.0206 gwei; see the log for the exact figures):

1. **Creation-code hashes.** Every contract the real factory deployed from the launch-toolchain build hashes to
   the pins: `SwarmCode.REGISTRY_LAUNCH`, `SwarmCode.PARAMS_LAUNCH`, `ModuleCode.launchHash(0..13)`. The
   CREATE2 addresses equal `predictContract`, so `register`, `bind`, `bindFeeRouter` and `forward` all pass
   their proofs. The attestation hashes the plane records must equal these same values.
2. **`afterInitialize` sender = LaunchFactory.** The trace shows `PoolManager.initialize` called by the
   LaunchFactory inside its launch transaction and `V4Market.afterInitialize(sender = 0xa25b…4645, …)`;
   `initializedAt()` is set. The `$factory` constructor word is correct.
3. **Gas per launch vs the 0.01 ETH ceiling** (gas used by the factory call, cost at the fork basefee):
   Desk 5,415,993; Escrow 1,743,701; token + hook 7,220,053; job A (8 contracts) 21,411,808; job B (8 contracts)
   19,523,888. At the fork basefee the dearest launch costs about 0.00045 ETH; the largest launch fits under the
   ceiling up to a basefee of about 0.47 gwei, more than 20× the fork's basefee.
4. **Constructor encoding through the real launcher.** The twelve-word SwarmDesk encoding
   (`tools/swarm_constructor_args.mjs` / `SwarmArgs.encode`), the three-word escrow, the eight-word hook with
   `$poolManager`, `$token`, `$factory` and the job A/B words all decoded as intended (every check view agrees).
5. **Order and checks.** `Desk.bind` → `register` 0–5 → job B + `register` 6–13 → `bindFeeRouter` → `forward`
   (full balance to the authenticated RewardPool) → `fundEndowment` (drip starts, 42 days) → relayed `submit`
   of an attested answer (plan severity clamped into 5000–7000) → keeper `advanceEpoch` with entropy reveal →
   `LaunchFactory.claimFees` pays the paying wallet (0.0198 ETH on a 2 ETH buy ≈ 1%). Buys at +5/+15/+25 min
   paid 90/50/25% to rewards; at +31 min exactly 1%; a net sell carried the surcharge; the first pack bought at
   +1h and its entropy was captured; before +1h `openPack` reverts `TooEarly`.

Where reality differed from the v3.10 runbook (all folded into §3 below, no contract change):

- **Pair currency.** The LaunchFactory `launch` tuple carries the pair currency explicitly. The three recorded
  4663 hook launches (1015, 1300, 1316) were all **IMD-paired**; BLACKOUT's `pairWith eth` must put the zero
  address there, so the pool is `(ETH, token)` as `V4Market.key()` expects. With IMD the hook's `afterInitialize`
  reverts `Unauthorized` on the key check and the launch fails (observed on the fork before the fix).
- **remainderTo gets the 20% plus the liquidity dust.** The factory sends `remainderTo` everything the pool
  position did not consume, so the escrow holds ≥ 200,000,000e18 (the fork: +560,364 tokens from the
  rehearsal's own liquidity figure). `forward` moves the whole balance; `fundEndowment` needs ≥ principal. OK.
- **First `advanceEpoch` before packs open.** Pack sales record into the live epoch, so the keeper's first
  `advanceEpoch` (allowed from pool initialization on) must land before +1h or `openPack` reverts `TooEarly`.

## 3. Mainnet (Robinhood Chain 4663), in order

Each paid step lists its objective text (paste verbatim after filling the `<...>` values; each is well under
8000 characters), its inputs and the check that proves it worked. Permissionless calls (M7 onward) can be
sent by any wallet; the keeper sends them with `node keeper/keeper.mjs wire --wiring wiring.json` (template
`keeper/wiring.example.json`), dry run first.

### M1. SwarmDesk bootstrap (paid, `launch.open`, `onchain: "evm_contracts"`, 1 contract)

Inputs: `GAME_CONFIG_HASH`; `docs/oracle-v37/oracle-config.json`; binding file
`{"factory":"0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e","registryLaunch":"0","registryIndex":0,"paramsLaunch":"0","paramsIndex":0,"heartbeatBps":200,"heartbeatCap":"1000000000000000000","gameConfigHash":"<GAME_CONFIG_HASH>"}`.
Constructor words: `node tools/swarm_constructor_args.mjs docs/oracle-v37/oracle-config.json binding.json`
(twelve static words).

Objective:

> BLACKOUT SwarmDesk bootstrap on Robinhood Chain (4663). Deploy exactly one contract, `SwarmDesk` from the accepted BLACKOUT v3.10 commit, built with solc 0.8.26, optimizer 200 runs, evm cancun, viaIR false, bytecode_hash none. Constructor: the twelve static words below, produced by `tools/swarm_constructor_args.mjs` from `docs/oracle-v37/oracle-config.json` and the binding file (factory 0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e, heartbeat 200 bps, gameConfigHash <GAME_CONFIG_HASH>): <TWELVE WORDS>. The contract has no owner, no admin key, no upgrade and no withdrawal; it acts only on attested IMD oracle answers. No token action, no other contract, no placeholder value. Record and return the deployed address. Project: https://playblackout.xyz · https://x.com/IMDBlackout

Check: `cast call <DESK> "registry()(address)"` = `0x0000000000000000000000000000000000000000`;
`cast call <DESK> "bindingConfig()"` decodes to factory `0x9c9d…265e`, heartbeatBps 200, cap 1e18,
`gameConfigHash` = `<GAME_CONFIG_HASH>`; `oracleConfig()` matches `oracle-config.json`.

### M2. EndowmentEscrow (paid, `evm_contracts`, 1 contract)

Inputs: `<DESK>`.

Objective:

> BLACKOUT EndowmentEscrow on Robinhood Chain (4663). Deploy exactly one contract, `EndowmentEscrow` from the accepted BLACKOUT v3.10 commit (solc 0.8.26, optimizer 200, cancun, viaIR false, bytecode_hash none), constructor (ProjectFactory 0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e, ProjectFactory launch registry 0xf52bbe066b7ad2d28c2195d066ea08dcbca88406, SwarmDesk <DESK>). It is ownerless; its only exit forwards its whole token balance once to the RewardPool of the registry the SwarmDesk bound to, proven on chain. It becomes the remainderTo of the BLACKOUT token launch. Record and return the address. No token action. https://x.com/IMDBlackout

Check: `factory()` = `0x9c9d…265e`, `records()` = `0xf52b…8406`, `desk()` = `<DESK>`, `forwarded()` = false.

### M3. Token launch (paid, `launch.open`, `onchain: "univ4_hook"`)

Inputs: `<ESCROW>`, `<DESK>`, `GAME_CONFIG_HASH`, paying wallet.

Objective:

> BLACKOUT token launch on Robinhood Chain (4663): onchain univ4_hook, pairWith eth, platform pool fee 12500 (1.25%: 1% to the paying wallet via LaunchFactory.claimFees, 0.25% to the IMD network), economics poolBps 7000 and remainderTo <ESCROW> (the BLACKOUT EndowmentEscrow; the 20% endowment reaches the game RewardPool only through it). Hook: `V4Market` from the accepted BLACKOUT v3.10 commit (solc 0.8.26, optimizer 200, cancun, viaIR false, bytecode_hash none), constructor ($poolManager, $token, 12500, 60, $factory, 0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e, <DESK>, <GAME_CONFIG_HASH>). The hook has no owner; after the stepped 30-minute launch tax it adds exactly 1% to game rewards on every swap plus the progressive sell surcharge. Paying wallet 0x6d51cBE774aeAe4dd40bCA2560E9bc2695A0d007. Record the token, hook and launch number. https://x.com/IMDBlackout · https://playblackout.xyz

Check: `cast call <TOKEN> "balanceOf(address)(uint256)" <ESCROW>` ≥ 200,000,000e18 (the 20% plus any pool
dust the factory did not seed; the fork showed +0.056%); the pool key is `(ETH 0x0, TOKEN, 12500, 60, HOOK)`;
`<HOOK>.launcher()` = LaunchFactory, `poolFee()` = 12500, `desk()` = `<DESK>`, `gameConfigHash()` =
`<GAME_CONFIG_HASH>`, `initializedAt()` ≠ 0; record `<TOKEN>`, `<HOOK>`, `<N_T>`.

### M4. Job A (paid, `evm_contracts`, 8 contracts)

Inputs: `<DESK>`, `<TOKEN>`, `<HOOK>`, `<STARTER_ROOT>`, `<FREE_ROOT>`, `<SNAPSHOT_BLOCK>`. The roots are first
revealed here.

Objective:

> BLACKOUT job A on Robinhood Chain (4663), eight contracts from the accepted BLACKOUT v3.10 commit, built with solc 0.8.26, optimizer 200, cancun, viaIR false, bytecode_hash none, in this order: [0] Params(<DESK>, 200, 1000000000000000000); [1] GameRegistry(<TOKEN>, $contract[0], <HOOK>, <STARTER_ROOT>, <FREE_ROOT>, <SNAPSHOT_BLOCK>, 200000000000000000000000000, 0x9c9d2fcb75c2c132c0ac0c42df3819a42347265e); [2] RewardPool($contract[1]); [3] FarmRewards($contract[1]); [4] FarmCore($contract[1]); [5] FarmItems($contract[1]); [6] PackSale($contract[1]); [7] StarterClaim($contract[1]). If a same-launch reference is not supported, deploy Params alone first and put its recorded address in GameRegistry. No owner, admin, upgrade, token action or placeholder. Record every address with its index and the launch number. https://x.com/IMDBlackout

Check: `GameRegistry.params()` = Params, `token()` = `<TOKEN>`, `market()` = `<HOOK>`,
`Params.swarmWallet()` = `<DESK>`; attested creation-code hashes equal `SwarmCode.REGISTRY_LAUNCH`,
`SwarmCode.PARAMS_LAUNCH` and `ModuleCode.launchHash(0..5)`. Record `<N_A>`, `<REGISTRY>`, indices.

### M5. Desk.bind — immediately after M4 (permissionless)

`SwarmDesk.bind(<REGISTRY>, registryCode, paramsCode, <N_A>, 1, <N_A>, 0)` with the `out-launch` creation
codes (`node keeper/keeper.mjs wire --wiring wiring.json --step bind-desk`).

Check: `cast call <DESK> "registry()(address)"` = `<REGISTRY>`. If it is anything else, **stop**: the Desk was
captured by a twin; do not forward the endowment, publish nothing, and escalate to the requester.

### M6. Register job A modules (permissionless)

`GameRegistry.register(role, <N_A>, index, creationCode)` for roles 0–5 (`--step register`).
Check: `GameRegistry.module(r)` for r = 0..5 equals the job A addresses.

### M7. Job B (paid, `evm_contracts`, 8 contracts; may be a `workflow.open` chained with the site job)

Objective:

> BLACKOUT job B on Robinhood Chain (4663), eight contracts from the accepted BLACKOUT v3.10 commit, built with solc 0.8.26, optimizer 200, cancun, viaIR false, bytecode_hash none, each with the single constructor argument <REGISTRY> (the job A GameRegistry): [0] FeeRouter; [1] GridOperator; [2] Season; [3] FarmEngine; [4] Economy; [5] Enhancement; [6] Civic; [7] Billboards. No owner, admin, upgrade, token action or placeholder. Record every address with its index and the launch number. https://x.com/IMDBlackout · https://playblackout.xyz

Then `register` roles 6–13 with `<N_B>`. Check: `GameRegistry.module(r)` for r = 6..13 equals the job B
addresses and the attested hashes equal `ModuleCode.launchHash(6..13)`.

### M8. bindFeeRouter (permissionless)

`V4Market.bindFeeRouter(<FEE_ROUTER>, <N_A>, 1)` (`--step bind-router`).
Check: `<HOOK>.fees()` = `<FEE_ROUTER>`, `<HOOK>.params()` = Params; `flushFees()` simulates without
`NotConfigured`.

### M9. escrow.forward (permissionless)

Precondition: `Desk.registry()` = `<REGISTRY>` (M5 check repeated). Call
`EndowmentEscrow.forward(<REGISTRY>, <N_A>, 1, registryCode, <N_A>, 2, poolCode)` (`--step forward`).
Check: `forwarded()` = true, `TOKEN.balanceOf(ESCROW)` = 0, `TOKEN.balanceOf(RewardPool)` ≥ 200,000,000e18,
`Forwarded` event names the registry and the pool.

### M10. fundEndowment (permissionless)

`RewardPool.fundEndowment()` (`--step fund`).
Check: `endowed()` = true, `lockedEndowment()` = 200,000,000e18 at funding and decreasing linearly over the
drip period.

### M11. Oracle schedules (paid on Ethereum, `schedule.create`)

Inputs: `<DESK>`. Bodies: `node tools/make_oracle_bodies.mjs <DESK>` writes
`docs/oracle-v37/event-schedule.json` (cron `5 */6 * * *` UTC, 4 per day, 28 runs) and
`regulator-schedule.json` (cron `5 0 * * 4` UTC, weekly, 4 runs). Since v3.10 they carry
`consumer {chainId: 4663, verifyingContract: <DESK>}` and **no** `deliver` (schedules refuse it). Preflight
both with the free schedule check first.

Objective (one request per schedule; paste the generated JSON as the input):

> BLACKOUT oracle schedule (Ethereum payment, consumer SwarmDesk <DESK> on Robinhood Chain 4663). Create the schedule exactly as in the attached `schedule.create` body generated by `tools/make_oracle_bodies.mjs` from the accepted BLACKOUT v3.10 commit: committed question body byte-for-byte (questionHash <QUESTION_HASH> from docs/oracle-v37/oracle-config.json), consumer {chainId 4663, verifyingContract <DESK>}, no deliver, cadence <CRON> UTC, <RUNS> runs. Answers are relayed permissionlessly to SwarmDesk.submit. https://x.com/IMDBlackout

Check: `GET /schedules/<id>` shows status active and the runs; after the first run,
`GET /oracle/requests/<run>/attestation` has `verifyingContract` = `<DESK>`, chainId 4663 and the pinned
question hash. Put the ids in `SCHEDULE_EVENT` / `SCHEDULE_REGULATOR`. Cost: 14.5 IMD/week at 0.5 IMD per run.

### M12. Keeper start (requester's `<KEEPER_WALLET>`) — within the first hour after M3

The first `FarmRewards.advanceEpoch()` is allowed from the pool initialization on and **must land before
packs open at launch + 1h**: pack sales record into the live epoch and revert `TooEarly` until epoch 1 exists
(fork rehearsal). Fill `/etc/blackout/keeper.env` from `keeper/keeper.env.example` (RPC, `REGISTRY`, `KEEPER_KEY`,
`SCHEDULE_EVENT`, `SCHEDULE_REGULATOR`, `LAUNCH_FACTORY`, `TOKEN_LAUNCH=<N_T>`), fund the wallet with gas
ETH, `systemctl enable --now blackout-keeper`.
Check: `node keeper/keeper.mjs status` shows the registry, the next epoch, the schedules; after the first
schedule run `SwarmDesk.lastAnswer(0)` shows the relayed answer and the next GridOperator plan is set; the
following `advanceEpoch` calls land at `FarmRewards.epochEnd()`.

### M13. LaunchFactory.claimFees (permissionless, recurring)

`LaunchFactory.claimFees(<N_T>)` (keeper every 6 h, or `--step claim-fees`).
Check: the paying wallet's ETH increases by about 1% of swap volume since the last claim (fork: 0.0198 ETH after
a 2 ETH buy); the IMD network receives 0.25%.

## 4. What is never paused or owned

Claims, withdrawals, sync, settlement, epochs, entropy, repairs, locks/unlocks, buybacks, season finalize,
`Desk.bind`, `bindFeeRouter`, `EndowmentEscrow.forward` and `fundEndowment` have no pause path. The only
pause (new packs incl. the ETH zap and black-market buys) comes from an attested oracle answer, lasts at most
72 hours and needs 72 live hours between pauses. If oracle answers stop, epochs keep running on the fallback
event table and the current Params. Pack profile Balanced, roots, snapshot block and endowment are fixed at
deploy.
