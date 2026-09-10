// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {LensAggregatorV3} from "../../src/LensAggregatorV3.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {RegistryFeed} from "../../src/RegistryFeed.sol";
import {RatioFeed} from "../../src/LensComposer.sol";
import {ILensFeed} from "../../src/interfaces/ILensFeed.sol";
import {ReserveMonitor} from "../../src/consumers/ReserveMonitor.sol";
import {LensMarket} from "../../src/consumers/LensMarket.sol";
import {VotePort} from "../../src/consumers/VotePort.sol";
import {SnapshotProver} from "../../src/consumers/SnapshotProver.sol";
import {ChainInfoLib} from "../../src/interfaces/IChainInfo.sol";
import {INativeQueryVerifier, NativeQueryVerifierLib} from
    "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {EvmV1Decoder} from "@gluwa/asc-contracts/contracts/common/EvmV1Decoder.sol";
import {ChainInfoStub, VerifierStub, TxFixture} from "../helpers/Precompiles.sol";

/// @dev Shared rig: a real registry with real proofs going through it, so the consumers
///      are tested against the same path production uses rather than against stubs.
abstract contract ConsumerRig is Test {
    uint64 constant KEY = 1;
    uint64 constant CHAIN_ID = 11155111;
    address constant PROBE = address(0xA11CE);
    address constant PROBER = address(0xB0B);
    uint64 constant FRONTIER = 11_676_500;
    uint64 constant SOURCE_TIME = 1_757_000_000;

    LensRegistry registry;
    ChainInfoStub chainInfo;
    VerifierStub verifier;
    uint64 nonce;

    function _setUpRig() internal {
        vm.etch(ChainInfoLib.PRECOMPILE, address(new ChainInfoStub()).code);
        vm.etch(NativeQueryVerifierLib.PRECOMPILE, address(new VerifierStub()).code);
        chainInfo = ChainInfoStub(ChainInfoLib.PRECOMPILE);
        verifier = VerifierStub(NativeQueryVerifierLib.PRECOMPILE);

        chainInfo.setChain(KEY, CHAIN_ID, "Sepolia ethereum");
        chainInfo.setFrontier(KEY, FRONTIER, true);
        chainInfo.setGenesis(KEY, 0);
        verifier.setAccept(true);

        uint64[] memory keys = new uint64[](1);
        uint64[] memory ids = new uint64[](1);
        address[] memory probes = new address[](1);
        keys[0] = KEY;
        ids[0] = CHAIN_ID;
        probes[0] = PROBE;
        registry = new LensRegistry(keys, ids, probes);
        vm.warp(SOURCE_TIME + 5 minutes);
    }

    /// Records a value for the feed defined by (target, callData), through a real proof.
    function _record(address target, bytes memory callData, uint64 height, uint256 value) internal {
        EvmV1Decoder.LogEntry[] memory logs = new EvmV1Decoder.LogEntry[](1);
        logs[0] = TxFixture.probedLog(
            PROBE, registry.PROBED_SIGNATURE(), target, keccak256(callData), PROBER,
            true, false, height, SOURCE_TIME, abi.encode(value)
        );
        verifier.setTxIndex(++nonce);
        registry.submitProof(
            KEY, height, TxFixture.encode(2, 1, logs),
            INativeQueryVerifier.MerkleProof({
                root: keccak256(abi.encode(nonce)), siblings: new INativeQueryVerifier.MerkleProofEntry[](0)
            }),
            INativeQueryVerifier.ContinuityProof({lowerEndpointDigest: bytes32(0), roots: new bytes32[](0)})
        );
    }

    function _feed(address target, bytes memory callData, uint256 maxAge) internal returns (RegistryFeed) {
        return new RegistryFeed(registry, KEY, registry.feedIdFromCallHash(KEY, target, keccak256(callData)), maxAge, "f");
    }
}

// ---------------------------------------------------------------------------

