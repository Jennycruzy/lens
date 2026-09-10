// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {ILensFeed} from "../../src/interfaces/ILensFeed.sol";
import {MedianFeed, RatioFeed} from "../../src/LensComposer.sol";

/// @dev A feed whose answer and age can be driven directly, so composition can be tested
///      without rebuilding the whole proof path underneath it.
contract StubFeed is ILensFeed {
    bool public answering = true;
    uint256 public value_;
    uint256 public age_;

    constructor(uint256 v, uint256 a) {
        value_ = v;
        age_ = a;
    }

    function set(uint256 v, uint256 a) external {
        value_ = v;
        age_ = a;
        answering = true;
    }

    function refuse() external {
        answering = false;
    }

    function read() external view returns (uint256, uint256) {
        require(answering, "refused");
        return (value_, age_);
    }

    function tryRead() external view returns (bool, uint256, uint256) {
        if (!answering) return (false, 0, type(uint256).max);
        return (true, value_, age_);
    }

    function describe() external pure returns (string memory) {
        return "stub";
    }
}

contract LensComposerTest is Test {
    function _feeds(StubFeed a, StubFeed b, StubFeed c) internal pure returns (ILensFeed[] memory f) {
        f = new ILensFeed[](3);
        f[0] = a;
        f[1] = b;
        f[2] = c;
    }

    // --- median ---------------------------------------------------------------

    function test_takesTheMiddleValue() public {
        MedianFeed m =
            new MedianFeed(_feeds(new StubFeed(100, 5), new StubFeed(300, 5), new StubFeed(200, 5)), 2, "median");
        (uint256 v,) = m.read();
        assertEq(v, 200, "sorted middle, not the input order");
    }

    function test_oneOddProberDoesNotMoveTheAnswer() public {
        MedianFeed m = new MedianFeed(
            _feeds(new StubFeed(2000e8, 5), new StubFeed(2001e8, 5), new StubFeed(9999e8, 5)), 2, "median"
        );
        (uint256 v,) = m.read();
        assertEq(v, 2001e8, "the outlier is outvoted");
    }

    function test_evenCountAveragesTheMiddlePair() public {
        ILensFeed[] memory f = new ILensFeed[](4);
        f[0] = new StubFeed(100, 1);
        f[1] = new StubFeed(200, 1);
        f[2] = new StubFeed(300, 1);
        f[3] = new StubFeed(400, 1);
        MedianFeed m = new MedianFeed(f, 2, "median");
        (uint256 v,) = m.read();
        assertEq(v, 250);
    }

    /// The property the invariant suite also enforces.
    function test_ageIsTheStalestInputNotTheAverage() public {
        MedianFeed m =
            new MedianFeed(_feeds(new StubFeed(100, 2), new StubFeed(200, 900), new StubFeed(300, 5)), 2, "median");
        (, uint256 age) = m.read();
        assertEq(age, 900, "a derived value is as old as its oldest input");
    }

    /// A refusal is an absence, not a zero. Counting it as zero would drag a price down.
    function test_refusingInputIsSkippedNotCountedAsZero() public {
        StubFeed a = new StubFeed(2000e8, 5);
        StubFeed b = new StubFeed(2010e8, 5);
        StubFeed c = new StubFeed(2020e8, 5);
        MedianFeed m = new MedianFeed(_feeds(a, b, c), 2, "median");

        c.refuse();
        (uint256 v,) = m.read();
        assertEq(v, (2000e8 + 2010e8) / 2, "the median of what answered");
        assertTrue(v > 1000e8, "and nowhere near zero");
    }

    function test_belowQuorumRefusesRatherThanGuessing() public {
        StubFeed a = new StubFeed(100, 1);
        StubFeed b = new StubFeed(200, 1);
        StubFeed c = new StubFeed(300, 1);
        MedianFeed m = new MedianFeed(_feeds(a, b, c), 2, "median");

        b.refuse();
        c.refuse();
        vm.expectRevert(abi.encodeWithSelector(MedianFeed.NoQuorum.selector, 1, 2));
        m.read();

        (bool ok,,) = m.tryRead();
        assertFalse(ok);
    }

    function test_quorumLargerThanTheInputsIsRejectedAtConstruction() public {
        ILensFeed[] memory f = new ILensFeed[](2);
        f[0] = new StubFeed(1, 1);
        f[1] = new StubFeed(2, 1);
        vm.expectRevert(abi.encodeWithSelector(MedianFeed.NotEnoughInputs.selector, 2, 3));
        new MedianFeed(f, 3, "median");
    }

    // --- ratio ----------------------------------------------------------------

    function test_dividesOneFeedByAnother() public {
        RatioFeed r = new RatioFeed(new StubFeed(150_000e18, 3), new StubFeed(100_000e18, 3), 1e18, "solvency");
        (uint256 v,) = r.read();
        assertEq(v, 1.5e18, "150 percent backed");
    }

    function test_ratioAgeIsTheStalerLeg() public {
        RatioFeed r = new RatioFeed(new StubFeed(150e18, 4), new StubFeed(100e18, 700), 1e18, "solvency");
        (, uint256 age) = r.read();
        assertEq(age, 700);
    }

    function test_eitherLegRefusingRefusesTheRatio() public {
        StubFeed n = new StubFeed(150e18, 3);
        StubFeed d = new StubFeed(100e18, 3);
        RatioFeed r = new RatioFeed(n, d, 1e18, "solvency");

        d.refuse();
        vm.expectRevert(RatioFeed.InputRefused.selector);
        r.read();

        d.set(100e18, 3);
        n.refuse();
        vm.expectRevert(RatioFeed.InputRefused.selector);
        r.read();
    }

    function test_zeroDenominatorRefusesRatherThanReverting() public {
        RatioFeed r = new RatioFeed(new StubFeed(150e18, 3), new StubFeed(0, 3), 1e18, "solvency");
        (bool ok,,) = r.tryRead();
        assertFalse(ok, "a supply of zero has no ratio, and it must not panic");
        vm.expectRevert(RatioFeed.InputRefused.selector);
        r.read();
    }

    // --- composition nests ----------------------------------------------------

    /// A composed feed is an ILensFeed, so it can be an input to another.
    function test_aMedianOfRatiosIsItselfAFeed() public {
        RatioFeed r1 = new RatioFeed(new StubFeed(150e18, 10), new StubFeed(100e18, 10), 1e18, "a");
        RatioFeed r2 = new RatioFeed(new StubFeed(160e18, 40), new StubFeed(100e18, 40), 1e18, "b");
        RatioFeed r3 = new RatioFeed(new StubFeed(170e18, 20), new StubFeed(100e18, 20), 1e18, "c");

        ILensFeed[] memory f = new ILensFeed[](3);
        f[0] = r1;
        f[1] = r2;
        f[2] = r3;
        MedianFeed m = new MedianFeed(f, 2, "median of ratios");

        (uint256 v, uint256 age) = m.read();
        assertEq(v, 1.6e18, "the middle ratio");
        assertEq(age, 40, "and the age still comes from the stalest leaf");
    }

    function testFuzz_medianIsNeverFresherThanItsStalestInput(uint32 a, uint32 b, uint32 c) public {
        MedianFeed m = new MedianFeed(_feeds(new StubFeed(1, a), new StubFeed(2, b), new StubFeed(3, c)), 3, "median");
        (, uint256 age) = m.read();
        uint256 worst = a > b ? a : b;
        if (c > worst) worst = c;
        assertEq(age, worst);
    }
}
