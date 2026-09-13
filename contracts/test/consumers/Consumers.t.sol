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
import {
    INativeQueryVerifier,
    NativeQueryVerifierLib
} from "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
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
            PROBE,
            registry.PROBED_SIGNATURE(),
            target,
            keccak256(callData),
            PROBER,
            true,
            false,
            height,
            SOURCE_TIME,
            abi.encode(value)
        );
        verifier.setTxIndex(++nonce);
        registry.submitProof(
            KEY,
            height,
            TxFixture.encode(2, 1, logs),
            INativeQueryVerifier.MerkleProof({
                root: keccak256(abi.encode(nonce)), siblings: new INativeQueryVerifier.MerkleProofEntry[](0)
            }),
            INativeQueryVerifier.ContinuityProof({lowerEndpointDigest: bytes32(0), roots: new bytes32[](0)})
        );
    }

    function _feed(address target, bytes memory callData, uint256 maxAge) internal returns (RegistryFeed) {
        return
            new RegistryFeed(registry, KEY, registry.feedIdFromCallHash(KEY, target, keccak256(callData)), maxAge, "f");
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

    function test_descriptionExposesTheConfiguredFeed() public {
        assertEq(monitor.description(), "issuer backing");
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
        port = new VotePort(registry, KEY, TOKEN, 0x3a46b1a8, 1000);
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

    function test_frontierRegressionRefusesVotingWeight() public {
        uint256 id = port.propose("raise the fee", snapshot, 3 days);
        _proveWeight(alice, 10e18, FRONTIER - 10);
        chainInfo.setFrontier(KEY, FRONTIER - 100, true);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                VotePort.FrontierRegression.selector, uint256(FRONTIER - 100), uint256(FRONTIER - 10)
            )
        );
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

    function test_publicProposalViewsExposeState() public {
        uint256 id = port.propose("view this", snapshot, 3 days);
        assertEq(port.proposalCount(), 1);
        VotePort.Proposal memory p = port.proposalOf(id);
        assertEq(p.description, "view this");
        assertEq(p.snapshotBlock, snapshot);
        (bool passed, uint256 forVotes, uint256 againstVotes) = port.outcome(id);
        assertFalse(passed);
        assertEq(forVotes, 0);
        assertEq(againstVotes, 0);
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

        // The organiser cannot prevent it: nothing they control stands between a holder and the claim.
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

    function test_eligibilityRefusesAStaleProof() public {
        _proveHolding(alice, 1000e18);
        chainInfo.setFrontier(KEY, FRONTIER + 6000, true);

        (bool eligible, uint256 holding, uint256 wouldPay, string memory reason) = prover.eligibility(campaign, alice);
        assertFalse(eligible);
        assertEq(holding, 0);
        assertEq(wouldPay, 0);
        assertEq(reason, "proof is stale");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SnapshotProver.ProofStale.selector, uint256(6010), uint256(5000)));
        prover.claim(campaign);
    }

    function test_eligibilityRefusesARegressedFrontier() public {
        _proveHolding(alice, 1000e18);
        chainInfo.setFrontier(KEY, FRONTIER - 100, true);

        (bool eligible, uint256 holding, uint256 wouldPay, string memory reason) = prover.eligibility(campaign, alice);
        assertFalse(eligible);
        assertEq(holding, 0);
        assertEq(wouldPay, 0);
        assertEq(reason, "attestation frontier regressed");

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(
                SnapshotProver.FrontierRegression.selector, uint256(FRONTIER - 100), uint256(FRONTIER - 10)
            )
        );
        prover.claim(campaign);
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

// ---------------------------------------------------------------------------

/**
 * @notice The accessor a token family uses is not universal, and choosing one for
 *         everybody excludes the rest silently: the call simply reverts and the weight
 *         reads as unprovable with nothing to say why.
 */
contract VotePortSelectorTest is ConsumerRig {
    address constant COMPOUND_STYLE = address(0x0271);
    address constant OZ_STYLE = address(0x02E4);
    address alice = address(0xA11CE06);

    function setUp() public {
        _setUpRig();
    }

    function test_bothTokenFamiliesAreSupported() public {
        VotePort compound = new VotePort(registry, KEY, COMPOUND_STYLE, 0x782d6fe1, 1000);
        VotePort oz = new VotePort(registry, KEY, OZ_STYLE, 0x3a46b1a8, 1000);

        assertEq(compound.WEIGHT_SELECTOR(), bytes4(0x782d6fe1), "getPriorVotes, as UNI and COMP use");
        assertEq(oz.WEIGHT_SELECTOR(), bytes4(0x3a46b1a8), "getPastVotes, as ERC20Votes uses");

        // The calldata each one asks a prober for differs, which is the whole point.
        assertTrue(
            keccak256(compound.weightCallData(alice, FRONTIER - 100))
                != keccak256(oz.weightCallData(alice, FRONTIER - 100)),
            "a different accessor is a different question"
        );
    }

    function test_aCompoundStyleTokenVotesThroughGetPriorVotes() public {
        VotePort port = new VotePort(registry, KEY, COMPOUND_STYLE, 0x782d6fe1, 1000);
        uint256 snapshot = FRONTIER - 200;
        uint256 id = port.propose("compound-style weight", snapshot, 3 days);

        _record(COMPOUND_STYLE, port.weightCallData(alice, snapshot), FRONTIER - 10, 4200e18);

        vm.prank(alice);
        assertEq(port.castVote(id, true), 4200e18, "weight read through getPriorVotes");
    }

    function test_theSelectorCannotBeLeftUnset() public {
        vm.expectRevert(VotePort.SelectorRequired.selector);
        new VotePort(registry, KEY, COMPOUND_STYLE, bytes4(0), 1000);
    }
}