contract ReserveMonitorTest is ConsumerRig {
    address constant RESERVE_TOKEN = address(0x115DC);
    address constant ISSUED_TOKEN = address(0x155ED);

    bytes reservesCall = abi.encodeWithSignature("balanceOf(address)", address(0xC05D));
    bytes supplyCall = abi.encodeWithSignature("totalSupply()");

    ReserveMonitor monitor;

    function setUp() public {
        _setUpRig();
        RegistryFeed reserves = _feed(RESERVE_TOKEN, reservesCall, 500);
        RegistryFeed supply = _feed(ISSUED_TOKEN, supplyCall, 500);
        RatioFeed ratio = new RatioFeed(reserves, supply, 1e18, "reserves over supply");
        monitor = new ReserveMonitor(ratio, 1e18, "issuer backing");
    }

    function test_reportsBackingAboveOneAsSolvent() public {
        _record(RESERVE_TOKEN, reservesCall, FRONTIER - 10, 1_500_000e18);
        _record(ISSUED_TOKEN, supplyCall, FRONTIER - 10, 1_000_000e18);

        (uint256 value,) = monitor.ratio();
        assertEq(value, 1.5e18, "150 percent backed");
        assertTrue(monitor.isSolvent());
    }

    function test_reportsShortfallAndLatchesIt() public {
        _record(RESERVE_TOKEN, reservesCall, FRONTIER - 10, 900_000e18);
        _record(ISSUED_TOKEN, supplyCall, FRONTIER - 10, 1_000_000e18);

        assertFalse(monitor.isSolvent(), "backing does not cover issuance");
        monitor.poke();
        assertTrue(monitor.everBreached());
        assertEq(monitor.worstRatio(), 0.9e18);

        // A later top-up does not erase that it happened.
        _record(RESERVE_TOKEN, reservesCall, FRONTIER - 5, 2_000_000e18);
        _record(ISSUED_TOKEN, supplyCall, FRONTIER - 5, 1_000_000e18);
        monitor.poke();
        assertTrue(monitor.isSolvent(), "solvent again");
        assertTrue(monitor.everBreached(), "but the breach is still on the record");
    }

    /// An outage must not be reported as an insolvency.
    function test_refusesRatherThanCallingAnOutageAnInsolvency() public {
        _record(RESERVE_TOKEN, reservesCall, FRONTIER - 10, 1_500_000e18);
        // supply never proven

        vm.expectRevert(ReserveMonitor.CannotDetermineSolvency.selector);
        monitor.isSolvent();

        (bool determinable, bool solvent,,) = monitor.status();
        assertFalse(determinable, "it says it cannot tell");
        assertFalse(solvent, "rather than asserting insolvency");
    }

    function test_staleLegRefusesTheWholeRatio() public {
        _record(RESERVE_TOKEN, reservesCall, FRONTIER - 10, 1_500_000e18);
        _record(ISSUED_TOKEN, supplyCall, FRONTIER - 1000, 1_000_000e18); // beyond 500

        vm.expectRevert(ReserveMonitor.CannotDetermineSolvency.selector);
        monitor.ratio();
    }
}

// ---------------------------------------------------------------------------

