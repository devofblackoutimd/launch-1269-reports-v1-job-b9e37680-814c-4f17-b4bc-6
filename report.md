# BLACKOUT v3.9 / v3.10 report

Source only. No deployment, broadcast, oracle purchase, schedule, token action or mint. v3.10 finishes v3.9
(job 14aa1d96). **No contract source changed in v3.10**: every module, Registry, Params, SwarmDesk,
EndowmentEscrow and hook build is byte-identical to the v3.9 pins. The v3.8 report is archived at
[docs/report-v38.md](docs/report-v38.md); earlier ones are in `docs/`.
X: https://x.com/IMDBlackout · https://playblackout.xyz · https://playblackout.xyz/freepack

## Changes

### v3.9 (job 14aa1d96, contracts)
- **Fees.** The hook has no network share. After the 30-minute stepped launch tax (90/50/25%, all to rewards)
  it adds exactly 1% to rewards on every swap, plus the progressive sell surcharge (cap 15%). `FeeRouter._base`
  sends 100% to reward ETH. The team's swap income is the platform 1% via `LaunchFactory.claimFees`. Pool fee
  12500.
- **Toolchain pins.** `ModuleCode`/`SwarmCode` pin both the IMD verifier build (viaIR false, bytecode_hash
  none) and the repository's via-IR build. Every runtime is under 24,576 bytes on both (FarmCore 21,987 /
  24,330). The SwarmDesk constructor is twelve words.
- **Severity floor 3000** in GridOperator; the Desk band is 5000–7000.
- **Keeper:** attestation relay, `wire` command (bind-desk with `Desk.registry()` check, register,
  bind-router, forward, fund, claim-fees). UI wiring status. Simulation `sim/run_v39.py`.

### v3.10 (this job, tests, tools, docs)
- **Launch toolchain tests.** The suite now compiles and passes with `FOUNDRY_VIA_IR=false
  FOUNDRY_BYTECODE_HASH=none`. Four stack-too-deep sites were refactored in tests only:
  `EndowmentEscrowV38.t.sol`, `LazyAccounting.t.sol` and two in `SwarmDeskV37.t.sol`.
- **Review fix M-1.** `tools/schedule_bodies.mjs` and `make_oracle_bodies.mjs` now generate `schedule.create`
  bodies with `consumer {4663, Desk}` and no `deliver`. `test/oracle-v310.test.mjs` covers it.
- **Regression tests.** `test/V310.t.sol` checks that the build's own 14 modules plus Registry and Params match
  one toolchain's pins together. `testTwinWithForeignTokenCannotDrainEscrow` covers the bounded part of M-2.
- **Docs.** [launch-v39.md](launch-v39.md) is the final ordered runbook (Sepolia rehearsal, then 4663) with
  objective texts, inputs and on-chain checks per step. [docs/review-v39-independent.md](docs/review-v39-independent.md)
  is the review.

## Tests on both toolchains

| Check | IMD verifier toolchain (`FOUNDRY_VIA_IR=false FOUNDRY_BYTECODE_HASH=none`) | Repository toolchain (`foundry.toml`, via-IR) |
|---|---|---|
| `forge build` | Passes (v3.9: failed, stack too deep) | Passes (~10 min compile) |
| `forge test` | **262 passed, 0 failed, 1 skipped** (optional live-RPC fork), 45 suites | Full suite 259/0/1 before the v3.10 additions. The four changed or new suites were re-run afterwards: 36/36 passed. Total 262 passed, 0 failed, 1 skipped |
| `forge fmt --check` | Passes | same |
| Pins (`tools/pin_module_code.py --check`, `tools/pin_swarm_code.py --check`) | All 14 modules plus Registry/Params match; every runtime ≤ 24,576 | same |
| Flattened `launch/V4Market.sol` | Byte-identical to `src/V4Market.sol` and embeds `REGISTRY_LAUNCH` | n/a |
| Node: `oracle-v37`, `keeper-v39`, `oracle-v310` | Pass | — |

Logs are in `artifacts/v310/`. The repository toolchain's full run was not repeated after the last test edits
because of its ten-minute compile; the edited suites were re-run on it.

## Simulation (Balanced, 35 days, five seeds, medians; from `artifacts/v39/simulation.md`)

| Scenario | v3.6 team ETH | v3.9 team ETH (swarm sells 50% day 1) | v3.6 drawdown | v3.9 drawdown | v3.6 week-1 payback | v3.9 week-1 payback |
|---|---:|---:|---:|---:|---:|---:|
| steady | 3.579 | 3.586 | 1.8% | 7.5% | 3.75 d | 3.75 d |
| weak | 0.917 | 0.914 | 0.7% | 11.2% | 4.25 d | 4.25 d |
| hype | 4.996 | 5.008 | 1.9% | 2.2% | 3.50 d | 3.25 d |

v3.6 used 11.1 ETH FDV and no swarm sales; v3.9 uses 10 ETH FDV and the swarm's 10% claimable after one hour.
The fee rework does not move team income: the team gets 1% of volume plus 10% of packs and of the surcharge
in both. The swarm sales set the larger drawdown in the first day. These are conditional model outputs, not
predictions. v3.10 did not re-run the simulation because no economics changed.

## Review result

The second-contributor review of v3.8 → v3.9 is in [docs/review-v39-independent.md](docs/review-v39-independent.md):
- **T-1** (launch blocker): tests did not compile on the verifier toolchain. Fixed.
- **M-1**: schedule bodies with `deliver`. Fixed, with a regression test.
- **M-2**: twin front-run of `Desk.bind`. Open by design, mitigated operationally (see below).
- **L-1**: mixed-toolchain artifacts would strand hook fees. Documented, with a pin-consistency test.

Fees, severity floor, escrow refactor, Desk constructor packing and keeper relay/wiring had no findings.

## Still open

1. **M-2 twin front-run.** It cannot be closed without an on-chain fact only the honest launch has. Mitigation:
   keep `starterRoot`, `freeRoot`, the snapshot block and the lists private until `Desk.registry()` equals the
   job A registry; bind immediately after job A; never forward otherwise. If the requester wants a code fix,
   they must decide the anchor (for example a factory record of the payer). That changes the Desk pin.
2. **Requester inputs:** snapshot block, the two Merkle roots, the keeper wallet and its RPC, the Ethereum IMD
   for the schedules, and the Sepolia platform addresses (read and verified at rehearsal time).
3. **Sepolia rehearsal** (runbook §2): not run. Attested creation-code hashes, the `afterInitialize` sender, gas
   per launch, the relay and `claimFees` are unproven on a live chain.
4. Slither/Mythril and live oracle schedules were not run. This is not an external audit.

## Responsibilities

The requester pays and approves each launch job and the schedules, and supplies the inputs above. Anyone may send
the permissionless wiring calls; the keeper wallet only pays gas and holds no game power. SwarmDesk acts only on
attested oracle answers within hard-coded bounds. Nothing is upgradeable or owned.
