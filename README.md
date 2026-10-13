# BLACKOUT v3.8

Source-only continuation of v3.7 against the real IMD platform (research job b94e6839): no launch number is known at construction, the 20% endowment goes through an ownerless `EndowmentEscrow`, the hook matches the platform pool fee 12500, and the Desk accepts relayed attestations through `submit`. See [launch-v38.md](launch-v38.md) for what is done and what is still open. No deployment, broadcast, token launch or mint. [@IMDBlackout](https://x.com/IMDBlackout) · [playblackout.xyz](https://playblackout.xyz) · [free pack claim](https://playblackout.xyz/freepack).

Packs, rooms, repairs, enhancement and lobbying use the existing token. Prices follow the last settled mining yield with explicit floors. Packs and lobbying send 88% to rewards, 10% to the team and 2% to the capped heartbeat; the latter two shares queue for bounded sales through the official pool. Other spending returns entirely to rewards. ETH purchases use an atomic swap-and-pack zap with minimum output. The normal swap fee schedule is retained.

Active items wear 1% each six-hour epoch and use output tiers. Optional auto-repair spends available mining credits at settlement. Enhancement replaces overclock, starts capped at +8, and uses committed future-block entropy. Locks redistribute the fixed mining budget and support district stability; both Green wave and Cheap tariff favor stable districts. Rooms retain age and level gates and require a yield-priced purchase after the free first room.

Weekly token pots receive half the sell surcharge, with 40% for the best farm, three 10% lottery shares, and 30% for the best district's paying farms. The existing best-farm mining allocation remains additional. Free allowlist and Identity MD items mine normally and remain unscrappable until the farm's first paid purchase. Items remain soulbound and now carry on-chain pixel SVG/JSON metadata. Eight district billboards run weekly token auctions.

The code retains immutable deployment identities, exact creation-code enrollment, authenticated pool launch time, endowment funding and hook/router binding gates, lazy settlement, idle expiry, capped governance steps and pull payments. There are no upgrades. Purchases may pause for at most 72 hours with automatic expiry; claims and settlement remain available.

- [Implementation report and open decisions](report.md)
- [Pack options, simulations and limitations](artifacts/v35/simulation.md)
- [Read API and game rules](docs/api-v35.md)
- [v3.8 launch kit, blocker table and open items](launch-v38.md)
- [v3.7 launch parameters, exact oracle bodies and operations](launch-v37.md)
- [M-2 twin front-run trust assumption (v3.12)](docs/m2-trust-assumption.md)
- [Platform research report b94e6839 (copy)](docs/research/b94e6839-platform-report.md)
- [Independent v3.7 contributor review](docs/review-v37-independent.md)
- [Entropy capture operations](docs/entropy-v34.md)
- [Historical v3.4 report](docs/report-v34.md)

## Local checks

The existing compiler configuration (Solidity 0.8.26) and dependencies are unchanged. Default checks need no network or environment variables.

```sh
forge build
python3 tools/pin_module_code.py --check
python3 tools/pin_swarm_code.py --check
python3 tools/check_v37_authority.py
node test/oracle-v37.test.mjs
forge test
forge fmt --check
python3 -m unittest discover -s test/python
node test/reveal.test.mjs
node test/ui-v35.test.mjs
python3 sim/run_v35.py
```

After a Solidity change: format, build, regenerate module pins with `python3 tools/pin_module_code.py`, rebuild, and check pins. Creation-code metadata is part of the binding. After changing pins, use a clean build before deriving launch addresses so prediction helpers cannot retain cached embedded bytecode. The opt-in historical fork test remains separate; the real PoolManager integration runs locally.

## After launch

Follow [launch-v38.md](launch-v38.md) (order, wiring calls, objective texts); `launch-v37.md` keeps the oracle bodies and question definitions. The requester supplies the existing token, launch identities and coordinates, and the frozen free-pack / Identity MD roots and snapshot. Balanced packs are fixed at deployment. No swarm wallet is supplied: every swarm authority points to the non-upgradeable SwarmDesk, whose only inputs are attested oracle answers. Both roots are constructor arguments; free claims retain the 30-day window.

Ethereum-funded IMD schedules deliver four event answers per day and one weekly regulator (about 2.0714 IMD/day). Permissionless keepers execute committed answers and enable announced phases after notice. Anyone can top up SwarmDesk with Robinhood IMD for its rate-limited backup asks. No game administrator, signer key, root setter, profile selection or moderation path exists. Oracle endpoints and signer are immutable under this explicit no-admin policy.

Publish the actual registry address for the dependency-free `ui/` app. Its wallet connection reads all modules from that registry and verifies the chain. Run native-block entropy capture continuously, epoch advancement every six hours, safe fee conversion when quotes are warm, and weekly preparation/settlement. Keepers supply gas; bounded heartbeat credits are not a service guarantee. Future-block entropy remains sequencer-influenced, not VRF.