contract LensMarketTest is ConsumerRig {
    address constant ETH_USD = address(0xFEED);
    bytes priceCall = abi.encodeWithSignature("latestAnswer()");

    LensMarket market;
    LensAggregatorV3 aggregator;
    address alice = address(0xA11CE02);
    address liquidator = address(0x11D0);

    function setUp() public {
        _setUpRig();
        bytes32 feedId = registry.feedIdFromCallHash(KEY, ETH_USD, keccak256(priceCall));
        aggregator = new LensAggregatorV3(registry, KEY, feedId, 8, 500, "ETH / USD");
        // 150% collateral, 10% liquidation bonus, price no older than an hour.
        market = new LensMarket(aggregator, 15000, 1000, 1 hours);

        vm.deal(alice, 100 ether);
        vm.deal(liquidator, 100 ether);
        vm.deal(address(market), 10 ether); // liquidity for payouts
    }

    function _price(uint64 height, uint256 usd) internal {
        _record(ETH_USD, priceCall, height, usd * 1e8);
    }

    function test_borrowsAgainstAProvenPrice() public {
        _price(FRONTIER - 10, 2000);

        vm.startPrank(alice);
        market.deposit{value: 10 ether}();
        market.borrow(10_000e18); // $10k against $20k of ETH at 150%
        vm.stopPrank();

        assertEq(market.price(), 2000e8);
        assertGe(market.healthFactor(alice), 1e18, "healthy");
    }

    function test_refusesToBorrowBeyondTheCollateralRatio() public {
        _price(FRONTIER - 10, 2000);
        vm.startPrank(alice);
        market.deposit{value: 1 ether}();
        vm.expectRevert(); // $2000 of collateral cannot support $10k
        market.borrow(10_000e18);
        vm.stopPrank();
    }

    /// The demonstration: a price move on another chain, proven here, triggers a
    /// liquidation in a market that knows nothing about Lens.
    function test_aProvenPriceFallMakesAPositionLiquidatable() public {
        _price(FRONTIER - 100, 2000);
        vm.startPrank(alice);
        market.deposit{value: 10 ether}();
        market.borrow(12_000e18);
        vm.stopPrank();
        assertGe(market.healthFactor(alice), 1e18, "healthy at $2000");

        _price(FRONTIER - 10, 1200); // the source chain moved

        assertLt(market.healthFactor(alice), 1e18, "unhealthy at $1200");

        uint256 before = liquidator.balance;
        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = market.liquidate(alice);

        assertEq(repaid, 12_000e18);
        assertGt(seized, 0);
        assertGt(liquidator.balance, before, "the liquidator was paid in collateral");
        (, uint256 debtAfter) = market.positions(alice);
        assertEq(debtAfter, 0, "debt cleared");
    }

    function test_aHealthyPositionCannotBeLiquidated() public {
        _price(FRONTIER - 10, 2000);
        vm.startPrank(alice);
        market.deposit{value: 10 ether}();
        market.borrow(5_000e18);
        vm.stopPrank();

        vm.prank(liquidator);
        vm.expectRevert();
        market.liquidate(alice);
    }

    /// The market inherits Lens's refusal rather than trading on an unavailable price.
    /// The market inherits Lens's refusal rather than trading on an unavailable price.
    function test_aStalePriceStopsEveryActionThatNeedsOne() public {
        _price(FRONTIER - 1000, 2000); // beyond the aggregator's 500-block bound

        // Depositing needs no price, so it still works.
        vm.prank(alice);
        market.deposit{value: 10 ether}();

        // Everything that acts on a price refuses.
        vm.prank(alice);
        vm.expectRevert();
        market.borrow(1e18);

        vm.expectRevert();
        market.price();
    }

    function test_borrowingRevertsWhenNoPriceHasEverBeenProven() public {
        vm.startPrank(alice);
        market.deposit{value: 10 ether}();
        vm.expectRevert();
        market.borrow(1e18);
        vm.stopPrank();
    }
}

// ---------------------------------------------------------------------------