// ---------------------------------------------------------------------------

/// @notice The paths a position takes after it is opened: repaying, withdrawing, and the
///         refusals that stop a borrower from walking away with the collateral.
contract LensMarketLifecycleTest is Test {
    address alice = address(0xA11CE07);
    FeedWithDecimals feed;
    LensMarket market;

    function setUp() public {
        feed = new FeedWithDecimals(8, 2000e8, block.timestamp);
        market = new LensMarket(feed, 15000, 1000, 1 hours);
        vm.deal(address(market), 100 ether);
        vm.deal(alice, 100 ether);
    }

    function _open(uint256 collateral, uint256 debt) internal {
        vm.startPrank(alice);
        market.deposit{value: collateral}();
        if (debt > 0) market.borrow(debt);
        vm.stopPrank();
    }

    function test_repayReducesDebtAndTotal() public {
        _open(10 ether, 10_000e18);
        assertEq(market.totalDebt(), 10_000e18);

        vm.prank(alice);
        market.repay(4_000e18);

        (, uint256 debt) = market.positions(alice);
        assertEq(debt, 6_000e18);
        assertEq(market.totalDebt(), 6_000e18);
    }

    function test_repayingMoreThanOwedIsRefused() public {
        _open(10 ether, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LensMarket.RepayExceedsDebt.selector, 2_000e18, 1_000e18));
        market.repay(2_000e18);
    }

    function test_repayingWithNoDebtIsRefused() public {
        _open(10 ether, 0);
        vm.prank(alice);
        vm.expectRevert(LensMarket.NoDebt.selector);
        market.repay(1);
    }

    function test_withdrawReturnsCollateralWhenNothingIsOwed() public {
        _open(10 ether, 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        market.withdraw(4 ether);
        assertEq(alice.balance, before + 4 ether);
        (uint256 collateral,) = market.positions(alice);
        assertEq(collateral, 6 ether);
    }

    /// The refusal that matters: collateral cannot be withdrawn out from under a debt.
    function test_withdrawThatWouldUndercollateraliseIsRefused() public {
        _open(10 ether, 12_000e18);
        vm.prank(alice);
        vm.expectRevert();
        market.withdraw(6 ether);

        (uint256 collateral,) = market.positions(alice);
        assertEq(collateral, 10 ether, "nothing left the position");
    }

    function test_withdrawIsAllowedWhileTheDebtStaysCovered() public {
        _open(10 ether, 2_000e18);
        vm.prank(alice);
        market.withdraw(5 ether);
        assertGe(market.healthFactor(alice), 1e18, "still healthy afterwards");
    }

    function test_withdrawingMoreThanDepositedIsRefused() public {
        _open(1 ether, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LensMarket.WithdrawExceedsCollateral.selector, 2 ether, 1 ether));
        market.withdraw(2 ether);
    }

    function test_repayingInFullClearsTheHealthConstraint() public {
        _open(10 ether, 12_000e18);
        vm.startPrank(alice);
        market.repay(12_000e18);
        market.withdraw(10 ether); // now unconstrained
        vm.stopPrank();
        (uint256 collateral, uint256 debt) = market.positions(alice);
        assertEq(collateral, 0);
        assertEq(debt, 0);
        assertEq(market.healthFactor(alice), type(uint256).max, "no debt is infinitely healthy");
    }

    function test_depositingNothingIsRefused() public {
        vm.prank(alice);
        vm.expectRevert(LensMarket.NothingDeposited.selector);
        market.deposit{value: 0}();
    }

    function test_borrowingNothingIsRefused() public {
        _open(10 ether, 0);
        vm.prank(alice);
        vm.expectRevert(LensMarket.NothingBorrowed.selector);
        market.borrow(0);
    }

    /// A feed reporting zero or a negative number is not a price, and must never be
    /// treated as one: at zero every position would appear infinitely undercollateralised.
    function test_aNonPositiveAnswerIsNotAPrice() public {
        feed.set(0);
        vm.expectRevert(abi.encodeWithSelector(LensMarket.InvalidPrice.selector, int256(0)));
        market.price();

        feed.set(-1);
        vm.expectRevert(abi.encodeWithSelector(LensMarket.InvalidPrice.selector, int256(-1)));
        market.price();
    }

    function test_liquidatingSomeoneWithNoDebtIsRefused() public {
        vm.expectRevert(LensMarket.NoDebt.selector);
        market.liquidate(alice);
    }

    function test_aFeedRequiresAnAddress() public {
        vm.expectRevert(LensMarket.FeedRequired.selector);
        new LensMarket(AggregatorV3Interface(address(0)), 15000, 1000, 1 hours);
    }

    /// The seizure is capped by what the position actually holds, so a liquidator can
    /// never take more collateral than exists.
    function test_seizureCannotExceedTheCollateralHeld() public {
        _open(10 ether, 12_000e18);
        feed.set(600e8); // a severe fall: the debt is now worth more than the collateral

        address liquidator = address(0x11D1);
        vm.deal(liquidator, 1 ether);
        vm.prank(liquidator);
        (, uint256 seized) = market.liquidate(alice);

        assertLe(seized, 10 ether, "never more than was deposited");
        (uint256 collateral, uint256 debt) = market.positions(alice);
        assertEq(debt, 0);
        assertEq(collateral, 10 ether - seized);
    }
}
