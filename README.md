# BLACKOUT v3.5

Source-only continuation of v3.4. No deployment, broadcast, token launch or mint. [@IMDBlackout](https://x.com/IMDBlackout) · [playblackout.xyz](https://playblackout.xyz) · [free pack claim](https://playblackout.xyz/freepack).

Packs, rooms, repairs, enhancement and lobbying use the existing token. Prices follow the last settled mining yield with explicit floors. Packs and lobbying send 88% to rewards, 10% to the team and 2% to the capped heartbeat; the latter two shares queue for bounded sales through the official pool. Other spending returns entirely to rewards. ETH purchases use an atomic swap-and-pack zap with minimum output. The normal swap fee schedule is retained.

Active items wear 1% each six-hour epoch and use output tiers. Optional auto-repair spends available mining credits at settlement. Enhancement replaces overclock, starts capped at +8, and uses committed future-block entropy. Locks redistribute the fixed mining budget and support district stability; both Green wave and Cheap tariff favor stable districts. Rooms retain age and level gates and require a yield-priced purchase after the free first room.

Weekly token pots receive half the sell surcharge, with 40% for the best farm, three 10% lottery shares, and 30% for the best district's paying farms. The existing best-farm mining allocation remains additional. Free allowlist and Identity MD items mine normally and remain unscrappable until the farm's first paid purchase. Items remain soulbound and now carry on-chain pixel SVG/JSON metadata. Eight district billboards run weekly token auctions.

The code retains immutable deployment identities, exact creation-code enrollment, authenticated pool launch time, endowment funding and hook/router binding gates, lazy settlement, idle expiry, capped governance steps and pull payments. There are no upgrades. Purchases may pause for at most 72 hours with automatic expiry; claims and settlement remain available.

- [Implementation report and open decisions](report.md)
- [Pack options, simulations and limitations](artifacts/v35/simulation.md)
- [Read API and game rules](docs/api-v35.md)
- [Launch parameters and operations](docs/launch-v35.md)
- [Independent contributor review](docs/review-v35-independent.md)
- [Entropy capture operations](docs/entropy-v34.md)
- [Historical v3.4 report](docs/report-v34.md)

## Local checks

The existing compiler configuration (Solidity 0.8.26) and dependencies are unchanged. Default checks need no network or environment variables.

```sh
forge build
python3 tools/pin_module_code.py --check
forge test
forge fmt --check
python3 -m unittest discover -s test/python
node test/reveal.test.mjs
node test/ui-v35.test.mjs
python3 sim/run_v35.py
```

After a Solidity change: format, build, regenerate module pins with `python3 tools/pin_module_code.py`, rebuild, and check pins. Creation-code metadata is part of the binding. After changing pins, use a clean build before deriving launch addresses so prediction helpers cannot retain cached embedded bytecode. The opt-in historical fork test remains separate; the real PoolManager integration runs locally.

## After launch

This assignment authorizes no launch. The separately authorized deployer supplies the real existing token, official pool/launcher, immutable factory, swarm and reserved coordinates, and verifies the original 20% endowment path. The swarm selects the requester-approved pack profile before the first purchase using `PackSale.selectProfile(0..2)`; unset selection keeps purchases closed. The recommended profile is Balanced (1), not an approved deployment choice.

Within seven days of the authenticated launch, the swarm may set the free-pack Merkle root once with `StarterClaim.setFreeRoot(root)`. Build it from the actual approved list (maximum 500 unique wallets) using `tools/freepack_merkle.py`; publish its generated wallet proofs as `ui/allowlist.json`. Claims close 30 days after launch. No placeholder list is supplied.

Publish the actual registry address for the dependency-free `ui/` app. Its wallet connection reads all modules from that registry and verifies the chain. Run native-block entropy capture continuously, epoch advancement every six hours, safe fee conversion when quotes are warm, and weekly preparation/settlement. Keepers supply gas; bounded heartbeat credits are not a service guarantee. Future-block entropy remains sequencer-influenced, not VRF.