contract VotePortTest is ConsumerRig {
    address constant TOKEN = address(0x70CE4);
    VotePort port;

    address alice = address(0xA11CE03);
    address bob = address(0xB0B03);
    address mallory = address(0x1A110);

    uint256 snapshot;

    function setUp() public {
        _setUpRig();
        port = new VotePort(registry, KEY, TOKEN, 1000);
        snapshot = FRONTIER - 200;
    }

    function _proveWeight(address who, uint256 weight, uint64 atHeight) internal {
        _record(TOKEN, port.weightCallData(who, snapshot), atHeight, weight);
    }

    function test_votesWithWeightProvenFromTheSourceChain() public {
        uint256 id = port.propose("raise the fee", snapshot, 3 days);
        _proveWeight(alice, 1000e18, FRONTIER - 10);

        vm.prank(alice);
        uint256 used = port.castVote(id, true);
        assertEq(used, 1000e18, "the weight the source chain reported");

        (bool passed, uint256 forVotes,) = port.outcome(id);
        assertTrue(passed);
        assertEq(forVotes, 1000e18);
    }

    function test_aVoterWithNoProofCannotVote() public {
        uint256 id = port.propose("raise the fee", snapshot, 3 days);
        bytes32 expectedFeed = port.weightFeedId(alice, snapshot);
        vm.expectRevert(abi.encodeWithSelector(VotePort.NoProvenWeight.selector, alice, expectedFeed));
        vm.prank(alice);
        port.castVote(id, true);
    }

    /// Weight is bound to the account, so a proof for one holder is useless to another.
    function test_oneHoldersProofCannotBeUsedByAnother() public {
        uint256 id = port.propose("raise the fee", snapshot, 3 days);
        _proveWeight(alice, 1_000_000e18, FRONTIER - 10);

        vm.prank(mallory);
        vm.expectRevert(); // mallory's own feed has nothing in it
        port.castVote(id, true);

        assertTrue(port.weightFeedId(alice, snapshot) != port.weightFeedId(mallory, snapshot));
    }

    /// Weight is bound to the snapshot block, so buying in later changes nothing.
    function test_weightAtADifferentBlockIsADifferentFeed() public {
        assertTrue(
            port.weightFeedId(alice, snapshot) != port.weightFeedId(alice, snapshot + 1),
            "a different block is a different question"
        );
    }

    function test_cannotVoteTwice() public {
        uint256 id = port.propose("raise the fee", snapshot, 3 days);
        _proveWeight(alice, 10e18, FRONTIER - 10);

        vm.startPrank(alice);
        port.castVote(id, true);
        vm.expectRevert(abi.encodeWithSelector(VotePort.AlreadyVoted.selector, id, alice));
        port.castVote(id, false);
        vm.stopPrank();
    }

    function test_cannotVoteAfterClosing() public {
        uint256 id = port.propose("raise the fee", snapshot, 1 days);
        _proveWeight(alice, 10e18, FRONTIER - 10);
        vm.warp(block.timestamp + 2 days);

        vm.prank(alice);
        vm.expectRevert();
        port.castVote(id, true);
    }

    function test_aSnapshotThatIsNotYetAttestedCannotBeProposed() public {
        vm.expectRevert(
            abi.encodeWithSelector(VotePort.SnapshotMustBeInThePast.selector, FRONTIER + 1, uint256(FRONTIER))
        );
        port.propose("too soon", FRONTIER + 1, 1 days);
    }

    function test_aStaleProofCannotBeVotedWith() public {
        uint256 id = port.propose("raise the fee", snapshot, 3 days);
        _proveWeight(alice, 10e18, FRONTIER - 5000); // beyond the 1000-block bound
        vm.prank(alice);
        vm.expectRevert();
        port.castVote(id, true);
    }

    function test_bothSidesTally() public {
        uint256 id = port.propose("raise the fee", snapshot, 3 days);
        _proveWeight(alice, 300e18, FRONTIER - 10);
        _proveWeight(bob, 700e18, FRONTIER - 10);

        vm.prank(alice);
        port.castVote(id, true);
        vm.prank(bob);
        port.castVote(id, false);

        (bool passed, uint256 forVotes, uint256 against) = port.outcome(id);
        assertEq(forVotes, 300e18);
        assertEq(against, 700e18);
        assertFalse(passed);
    }
}

// ---------------------------------------------------------------------------

