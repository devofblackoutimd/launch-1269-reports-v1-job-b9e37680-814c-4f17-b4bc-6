// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;
import {BaseTest} from "./Base.t.sol";
import {LocalApplicationFactory} from "../script/Deploy.s.sol";
import {GameRegistry} from "../src/GameRegistry.sol";
import {SwarmDesk} from "../src/SwarmDesk.sol";
import {SwarmArgs} from "../script/SwarmArgs.sol";
import {OracleAttestation, OracleAttestationConsumer} from "../src/oracle/OracleAttestation.sol";
import {MockSwarmIntake, MockSwarmDelivery} from "./mocks/MockSwarmIntake.sol";
import {Params} from "../src/Params.sol";
import {GridOperator} from "../src/GridOperator.sol";
import "../src/lib/Errors.sol";

contract SwarmDeskV37Test is BaseTest {
    MockSwarmIntake private intake;
    MockSwarmDelivery private delivery;
    uint256 private nonce;

    function launchFeatures() internal pure override returns (bool) {
        return false;
    }

    function setUp() public override {
        super.setUp();
        SwarmDesk.OracleConfig memory o = desk.oracleConfig();
        MockSwarmIntake model = new MockSwarmIntake();
        vm.etch(o.intake, address(model).code);
        intake = MockSwarmIntake(o.intake);
        intake.setPrice(0.5 ether);
        MockSwarmDelivery relay = new MockSwarmDelivery();
        vm.etch(o.delivery, address(relay).code);
        delivery = MockSwarmDelivery(o.delivery);
        vm.warp((block.timestamp / 6 hours) * 6 hours + 2 hours);
        token.transfer(address(desk), 10 ether);
    }

    function eventValues() private view returns (bytes32[] memory v) {
        v = new bytes32[](7);
        v[0] = bytes32(desk.slot(0));
        v[1] = bytes32(d.rewards.epoch());
        v[2] = bytes32(uint256(1));
        v[3] = bytes32(uint256(7000));
        v[4] = bytes32(uint256(3));
        v[5] = keccak256("oracle salt");
        v[6] = keccak256("offchain letter");
    }

    function regulatorValues() private view returns (bytes32[] memory v) {
        v = new bytes32[](17);
        v[0] = bytes32(desk.slot(1));
        v[16] = keccak256("regulator letter");
    }

    function attestation(uint8 stream, bytes32[] memory v) private returns (OracleAttestation.Attestation memory a) {
        a.requestId = keccak256(abi.encode("uuid", ++nonce));
        a.chainId = 1;
        a.questionHash = desk.oracleConfig().questions[stream];
        a.answerType = 5;
        a.answer = abi.encode(v);
        a.fromBlock = 100;
        a.toBlock = 200;
        a.blockHash = keccak256("anchor");
        a.panelJobId = keccak256("panel");
        a.panelSize = 5;
        a.quorum = 4;
        a.agreed = 5;
        a.issuedAt = uint64(block.timestamp);
        a.expiresAt = uint64(block.timestamp + 6 hours);
    }

    function signature(OracleAttestation.Attestation memory a) private view returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x123456, desk.attestationDigest(a));
        return abi.encodePacked(r, s, v);
    }

    function receiveAnswer(OracleAttestation.Attestation memory a) private {
        bytes memory sig = signature(a);
        assertTrue(
            delivery.deliver(address(desk), keccak256(abi.encode("source", nonce)), a, sig), "200k callback failed"
        );
        assertTrue(desk.consumed(a.requestId));
    }

    function testScheduleDeliveryStoresUnder200kThenExecutesTwoPlans() public {
        OracleAttestation.Attestation memory a = attestation(0, eventValues());
        receiveAnswer(a);
        assertFalse(d.grid.planAt(2).submitted);
        vm.prank(bob);
        desk.execute(0, a.answer);
        assertTrue(d.grid.planAt(2).submitted);
        assertTrue(d.grid.planAt(3).submitted);
        assertEq(d.grid.planAt(2).severity, 7000);
        assertEq(desk.districtHint(), 3);
        assertEq(desk.lastLetterHash(), keccak256("offchain letter"));
        vm.expectRevert(InvalidProof.selector);
        desk.execute(0, a.answer);
    }

    function testForgedTamperedWrongSignerWrongDomainAndCallerRejected() public {
        OracleAttestation.Attestation memory a = attestation(0, eventValues());
        bytes memory sig = signature(a);
        vm.expectRevert(Unauthorized.selector);
        desk.onOracleResult(keccak256("id"), a, sig);
        a.figure++;
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("id"), a, sig);
        a.figure--;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0x9999, desk.attestationDigest(a));
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("id"), a, abi.encodePacked(r, s, v));
        vm.chainId(4663);
        vm.expectRevert(OracleAttestationConsumer.BadSignature.selector);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("id"), a, sig);
    }

    function testWrongQuestionUnknownRequestWeakPanelAndWindowRejected() public {
        OracleAttestation.Attestation memory a = attestation(0, eventValues());
        a.questionHash = keccak256("attacker question");
        bytes memory sig = signature(a);
        vm.expectRevert(InvalidProof.selector);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("id"), a, sig);
        a.questionHash = desk.oracleConfig().questions[0];
        sig = signature(a);
        vm.expectRevert(InvalidProof.selector);
        vm.prank(address(intake));
        desk.onOracleResult(keccak256("unknown"), a, sig);
        a.agreed = 3;
        sig = signature(a);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("id"), a, sig);
        a.agreed = 5;
        a.toBlock = 201;
        sig = signature(a);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("id"), a, sig);
    }

    function testReplayDifferentSourceAndSecondAnswerSameSlotIgnored() public {
        OracleAttestation.Attestation memory a = attestation(0, eventValues());
        receiveAnswer(a);
        bytes memory sig = signature(a);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("different source"), a, sig);
        bytes32[] memory v = eventValues();
        v[3] = bytes32(uint256(5000));
        OracleAttestation.Attestation memory b = attestation(0, v);
        sig = signature(b);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("new source"), b, sig);
        assertFalse(desk.consumed(b.requestId));
        desk.execute(0, a.answer);
        assertEq(d.grid.planAt(2).severity, 7000);
    }

    function testExpiredOldSlotOldEpochAndUnexecutedAnswersNeverAct() public {
        OracleAttestation.Attestation memory a = attestation(0, eventValues());
        a.expiresAt = uint64(block.timestamp - 1);
        bytes memory sig = signature(a);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("expired"), a, sig);
        assertFalse(desk.consumed(a.requestId));
        bytes32[] memory v = eventValues();
        v[0] = bytes32(uint256(v[0]) - 1);
        a = attestation(0, v);
        sig = signature(a);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("old slot"), a, sig);
        assertFalse(desk.consumed(a.requestId));
        v = eventValues();
        v[1] = bytes32(uint256(v[1]) + 1);
        a = attestation(0, v);
        sig = signature(a);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("wrong epoch"), a, sig);
        assertFalse(desk.consumed(a.requestId));
        a = attestation(0, eventValues());
        receiveAnswer(a);
        vm.warp((desk.slot(0) + 1) * 6 hours);
        desk.execute(0, a.answer);
        assertFalse(d.grid.planAt(2).submitted);
    }

    function testEventClampingAndFallbackWithoutAnswer() public {
        bytes32[] memory v = eventValues();
        v[2] = bytes32(type(uint256).max);
        v[3] = bytes32(uint256(1));
        v[4] = bytes32(type(uint256).max);
        OracleAttestation.Attestation memory a = attestation(0, v);
        receiveAnswer(a);
        desk.execute(0, a.answer);
        assertEq(uint256(d.grid.planAt(2).kind), 7);
        assertEq(d.grid.planAt(2).severity, 5000);
        assertEq(desk.districtHint(), 7);
        // Epoch 1 was already started without a plan; expired entropy uses the unchanged fixed table.
        vm.roll(block.number + 300);
        d.grid.resolve(1);
        (GridOperator.Kind kind, uint16 severity,,, bool resolved) = d.grid.eventAt(1);
        assertTrue(resolved);
        assertEq(uint256(kind), uint256(d.grid.fallbackKind(1)));
        assertEq(severity, 10000);
    }

    function testRegulatorClampsParamsAnnouncesPhasesAndThirtyDayCaps() public {
        vm.warp(block.timestamp + 1 days);
        bytes32[] memory v = regulatorValues();
        v[1] = bytes32((uint256(1) << 248) | type(uint248).max);
        v[9] = bytes32(uint256(4));
        v[10] = bytes32(type(uint256).max);
        OracleAttestation.Attestation memory a = attestation(1, v);
        receiveAnswer(a);
        desk.execute(1, a.answer);
        assertEq(d.params.get(Params.Key.EmissionBps), 385);
        assertFalse(d.civic.enabled(3));
        assertEq(d.civic.noticeAt(3), block.timestamp + 48 hours);
        assertEq(d.enhancement.announcedCap(), 12);
        assertGe(d.enhancement.activationAt(), tokenLaunch() + 30 days);
        vm.expectRevert(TooEarly.selector);
        d.civic.enable(3);
        vm.expectRevert(TooEarly.selector);
        d.enhancement.activateCap();
        vm.warp(d.civic.noticeAt(3));
        d.civic.enable(3);
        assertTrue(d.civic.enabled(3));
        vm.warp(d.enhancement.activationAt());
        d.enhancement.activateCap();
        assertEq(d.enhancement.cap(), 12);
        v = regulatorValues();
        v[10] = bytes32(uint256(1));
        a = attestation(1, v);
        receiveAnswer(a);
        desk.execute(1, a.answer);
        assertEq(d.enhancement.announcedCap(), 16);
        assertEq(d.enhancement.activationAt(), block.timestamp + 30 days);
    }

    function testNoopRegulatorAcceptedAndParamsCooldownPreserved() public {
        bytes32[] memory v = regulatorValues();
        v[1] = bytes32((uint256(1) << 248) | type(uint248).max);
        OracleAttestation.Attestation memory a = attestation(1, v);
        receiveAnswer(a);
        desk.execute(1, a.answer);
        assertEq(d.params.get(Params.Key.EmissionBps), 350);
        assertEq(d.civic.noticeAt(3), 0);
    }

    function testBackupPullsExactPriceRecordsRequestAndRestrictsBodyAndCadence() public {
        vm.expectRevert(InvalidProof.selector);
        desk.askBackup(0, bytes("arbitrary"));
        uint256 before_ = token.balanceOf(address(desk));
        bytes32 id = desk.askBackup(0, bytes("event body"));
        assertEq(before_ - token.balanceOf(address(desk)), 0.5 ether);
        assertEq(token.allowance(address(desk), address(intake)), 0);
        assertEq(intake.failureSelector(), desk.onOracleFailure.selector);
        vm.expectRevert(TooEarly.selector);
        desk.askBackup(0, bytes("event body"));
        OracleAttestation.Attestation memory a = attestation(0, eventValues());
        assertTrue(intake.result(id, a, signature(a)));
        assertTrue(desk.consumed(a.requestId));
        desk.execute(0, a.answer);
        assertTrue(d.grid.planAt(2).submitted);
    }

    function testBackupFailureUnknownFailureDeadlineAndPriceCap() public {
        bytes32 id = desk.askBackup(0, bytes("event body"));
        vm.expectRevert(Unauthorized.selector);
        desk.onOracleFailure(id, 1, bytes32("bad"), 0, 0, "");
        vm.expectRevert(InvalidValue.selector);
        vm.prank(address(intake));
        desk.onOracleFailure(keccak256("foreign"), 1, bytes32("bad"), 0, 0, "");
        vm.prank(address(delivery));
        desk.onOracleFailure(id, 1, bytes32("foreign"), 0, 0, "");
        (,, uint8 active) = desk.pending(id);
        assertEq(active, 1);
        assertTrue(intake.failure(id, 2, bytes32("disagreed")));
        assertEq(desk.lastFailure(), bytes32("disagreed"));
        assertFalse(d.grid.planAt(2).submitted);
        vm.warp(block.timestamp + 6 hours);
        intake.setPrice(1 ether);
        vm.expectRevert(InvalidValue.selector);
        desk.askBackup(0, bytes("event body"));
        intake.setPrice(0.5 ether);
        id = desk.askBackup(0, bytes("event body"));
        vm.expectRevert(TooEarly.selector);
        desk.clearExpired(id);
        vm.warp(block.timestamp + 1 hours);
        desk.clearExpired(id);
        (,, active) = desk.pending(id);
        assertEq(active, 0);
    }

    function testNoAdminPathsAndEntireGraphUsesDesk() public {
        assertEq(d.params.swarmWallet(), address(desk));
        assertEq(d.grid.swarmWallet(), address(desk));
        assertEq(address(desk.registry()), address(d.registry));
        assertEq(d.packs.profile(), 1);
        assertTrue(d.packs.profileChosen());
        assertLe(address(desk).code.length, 24576);
        assertLe(address(d.farm).code.length, 24576);
        vm.expectRevert(Unauthorized.selector);
        d.params.set(Params.Key.EmissionBps, 360, "forged");
        vm.expectRevert(Unauthorized.selector);
        d.civic.announce(3, "forged");
        vm.expectRevert(Unauthorized.selector);
        d.enhancement.announceCap(12, "forged");
        vm.expectRevert(Unauthorized.selector);
        d.packs.pause(1);
        vm.expectRevert(Unauthorized.selector);
        d.civic.startWar(1, 2);
        (bool ok,) = address(d.packs).call(abi.encodeWithSignature("selectProfile(uint8)", 0));
        assertFalse(ok);
        (ok,) = address(d.starter).call(abi.encodeWithSignature("setFreeRoot(bytes32)", keccak256("root")));
        assertFalse(ok);
        (ok,) = address(d.billboards).call(abi.encodeWithSignature("blankBillboard(uint256,uint256)", 0, 0));
        assertFalse(ok);
        (ok,) = address(desk).call(abi.encodeWithSignature("setOracleSigner(address)", alice));
        assertFalse(ok);
        (ok,) = address(desk).call(abi.encodeWithSignature("execute(address,bytes)", address(d.params), bytes("")));
        assertFalse(ok);
        vm.expectRevert(AlreadyDone.selector);
        desk.bind(address(d.registry), "", "");
    }

    function testNextSlotAcceptsSameQuestionAndChangedExecutionBytesReject() public {
        OracleAttestation.Attestation memory a = attestation(0, eventValues());
        receiveAnswer(a);
        bytes32[] memory tampered = eventValues();
        tampered[3] = bytes32(uint256(9000));
        vm.expectRevert(InvalidProof.selector);
        desk.execute(0, abi.encode(tampered));
        vm.warp(block.timestamp + 6 hours);
        OracleAttestation.Attestation memory b = attestation(0, eventValues());
        receiveAnswer(b);
        assertEq(a.questionHash, b.questionHash);
        desk.execute(0, b.answer);
        assertTrue(d.grid.planAt(2).submitted);
    }

    function testFutureIssueWrongTypeMalformedLengthAndPriceNeverConsume() public {
        OracleAttestation.Attestation memory a = attestation(0, eventValues());
        a.issuedAt = uint64(block.timestamp + 301);
        bytes memory sig = signature(a);
        vm.expectRevert(abi.encodeWithSelector(OracleAttestationConsumer.AttestationNotYetValid.selector, a.issuedAt));
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("future"), a, sig);
        a.issuedAt = uint64(block.timestamp);
        a.answerType = 3;
        sig = signature(a);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("type"), a, sig);
        a.answerType = 5;
        a.answer = abi.encode(new bytes32[](6));
        sig = signature(a);
        vm.expectRevert(InvalidValue.selector);
        vm.prank(address(delivery));
        desk.onOracleResult(keccak256("length"), a, sig);
        assertFalse(desk.consumed(a.requestId));
    }

    function testRobinhoodNativeClockCallbackWithin200k() public {
        vm.chainId(4663);
        vm.mockCall(address(100), abi.encodeWithSignature("arbBlockNumber()"), abi.encode(uint256(987654)));
        OracleAttestation.Attestation memory a = attestation(0, eventValues());
        receiveAnswer(a);
        (,,,,,, uint48 receivedBlock) = desk.lastAnswer(0);
        assertEq(receivedBlock, 987654);
    }

    function testEmptyChainConstructorAndAuthenticatedBindingRejectSpoofs() public {
        LocalApplicationFactory f = new LocalApplicationFactory();
        SwarmDesk.BindingConfig memory b = desk.bindingConfig();
        b.factory = address(f);
        SwarmDesk fresh = SwarmDesk(deployCode("SwarmDesk.sol:SwarmDesk", SwarmArgs.encode(desk.oracleConfig(), b)));
        assertEq(keccak256(abi.encode(fresh.oracleConfig())), keccak256(abi.encode(desk.oracleConfig())));
        assertEq(keccak256(abi.encode(fresh.bindingConfig())), keccak256(abi.encode(b)));
        assertEq(address(fresh.registry()), address(0));
        bytes memory pCode = type(Params).creationCode;
        bytes memory rCode = type(GameRegistry).creationCode;
        Params p =
            Params(f.deploy(1, 0, bytes.concat(pCode, abi.encode(address(fresh), uint256(200), uint256(1 ether)))));
        bytes memory args = abi.encode(
            address(token),
            address(p),
            address(market),
            d.registry.starterRoot(),
            d.registry.freeRoot(),
            d.registry.snapshotBlock(),
            d.registry.endowment(),
            address(f)
        );
        GameRegistry r = GameRegistry(f.deploy(1, 1, bytes.concat(rCode, args)));
        vm.expectRevert(InvalidProof.selector);
        fresh.bind(address(r), hex"ff", pCode);
        vm.expectRevert(InvalidProof.selector);
        fresh.bind(address(r), rCode, hex"ff");
        vm.expectRevert(InvalidProof.selector);
        fresh.bind(address(d.registry), rCode, pCode);
        GameRegistry spoof = new GameRegistry(
            address(token),
            address(p),
            address(market),
            d.registry.starterRoot(),
            d.registry.freeRoot(),
            d.registry.snapshotBlock(),
            d.registry.endowment(),
            address(f)
        );
        vm.expectRevert(InvalidProof.selector);
        fresh.bind(address(spoof), rCode, pCode);
        GameRegistry wrongRoot = new GameRegistry(
            address(token),
            address(p),
            address(market),
            keccak256("wrong root"),
            d.registry.freeRoot(),
            d.registry.snapshotBlock(),
            d.registry.endowment(),
            address(f)
        );
        vm.expectRevert(InvalidProof.selector);
        fresh.bind(address(wrongRoot), rCode, pCode);
        vm.prank(bob);
        fresh.bind(address(r), rCode, pCode);
        assertEq(address(fresh.registry()), address(r));
        vm.expectRevert(AlreadyDone.selector);
        fresh.bind(address(r), rCode, pCode);
        vm.expectRevert(AlreadyDone.selector);
        f.deploy(1, 1, bytes.concat(rCode, abi.encode("different initcode")));
    }

    function testFlatConstructorRejectsUnusedPackedBits() public {
        SwarmDesk.OracleConfig memory o = desk.oracleConfig();
        SwarmDesk.BindingConfig memory b = desk.bindingConfig();
        bytes memory args = SwarmArgs.encode(o, b);
        assertEq(args.length, 14 * 32);
        bytes memory code = vm.getCode("SwarmDesk.sol:SwarmDesk");
        LocalApplicationFactory f = new LocalApplicationFactory();
        uint256 badContext = SwarmArgs.context(o) | (uint256(1) << 192);
        assembly ("memory-safe") { mstore(add(args, 224), badContext) }
        vm.expectRevert(InvalidValue.selector);
        f.deploy(5, 0, bytes.concat(code, args));
        args = SwarmArgs.encode(o, b);
        uint256 badBinding = SwarmArgs.binding(b) | (uint256(1) << 160);
        assembly ("memory-safe") { mstore(add(args, 416), badBinding) }
        vm.expectRevert(InvalidValue.selector);
        f.deploy(5, 0, bytes.concat(code, args));
    }

    function testFuzzEveryParamHardBoundsAndTenPercentStep(uint8 rawKey, uint248 target) public {
        uint256 key = bound(rawKey, 0, 44);
        vm.warp(block.timestamp + 2 days);
        uint256 old = d.params.get(Params.Key(key));
        (uint256 low, uint256 high) = d.params.bounds(Params.Key(key));
        uint256 expected = target < low ? low : target > high ? high : target;
        if (expected < old - old / 10) expected = old - old / 10;
        if (expected > old + old / 10) expected = old + old / 10;
        bytes32[] memory v = regulatorValues();
        v[1] = bytes32(((key + 1) << 248) | uint256(target));
        OracleAttestation.Attestation memory a = attestation(1, v);
        receiveAnswer(a);
        desk.execute(1, a.answer);
        assertEq(d.params.get(Params.Key(key)), expected);
        assertGe(expected, low);
        assertLe(expected, high);
    }
}
