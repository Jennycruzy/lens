// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";
import {FeedEscrow} from "../../src/FeedEscrow.sol";
import {CircuitBreaker} from "../../src/CircuitBreaker.sol";
import {MedianFeed, RatioFeed} from "../../src/LensComposer.sol";
import {ILensFeed} from "../../src/interfaces/ILensFeed.sol";
import {ChainInfoLib} from "../../src/interfaces/IChainInfo.sol";
import {NativeQueryVerifierLib} from "@gluwa/asc-contracts/contracts/write-ability/common/INativeQueryVerifier.sol";
import {ChainInfoStub, VerifierStub} from "../helpers/Precompiles.sol";
import {EscrowHandler} from "./EscrowHandler.sol";

/**
 * @notice The three properties the first invariant suite could not state, because the
 *         contracts they are about did not exist yet.
 */
contract EscrowInvariantsTest is Test {
    uint64 constant KEY = 1;
    uint64 constant CHAIN_ID = 11155111;
    uint64 constant START_FRONTIER = 1_000_000;

    LensRegistry registry;
    FeedEscrow escrow;
    EscrowHandler handler;

    function setUp() public {
        vm.etch(ChainInfoLib.PRECOMPILE, address(new ChainInfoStub()).code);
        vm.etch(NativeQueryVerifierLib.PRECOMPILE, address(new VerifierStub()).code);
        ChainInfoStub chainInfo = ChainInfoStub(ChainInfoLib.PRECOMPILE);
        VerifierStub verifier = VerifierStub(NativeQueryVerifierLib.PRECOMPILE);

        chainInfo.setChain(KEY, CHAIN_ID, "Sepolia ethereum");
        chainInfo.setFrontier(KEY, START_FRONTIER, true);
        chainInfo.setGenesis(KEY, 0);
        verifier.setAccept(true);

        uint64[] memory keys = new uint64[](1);
        uint64[] memory ids = new uint64[](1);
        address[] memory probes = new address[](1);
        keys[0] = KEY;
        ids[0] = CHAIN_ID;
        probes[0] = address(0xA11CE);
        registry = new LensRegistry(keys, ids, probes);
        escrow = new FeedEscrow(registry);

        handler = new EscrowHandler(registry, escrow, chainInfo, verifier, START_FRONTIER);
        vm.deal(address(handler), 1000 ether);
        targetContract(address(handler));
    }

    /// Invariant 4: what leaves the escrow never exceeds what went into it.
    function invariant_escrowNeverPaysOutMoreThanWasFunded() public view {
        assertLe(
            handler.totalPaidOut() + handler.totalRefunded(),
            handler.totalFunded(),
            "the escrow paid out more than it was ever given"
        );
    }

    /// And the contract's own balance always accounts for the difference.
    function invariant_escrowBalanceMatchesItsLedger() public view {
        assertEq(
            address(escrow).balance,
            handler.totalFunded() - handler.totalPaidOut() - handler.totalRefunded(),
            "the held balance and the ledger disagree"
        );
    }
}

// ---------------------------------------------------------------------------

/// @dev Drives a breaker across values and frontiers, so the refusal can be checked in
///      every state the fuzzer can reach rather than only the ones a test names.
contract BreakerHandler is Test {
    CircuitBreaker public immutable breaker;
    ChainInfoStub public immutable chainInfo;
    uint64 public constant KEY = 1;

    constructor(CircuitBreaker b, ChainInfoStub ci) {
        breaker = b;
        chainInfo = ci;
    }

    function poke() external {
        try breaker.poke() {} catch {}
    }

    function moveFrontier(uint64 h) external {
        chainInfo.setFrontier(KEY, uint64(bound(h, 1, 2_000_000)), true);
    }
}

