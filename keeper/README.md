# BLACKOUT keeper (v3.7 launch kit)

A single-file Node 22+ keeper with **no npm dependencies** (`lib/eth.mjs` carries its own keccak-256,
secp256k1 signing, RLP and ABI helpers; `node keeper.mjs` needs nothing installed beyond Node).

## What it does, every pass (default every 2 seconds)

| Duty | Calls | Notes |
|---|---|---|
| Oracle execution | Recover `AnswerStored` at the stored native block, verify matching UUID, then `SwarmDesk.execute(stream, answer)` | Runs before epoch advancement; the contract verifies the answer commitment and bounds |
| Advance epochs | `FarmRewards.advanceEpoch()` when `live()` and `epochEnd()` has passed; `GridOperator.resolve(epoch)` if the event is still unresolved | Caller receives the epoch bounty from the heartbeat balance |
| Pack entropy | scans `PackCommitted` logs, then `PackSale.captureEntropy(id)` or `rearm(id)` after the 256-block window | Capture is paid the entropy bounty; packs never lose value |
| Starter entropy | `StarterCommitted` logs, `StarterClaim.captureEntropy` / `rearm` | Same window rules |
| Enhancement | `EnhancementCommitted` logs, `Enhancement.capture(id)` then `resolve(id)` | Resolve reverts while the item is equipped; the keeper retries later |
| Seasons | `Season.prepare(w, 64)` for past weeks after their deadline, `finalize(w)` / `rearm(w)` after `SeasonPrepared`, `rollover(w)` for expired pots | Permissionless, bounty-paid |
| Billboards | `Billboards.settleBillboard(week, d)` for the eight districts | No-op until the billboards phase is enabled |
| System sells | `FeeRouter.sellBatchQuote()` then `executeSells(amount, minimum)` | Exactly the quoted batch, 150 bps floor, five-minute cadence enforced on chain |
| Reward / pot buys | `executeBuys` / `executePotBuys` with `market.quote()` and the Params slippage floor | Batch ≤ Params `BuyBatch`, ≥ 0.05 ETH or the remaining queue |
| Phased release | `Civic.enable(feature)` once a swarm notice has aged 48 hours; `Enhancement.activateCap()` once announced | The keeper can only turn features **on** after the swarm's letter; nothing can turn them off |

Every action is simulated with `eth_call` first and only sent when the simulation succeeds, so disabled
phases, early calls and already-done work never cost gas. Transactions are EIP-1559, signed locally, and
sent through `eth_sendRawTransaction`; the keeper waits for the receipt and logs reverts.

## Install on a Linux VPS

```sh
sudo useradd --system --home /opt/blackout --shell /usr/sbin/nologin blackout
sudo mkdir -p /opt/blackout /etc/blackout /var/lib/blackout
sudo cp -r keeper /opt/blackout/keeper
sudo cp keeper/keeper.env.example /etc/blackout/keeper.env   # then edit: RPC_URL, REGISTRY, KEEPER_KEY
sudo chown -R blackout:blackout /opt/blackout /etc/blackout /var/lib/blackout
sudo chmod 0600 /etc/blackout/keeper.env
sudo cp keeper/blackout-keeper.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now blackout-keeper
journalctl -u blackout-keeper -f
```

The env file is the **only** place the RPC URL and keeper key are read from. It sits outside the
repository; nothing in `keeper/` or the state file ever contains a key. Use a dedicated hot wallet with a
small ETH float. Bounties (epoch, entropy, season, buy/sell work) are credited in FeeRouter and withdrawn
with `FeeRouter.withdraw()` by the keeper address; top the float up from there.

## Commands

```sh
node keeper.mjs status --env /etc/blackout/keeper.env     # read-only: epoch, week, queues, phase flags, what is due
node keeper.mjs once --dry-run --env ...                  # one pass, simulate only, print what would be sent
node keeper.mjs once --env ...                            # one pass, send
node keeper.mjs run --interval 2 --env ...                # loop (what the systemd unit runs)
```

`status` and `--dry-run` work without `KEEPER_KEY`. The state file (`STATE_FILE`, default
`/var/lib/blackout/keeper-state.json`) only holds the last scanned block and pending commit ids; deleting
it is safe (the keeper rescans and skips completed work).

## Before launch

- Run `status` against the published registry: it must list all fourteen modules and show every phase as
  `disabled`. If it throws "unregistered or codeless modules", registration is incomplete.
- Keep one keeper per key (nonces are read from the node; two instances on one key would collide). A second
  VPS with its own key is fine and recommended for redundancy: all duties are permissionless and idempotent.
- The keeper never calls `announce`, `submitPlan`, Params setters or any
  swarm-only function. SwarmDesk alone can call those functions after verifying an oracle answer. Removed profile/root/moderation selectors are never called.

## Local test

`test/scratch/smoke.mjs` (not shipped) signed and sent a value transfer against a local anvil and verified
the recovered sender; `status` against a registry without code exits with the registration error. A full
end-to-end run needs the deployed registry on Robinhood Chain.

## Oracle backup and status (v3.7)

`status` includes both last answer times, pending execution, UTC slots, failure status and SwarmDesk's Robinhood IMD balance. The UI shows the last answer vector and next epoch plan. No oracle signer key is used by the keeper.

From the repository root, `node keeper/keeper.mjs ask-backup --stream event --dry-run --env /etc/blackout/keeper.env` simulates a paid backup. Use `--stream regulator` for the weekly question. A separately authorized operator removes `--dry-run` to send. `--body PATH` selects the exact committed compact body; the contract rejects any changed byte. Copy `docs/oracle-v37/` beside the installed keeper or use absolute `--body` paths. This assignment did not send either command on a live chain.

A backup is available one hour into each UTC slot, at most once per slot, only if no answer was already accepted. A failed ask spends its price; no same-slot retry or refund. The endpoint price must be at or below the immutable maxPrice (0.5 IMD). Anyone may transfer Robinhood IMD to the Desk; there is no withdrawal. Funding this optional balance permits anyone to trigger its bounded schedule of asks. An unrelated gas payer may run all keeper duties; they gain no authority over the answer or modules.

The schedule bodies and cadence are in [launch-v37.md](../launch-v37.md). Ethereum schedule balances and on-chain heartbeat ETH are separate. Schedule top-ups require an external payer; keeper gas accounts are not administrators.