contract SnapshotProverTest is ConsumerRig {
    address constant TOKEN = address(0x70CE5);
    bytes4 constant GET_PAST_VOTES = 0x3a46b1a8;

    SnapshotProver prover;
    address organiser = address(0x06A);
    address alice = address(0xA11CE04);
    address bob = address(0xB0B04);
    address dust = address(0xD057);

    uint256 snapshot;
    uint256 campaign;

    function setUp() public {
        _setUpRig();
        prover = new SnapshotProver(registry, KEY, 5000);
        snapshot = FRONTIER - 300;

        vm.deal(organiser, 100 ether);
        vm.prank(organiser);
        // 1 wei of reward per token held, minimum 10 tokens, ceiling 5 ether per claim.
        campaign = prover.open{value: 50 ether}(TOKEN, GET_PAST_VOTES, snapshot, 10e18, 1, 5 ether, 30 days);
    }

    function _proveHolding(address who, uint256 amount) internal {
        _record(TOKEN, prover.holdingCallData(campaign, who), FRONTIER - 10, amount);
    }

    function test_claimsOnAProvenHistoricalHolding() public {
        _proveHolding(alice, 1000e18);

        uint256 before = alice.balance;
        vm.prank(alice);
        (uint256 holding, uint256 paid) = prover.claim(campaign);

        assertEq(holding, 1000e18, "what the source chain says was held then");
        assertEq(paid, 1000, "1 wei per token");
        assertEq(alice.balance, before + paid);
    }

    /// The whole point: nobody publishes a list, so nobody can be left off one.
    function test_thereIsNoListToBeOnOrLeftOff() public {
        _proveHolding(bob, 500e18);
        vm.prank(bob);
        (, uint256 paid) = prover.claim(campaign);
        assertGt(paid, 0, "bob claimed without the organiser naming him");

        // The organiser cannot prevent it: nothing they control gates the claim.
        assertEq(prover.campaignOf(campaign).organiser, organiser);
    }

    function test_anUnprovenClaimantIsRefused() public {
        bytes32 expectedFeed = prover.holdingFeedId(campaign, alice);
        vm.expectRevert(abi.encodeWithSelector(SnapshotProver.NoProvenHolding.selector, alice, expectedFeed));
        vm.prank(alice);
        prover.claim(campaign);
    }

    function test_holdingBelowTheMinimumIsRefused() public {
        _proveHolding(dust, 1e18); // minimum is 10e18
        vm.prank(dust);
        vm.expectRevert(abi.encodeWithSelector(SnapshotProver.BelowMinimum.selector, 1e18, 10e18));
        prover.claim(campaign);
    }

    function test_cannotClaimTwice() public {
        _proveHolding(alice, 1000e18);
        vm.startPrank(alice);
        prover.claim(campaign);
        vm.expectRevert(abi.encodeWithSelector(SnapshotProver.AlreadyClaimed.selector, campaign, alice));
        prover.claim(campaign);
        vm.stopPrank();
    }

    function test_aCeilingStopsOneHolderDrainingThePool() public {
        // At 1 wei per whole token, a payout above the 5 ether ceiling needs a holding
        // of more than 5e18 tokens.
        _proveHolding(alice, 10e18 * 1e18);
        vm.prank(alice);
        (, uint256 paid) = prover.claim(campaign);
        assertEq(paid, 5 ether, "capped at the per-claim ceiling");
    }

    function test_eligibilityReportsWithoutReverting() public {
        (bool eligible,,, string memory reason) = prover.eligibility(campaign, alice);
        assertFalse(eligible);
        assertEq(reason, "holding not yet proven");

        _proveHolding(alice, 1000e18);
        uint256 wouldPay;
        (eligible,, wouldPay, reason) = prover.eligibility(campaign, alice);
        assertTrue(eligible);
        assertEq(wouldPay, 1000);
        assertEq(reason, "");
    }

    function test_organiserReclaimsTheRemainderAfterClosing() public {
        _proveHolding(alice, 1000e18);
        vm.prank(alice);
        prover.claim(campaign);

        vm.warp(block.timestamp + 31 days);
        uint256 before = organiser.balance;
        vm.prank(organiser);
        prover.reclaim(campaign);
        assertGt(organiser.balance, before);
    }

    function test_organiserCannotReclaimWhileStillOpen() public {
        vm.prank(organiser);
        vm.expectRevert();
        prover.reclaim(campaign);
    }

    function test_aSnapshotNotYetAttestedCannotOpenACampaign() public {
        vm.prank(organiser);
        vm.expectRevert();
        prover.open{value: 1 ether}(TOKEN, GET_PAST_VOTES, FRONTIER + 1, 0, 1, 0, 1 days);
    }
}

// ---------------------------------------------------------------------------

/// @dev A feed whose decimals and answer are both settable, so a market can be held to
///      the same economic position expressed in different units.
contract FeedWithDecimals is AggregatorV3Interface {
    uint8 private immutable _decimals;
    int256 private _answer;
    uint256 private _updatedAt;

    constructor(uint8 d, int256 answer, uint256 updatedAt_) {
        _decimals = d;
        _answer = answer;
        _updatedAt = updatedAt_;
    }

    function set(int256 answer) external {
        _answer = answer;
    }

    function decimals() external view returns (uint8) {
        return _decimals;
    }

    function description() external pure returns (string memory) {
        return "settable";
    }

    function version() external pure returns (uint256) {
        return 4;
    }

    function latestRoundData() public view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, _answer, _updatedAt, _updatedAt, 1);
    }

    function getRoundData(uint80) external view returns (uint80, int256, uint256, uint256, uint80) {
        return latestRoundData();
    }
}

