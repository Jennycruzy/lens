// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {LensConsumer} from "../../src/LensConsumer.sol";
import {LensRegistry} from "../../src/LensRegistry.sol";

/**
 * @notice The freshness arithmetic, proved for every input rather than sampled.
 *
 * @dev Run with `halmos --match-contract FreshnessSymbolic` (see SETUP.md). Every
 *      `check_` function is executed once over symbolic inputs: the solver either finds
 *      a counterexample or proves that none exists for any 64-bit frontier and height,
 *      any bound, and any combination of the success and truncation flags.
 *
 *      The registry is replaced by a model that returns whatever the test stored. That
 *      is the right boundary here: what is proved is that {LensConsumer} never hands a
 *      value to a caller unless it is present, succeeded, whole and within the bound —
 *      whatever the registry reports. The registry's own six checks are covered by the
 *      adversarial suite, which needs the precompile stubs rather than a solver.
 */
contract RegistryModel {
    LensRegistry.Observation private observation;
    bool private present;
    uint64 private frontier;

    function set(LensRegistry.Observation memory o, bool isPresent, uint64 f) external {
        observation = o;
        present = isPresent;
        frontier = f;
    }

    function hasObservation(bytes32) external view returns (bool) {
        return present;
    }

    function observationOf(bytes32) external view returns (LensRegistry.Observation memory) {
        return observation;
    }

    function frontierOf(uint64) external view returns (uint64) {
        return frontier;
    }
}

contract Reader is LensConsumer {
    constructor(LensRegistry lens) LensConsumer(lens) {}

    function _defaultChainKey() internal pure override returns (uint64) {
        return 1;
    }

    function tryRead(bytes32 id, uint256 maxAge) external view returns (bool, bytes memory, uint256) {
        return _tryLatest(id, maxAge);
    }

    function read(bytes32 id, uint256 maxAge) external view returns (bytes memory) {
        return _latest(id, maxAge);
    }
}

contract FreshnessSymbolicTest is Test {
    RegistryModel model;
    Reader reader;
    bytes32 constant ID = keccak256("feed");
    bytes constant VALUE = hex"0000000000000000000000000000000000000000000000000de0b6b3a7640000";

    function setUp() public {
        model = new RegistryModel();
        reader = new Reader(LensRegistry(address(model)));
    }

    function _arrange(bool present, bool succeeded, bool truncated, uint64 frontier, uint64 height) private {
        model.set(
            LensRegistry.Observation({
                returnData: VALUE,
                probeHeight: height,
                sourceTimestamp: 1,
                recordedAt: 1,
                callSucceeded: succeeded,
                truncated: truncated,
                prober: address(0xBEEF)
            }),
            present,
            frontier
        );
    }

    /// A value is handed out only when present, succeeded, whole, not regressed and within the bound.
    function check_okImpliesEveryCondition(
        bool present,
        bool succeeded,
        bool truncated,
        uint64 frontier,
        uint64 height,
        uint256 maxAge
    ) public {
        _arrange(present, succeeded, truncated, frontier, height);
        (bool ok, bytes memory data, uint256 age) = reader.tryRead(ID, maxAge);
        if (ok) {
            assert(present && succeeded && !truncated);
            assert(height <= frontier);
            assert(age == uint256(frontier) - height);
            assert(age <= maxAge);
            assert(keccak256(data) == keccak256(VALUE));
        }
    }

    /// Every input that satisfies the conditions is accepted: refusal is never spurious.
    function check_everyConditionImpliesOk(uint64 frontier, uint64 height, uint256 maxAge) public {
        vm.assume(height <= frontier);
        vm.assume(uint256(frontier) - height <= maxAge);
        _arrange(true, true, false, frontier, height);
        (bool ok,,) = reader.tryRead(ID, maxAge);
        assert(ok);
    }

    /// A refused read never carries bytes.
    function check_refusalCarriesNoValue(
        bool present,
        bool succeeded,
        bool truncated,
        uint64 frontier,
        uint64 height,
        uint256 maxAge
    ) public {
        _arrange(present, succeeded, truncated, frontier, height);
        (bool ok, bytes memory data,) = reader.tryRead(ID, maxAge);
        if (!ok) assert(data.length == 0);
    }

    /// A frontier below the recorded height is the maximum age, never zero, whatever the bound.
    function check_regressionIsNeverAgeZero(uint64 frontier, uint64 height, uint256 maxAge) public {
        vm.assume(height > frontier);
        _arrange(true, true, false, frontier, height);
        (bool ok,, uint256 age) = reader.tryRead(ID, maxAge);
        assert(!ok);
        assert(age == type(uint256).max);
    }

    /// The reverting read and the reporting read agree on every input.
    function check_strictAndTryAgree(
        bool present,
        bool succeeded,
        bool truncated,
        uint64 frontier,
        uint64 height,
        uint256 maxAge
    ) public {
        _arrange(present, succeeded, truncated, frontier, height);
        (bool ok,,) = reader.tryRead(ID, maxAge);
        try reader.read(ID, maxAge) returns (bytes memory data) {
            assert(ok);
            assert(keccak256(data) == keccak256(VALUE));
        } catch {
            assert(!ok);
        }
    }
}
