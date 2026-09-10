// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test, Vm} from "forge-std/Test.sol";
import {StateProbe} from "../../src/source/StateProbe.sol";

/// @dev Returns a caller-chosen number of bytes, to attack the probe's memory use.
contract Bomb {
    uint256 public size;

    function setSize(uint256 s) external {
        size = s;
    }

    fallback() external {
        uint256 s = size;
        assembly {
            let ptr := mload(0x40)
            // Deliberately uninitialised memory: content does not matter, length does.
            return(ptr, s)
        }
    }
}

contract Reverter {
    error Nope(uint256 code);

    function boom() external pure {
        revert Nope(7);
    }

    function assertish() external pure {
        assert(false);
    }
}

contract Value {
    function answer() external pure returns (uint256) {
        return 42;
    }
}

contract StateProbeTest is Test {
    StateProbe probe;
    Value value;
    Reverter reverter;
    Bomb bomb;

    event Probed(
        address indexed target,
        bytes32 indexed callHash,
        address indexed caller,
        bool success,
        bool truncated,
        uint256 blockNumber,
        uint256 blockTimestamp,
        bytes returnData
    );

    function setUp() public {
        probe = new StateProbe();
        value = new Value();
        reverter = new Reverter();
        bomb = new Bomb();
    }

    function test_emitsTheValueTheEvmProduced() public {
        bytes memory data = abi.encodeCall(Value.answer, ());
        vm.expectEmit(true, true, true, true);
        emit Probed(
            address(value),
            keccak256(data),
            address(this),
            true,
            false,
            block.number,
            block.timestamp,
            abi.encode(uint256(42))
        );
        probe.probe(address(value), data);
    }

    /// A reverted read is a result. Reporting it is what lets a consumer tell the
    /// difference between a failed read and an absent one.
    function test_revertingTargetIsRecordedAsFailureNotPropagated() public {
        bytes memory data = abi.encodeCall(Reverter.boom, ());
        vm.recordLogs();
        probe.probe(address(reverter), data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "one log");
        (bool success,,,, bytes memory ret) = abi.decode(logs[0].data, (bool, bool, uint256, uint256, bytes));
        assertFalse(success, "must report failure");
        assertEq(ret, abi.encodeWithSelector(Reverter.Nope.selector, uint256(7)), "revert data preserved");
    }

    function test_probeDoesNotBubbleAssertPanics() public {
        probe.probe(address(reverter), abi.encodeCall(Reverter.assertish, ()));
    }

    /// The whole point of the bounded copy: an arbitrary target must not be able to
    /// choose this transaction's memory cost.
    function test_oversizeReturndataIsTruncatedAndFlagged() public {
        bomb.setSize(probe.MAX_RETURN_BYTES() * 4);
        vm.recordLogs();
        probe.probe(address(bomb), hex"11223344");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool success, bool truncated,,, bytes memory ret) =
            abi.decode(logs[0].data, (bool, bool, uint256, uint256, bytes));
        assertTrue(success);
        assertTrue(truncated, "must flag truncation");
        assertEq(ret.length, probe.MAX_RETURN_BYTES(), "copy is capped");
    }

    function test_exactlyAtTheCapIsNotFlaggedAsTruncated() public {
        bomb.setSize(probe.MAX_RETURN_BYTES());
        vm.recordLogs();
        probe.probe(address(bomb), hex"01");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (, bool truncated,,, bytes memory ret) = abi.decode(logs[0].data, (bool, bool, uint256, uint256, bytes));
        assertFalse(truncated, "boundary is inclusive");
        assertEq(ret.length, probe.MAX_RETURN_BYTES());
    }

    function testFuzz_returndataIsNeverLongerThanTheCap(uint16 requested) public {
        bomb.setSize(requested);
        vm.recordLogs();
        probe.probe(address(bomb), hex"02");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (,,,, bytes memory ret) = abi.decode(logs[0].data, (bool, bool, uint256, uint256, bytes));
        assertLe(ret.length, probe.MAX_RETURN_BYTES());
        assertEq(ret.length, requested > probe.MAX_RETURN_BYTES() ? probe.MAX_RETURN_BYTES() : requested);
    }

    /// A probe must never be able to write to the source chain, whatever it is pointed at.
    function test_probeCannotMutateSourceState() public {
        uint256 before = bomb.size();
        probe.probe(address(bomb), abi.encodeCall(Bomb.setSize, (999)));
        assertEq(bomb.size(), before, "staticcall must forbid the write");
    }

    function test_callToAddressWithNoCodeSucceedsEmpty() public {
        vm.recordLogs();
        probe.probe(address(0xdead), hex"aabb");
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (bool success,,,, bytes memory ret) = abi.decode(logs[0].data, (bool, bool, uint256, uint256, bytes));
        assertTrue(success, "the EVM says this succeeds");
        assertEq(ret.length, 0);
    }

    function test_probeManyEmitsOnePerQuery() public {
        address[] memory targets = new address[](3);
        bytes[] memory datas = new bytes[](3);
        targets[0] = address(value);
        targets[1] = address(reverter);
        targets[2] = address(value);
        datas[0] = abi.encodeCall(Value.answer, ());
        datas[1] = abi.encodeCall(Reverter.boom, ());
        datas[2] = abi.encodeCall(Value.answer, ());
        vm.recordLogs();
        probe.probeMany(targets, datas);
        assertEq(vm.getRecordedLogs().length, 3);
    }

    function test_probeManyRejectsMismatchedLengths() public {
        address[] memory targets = new address[](2);
        bytes[] memory datas = new bytes[](1);
        vm.expectRevert(abi.encodeWithSelector(StateProbe.LengthMismatch.selector, 2, 1));
        probe.probeMany(targets, datas);
    }

    function test_probeManyRejectsEmptyBatch() public {
        vm.expectRevert(StateProbe.EmptyBatch.selector);
        probe.probeMany(new address[](0), new bytes[](0));
    }

    function test_probeManyRejectsOversizeBatch() public {
        uint256 n = probe.MAX_BATCH() + 1;
        vm.expectRevert(abi.encodeWithSelector(StateProbe.BatchTooLarge.selector, n, probe.MAX_BATCH()));
        probe.probeMany(new address[](n), new bytes[](n));
    }
}