contract BreakerInvariantsTest is Test {
    uint64 constant KEY = 1;
    CircuitBreaker breaker;
    BreakerHandler handler;
    ChainInfoStub chainInfo;

    function setUp() public {
        vm.etch(ChainInfoLib.PRECOMPILE, address(new ChainInfoStub()).code);
        vm.etch(NativeQueryVerifierLib.PRECOMPILE, address(new VerifierStub()).code);
        chainInfo = ChainInfoStub(ChainInfoLib.PRECOMPILE);
        chainInfo.setChain(KEY, 11155111, "Sepolia ethereum");
        chainInfo.setFrontier(KEY, 1_000_000, true);
        chainInfo.setGenesis(KEY, 0);
        VerifierStub(NativeQueryVerifierLib.PRECOMPILE).setAccept(true);

        uint64[] memory keys = new uint64[](1);
        uint64[] memory ids = new uint64[](1);
        address[] memory probes = new address[](1);
        keys[0] = KEY;
        ids[0] = 11155111;
        probes[0] = address(0xA11CE);
        LensRegistry registry = new LensRegistry(keys, ids, probes);
        breaker = new CircuitBreaker(registry, KEY, keccak256("f"), 500, 300);
        handler = new BreakerHandler(breaker, chainInfo);
        targetContract(address(handler));
    }

    /// Invariant 7: a tripped breaker always refuses a read. There is no state in which
    /// `status` says tripped and `value` hands something back.
    function invariant_aTrippedBreakerAlwaysRefuses() public view {
        (bool tripped,) = breaker.status();
        if (!tripped) return;
        try breaker.value() returns (uint256, uint256) {
            revert("a tripped breaker returned a value");
        } catch {
            // Refusing is the whole point.
        }
    }
}

// ---------------------------------------------------------------------------

contract MedianStub is ILensFeed {
    uint256 public v;
    uint256 public a;
    bool public answering = true;

    function set(uint256 value_, uint256 age_, bool ok) external {
        v = value_;
        a = age_;
        answering = ok;
    }

    function read() external view returns (uint256, uint256) {
        require(answering, "refused");
        return (v, a);
    }

    function tryRead() external view returns (bool, uint256, uint256) {
        return answering ? (true, v, a) : (false, 0, type(uint256).max);
    }

    function describe() external pure returns (string memory) {
        return "stub";
    }
}

contract ComposerHandler is Test {
    MedianStub[3] public inputs;
    MedianFeed public median;
    RatioFeed public ratio;

    constructor(MedianStub[3] memory i, MedianFeed m, RatioFeed r) {
        inputs = i;
        median = m;
        ratio = r;
    }

    function setInput(uint8 which, uint128 value, uint32 age, bool ok) external {
        inputs[which % 3].set(bound(value, 1, type(uint128).max), age, ok);
    }
}

contract ComposerInvariantsTest is Test {
    MedianStub[3] stubs;

    MedianFeed median;
    RatioFeed ratio;
    ComposerHandler handler;

    function setUp() public {
        // A fixed-size storage array has no push; assign into it directly.
        MedianStub[3] memory arr;
        ILensFeed[] memory feeds = new ILensFeed[](3);
        for (uint256 i = 0; i < 3; i++) {
            arr[i] = new MedianStub();
            stubs[i] = arr[i];
            feeds[i] = arr[i];
            arr[i].set(100 + i, 10 * (i + 1), true);
        }

        median = new MedianFeed(feeds, 2, "median");
        ratio = new RatioFeed(arr[0], arr[1], 1e18, "ratio");
        handler = new ComposerHandler(arr, median, ratio);
        targetContract(address(handler));
    }

    /// Invariant 8: a composed feed is never fresher than its stalest input. Averaging
    /// ages, or taking the freshest, would let one current leg disguise several stale ones.
    function invariant_medianIsNeverFresherThanItsStalestAnsweringInput() public view {
        (bool ok,, uint256 age) = median.tryRead();
        if (!ok) return;
        uint256 stalest;
        for (uint256 i = 0; i < 3; i++) {
            (bool answered,, uint256 a) = stubs[i].tryRead();
            if (answered && a > stalest) stalest = a;
        }
        assertEq(age, stalest, "a median reported itself fresher than an input it used");
    }

    function invariant_ratioIsNeverFresherThanItsStalerLeg() public view {
        (bool ok,, uint256 age) = ratio.tryRead();
        if (!ok) return;
        (bool nOk,, uint256 nAge) = stubs[0].tryRead();
        (bool dOk,, uint256 dAge) = stubs[1].tryRead();
        if (!nOk || !dOk) return;
        assertEq(age, nAge > dAge ? nAge : dAge, "a ratio reported itself fresher than a leg");
    }
}