/**
 * @notice The market must value a position identically however many decimals its feed
 *         reports. This is the test that distinguishes a correct implementation from one
 *         that happens to hardcode the eight decimals a USD feed uses: a hardcoded scale
 *         passes every eight-decimal test and fails here.
 */
contract LensMarketDecimalsTest is Test {
    address alice = address(0xA11CE05);

    function _market(uint8 decimals_, int256 answer) internal returns (LensMarket m) {
        FeedWithDecimals feed = new FeedWithDecimals(decimals_, answer, block.timestamp);
        m = new LensMarket(feed, 15000, 1000, 1 hours);
        vm.deal(address(m), 100 ether);
    }

    function test_theSamePositionValuesIdenticallyAtEightAndEighteenDecimals() public {
        // $2000 per unit, expressed twice.
        LensMarket eight = _market(8, 2000e8);
        LensMarket eighteen = _market(18, 2000e18);

        vm.deal(alice, 200 ether);
        vm.startPrank(alice);
        eight.deposit{value: 10 ether}();
        eight.borrow(10_000e18);
        eighteen.deposit{value: 10 ether}();
        eighteen.borrow(10_000e18);
        vm.stopPrank();

        uint256 hfEight = eight.healthFactor(alice);
        uint256 hfEighteen = eighteen.healthFactor(alice);

        assertEq(hfEight, hfEighteen, "the same position must value the same in either unit");
        // 10 ETH at $2000 is $20,000 against $15,000 required, so 1.333e18.
        assertApproxEqAbs(hfEight, 1.333e18, 0.001e18, "and the figure must be economically right");
    }

    function test_aSixDecimalFeedIsAlsoHandled() public {
        LensMarket six = _market(6, 2000e6);
        vm.deal(alice, 100 ether);
        vm.startPrank(alice);
        six.deposit{value: 10 ether}();
        six.borrow(10_000e18);
        vm.stopPrank();
        assertApproxEqAbs(six.healthFactor(alice), 1.333e18, 0.001e18);
    }

    function test_priceUnitIsTakenFromTheFeedNotAssumed() public {
        assertEq(_market(8, 1e8).PRICE_UNIT(), 1e8);
        assertEq(_market(18, 1e18).PRICE_UNIT(), 1e18);
        assertEq(_market(6, 1e6).PRICE_UNIT(), 1e6);
    }

    /// A liquidation must trigger at the same real price whatever units it is quoted in.
    function test_liquidationTriggersAtTheSameRealPriceInEitherUnit() public {
        FeedWithDecimals f8 = new FeedWithDecimals(8, 2000e8, block.timestamp);
        FeedWithDecimals f18 = new FeedWithDecimals(18, 2000e18, block.timestamp);
        LensMarket eight = new LensMarket(f8, 15000, 1000, 1 hours);
        LensMarket eighteen = new LensMarket(f18, 15000, 1000, 1 hours);
        vm.deal(address(eight), 100 ether);
        vm.deal(address(eighteen), 100 ether);

        vm.deal(alice, 200 ether);
        vm.startPrank(alice);
        eight.deposit{value: 10 ether}();
        eight.borrow(12_000e18);
        eighteen.deposit{value: 10 ether}();
        eighteen.borrow(12_000e18);
        vm.stopPrank();

        assertGe(eight.healthFactor(alice), 1e18);
        assertGe(eighteen.healthFactor(alice), 1e18);

        f8.set(1200e8);
        f18.set(1200e18);

        assertLt(eight.healthFactor(alice), 1e18, "liquidatable at $1200");
        assertLt(eighteen.healthFactor(alice), 1e18, "and equally so in the other unit");
        assertEq(eight.healthFactor(alice), eighteen.healthFactor(alice));
    }
}