/// @dev Burns every unit of gas it is given, then reverts.
contract GasBurner {
    fallback() external {
        while (true) {
            assembly {
                pop(keccak256(0, 32))
            }
        }
    }
}

contract StateProbeGasTest is Test {
    StateProbe probe;
    GasBurner burner;
    Value value;

    function setUp() public {
        probe = new StateProbe();
        burner = new GasBurner();
        value = new Value();
    }

    /// One hostile target must not be able to take the rest of the batch down with it.
    function test_hostileTargetCannotStarveTheRestOfTheBatch() public {
        address[] memory targets = new address[](3);
        bytes[] memory datas = new bytes[](3);
        targets[0] = address(value);
        targets[1] = address(burner);
        targets[2] = address(value);
        datas[0] = abi.encodeCall(Value.answer, ());
        datas[1] = hex"00";
        datas[2] = abi.encodeCall(Value.answer, ());

        vm.recordLogs();
        probe.probeMany{gas: 12_000_000}(targets, datas);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(logs.length, 3, "every query still reported");
        (bool okBurner,,,,) = abi.decode(logs[1].data, (bool, bool, uint256, uint256, bytes));
        assertFalse(okBurner, "the burner is recorded as a failed read");
        (bool okLast,,,, bytes memory ret) = abi.decode(logs[2].data, (bool, bool, uint256, uint256, bytes));
        assertTrue(okLast, "the query after it still ran");
        assertEq(ret, abi.encode(uint256(42)), "and returned the right value");
    }

    function test_singleProbeOfAGasBurnerIsBounded() public {
        uint256 before = gasleft();
        probe.probe(address(burner), hex"00");
        uint256 used = before - gasleft();
        assertLt(used, 2_500_000, "one read cannot burn an unbounded amount");
    }
}
