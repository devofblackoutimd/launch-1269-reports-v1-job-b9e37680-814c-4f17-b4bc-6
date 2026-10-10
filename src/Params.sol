// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IEmission} from "./interfaces/Interfaces.sol";
import "./lib/Errors.sol";

/// @notice Bounded numeric settings. No mint, withdrawal, ownership or upgrade power.
contract Params is ReentrancyGuard {
    enum Key {
        EmissionBps,
        TariffBps,
        PriceStepBps,
        PriceFloor,
        PremiumBps,
        DemandTarget,
        RepairBps,
        IngameBonusBps,
        TokenRecycleBps,
        TaxDay0Bps,
        TaxFloorBps,
        TaxDecaySeconds,
        LobbyKBps,
        LobbyMinWeight,
        BlackoutCooldownSeconds,
        HeatPenaltyBps,
        InspectionBps,
        InspectionMinHash,
        EpochHashBps,
        SoftCapBps,
        FullSetBps,
        ComputePairBps,
        ElectricityPairBps,
        ShieldPairBps,
        RareSetBps,
        EpicSetBps,
        LegendarySetBps,
        SetCapBps,
        BuyBatch,
        SlippageBps,
        SellHourBps,
        SellDayBps,
        SellDeviationBps
    }
    address public immutable swarmWallet;
    IEmission public immutable emission;
    mapping(Key => uint256) public get;
    mapping(Key => uint256) public lastChanged;
    event ParamChanged(Key indexed key, uint256 oldValue, uint256 newValue);

    constructor(address swarmWallet_, address emission_) {
        if (swarmWallet_ == address(0) || emission_ == address(0)) revert InvalidAddress();
        swarmWallet = swarmWallet_;
        emission = IEmission(emission_);
        uint256[33] memory defaults = [
            uint256(350),
            1500,
            1500,
            0.006 ether,
            5000,
            1000,
            250,
            500,
            7000,
            2000,
            500,
            7 days,
            5000,
            4000,
            3 days,
            2000,
            100,
            100 ether,
            1000,
            200,
            2500,
            1000,
            1500,
            2500,
            500,
            1000,
            2000,
            4000,
            0.5 ether,
            200,
            500,
            400,
            5000
        ];
        for (uint256 i; i < defaults.length; ++i) {
            get[Key(i)] = defaults[i];
        }
    }

    function bounds(Key key) public pure returns (uint256 low, uint256 high) {
        if (key == Key.EmissionBps) return (250, 500);
        if (key == Key.TariffBps) return (1000, 3000);
        if (key == Key.PriceStepBps) return (0, 2000);
        if (key == Key.PriceFloor) return (0.004 ether, 0.01 ether);
        if (key == Key.PremiumBps) return (0, 10000);
        if (key == Key.DemandTarget) return (500, 3000);
        if (key == Key.RepairBps) return (150, 400);
        if (key == Key.IngameBonusBps) return (0, 1000);
        if (key == Key.TokenRecycleBps) return (5000, 9000);
        if (key == Key.TaxDay0Bps) return (1000, 2500);
        if (key == Key.TaxFloorBps) return (0, 500);
        if (key == Key.TaxDecaySeconds) return (3 days, 14 days);
        if (key == Key.LobbyKBps) return (2500, 10000);
        if (key == Key.LobbyMinWeight) return (4000, 7000);
        if (key == Key.BlackoutCooldownSeconds) return (3 days, 12 days);
        if (key == Key.HeatPenaltyBps) return (1000, 3000);
        if (key == Key.InspectionBps) return (0, 200);
        if (key == Key.InspectionMinHash) return (100 ether, 2000 ether);
        if (key == Key.EpochHashBps) return (0, 1500);
        if (key == Key.SoftCapBps) return (100, 500);
        if (key == Key.FullSetBps) return (0, 2500);
        if (key == Key.ComputePairBps) return (0, 1000);
        if (key == Key.ElectricityPairBps) return (0, 1500);
        if (key == Key.ShieldPairBps) return (0, 2500);
        if (key == Key.RareSetBps) return (0, 500);
        if (key == Key.EpicSetBps) return (0, 1000);
        if (key == Key.LegendarySetBps) return (0, 2000);
        if (key == Key.SetCapBps) return (0, 4000);
        if (key == Key.BuyBatch) return (0.1 ether, 1 ether);
        if (key == Key.SlippageBps) return (100, 300);
        if (key == Key.SellHourBps) return (200, 600);
        if (key == Key.SellDayBps) return (0, 500);
        return (2000, 5000);
    }

    function set(Key key, uint256 next) external nonReentrant {
        if (msg.sender != swarmWallet) revert Unauthorized();
        (uint256 low, uint256 high) = bounds(key);
        uint256 old = get[key];
        if (next < low || next > high || next == old) revert InvalidValue();
        if (block.timestamp < lastChanged[key] + 1 days) revert TooEarly();
        uint256 delta = next > old ? next - old : old - next;
        // Relative step; deliberately no rounding up for small integer settings.
        if (delta * 10 > old) revert InvalidValue();
        if (key == Key.TaxFloorBps && next > old) revert InvalidValue();
        if ((key == Key.BlackoutCooldownSeconds || key == Key.LobbyMinWeight) && next < old) revert InvalidValue();
        if (!emission.checkpoint(64)) revert CatchUpRequired();
        get[key] = next;
        lastChanged[key] = block.timestamp;
        emit ParamChanged(key, old, next);
    }
}
