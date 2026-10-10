// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PanelDesigns} from "src/PanelDesigns.sol";

/// Ghost words come only from requested actions, never from contract reads.
contract PanelDesignHandler is Test {
    PanelDesigns public immutable designs;
    address[6] public actors;
    bytes32[6] public expected;
    uint256 public operations;

    constructor(PanelDesigns target) {
        designs = target;
        actors = [
            address(1),
            address(type(uint160).max),
            makeAddr("sequence alice"),
            makeAddr("sequence bob"),
            makeAddr("sequence carol"),
            makeAddr("sequence dave")
        ];
    }

    function publish(uint256 actorSeed, bytes32 word) external {
        uint256 i = bound(actorSeed, 0, actors.length - 1);
        vm.prank(actors[i], actors[(i + 1) % actors.length]);
        designs.setDesign(word);
        expected[i] = word;
        ++operations;
    }

    function erase(uint256 actorSeed) external {
        uint256 i = bound(actorSeed, 0, actors.length - 1);
        vm.prank(actors[i], actors[(i + 1) % actors.length]);
        designs.clearDesign();
        expected[i] = bytes32(0);
        ++operations;
    }

    /// Failed writes are interleaved with valid updates; they must never change
    /// the ghost model or leave ETH behind.
    function rejectedPayment(uint256 actorSeed, bytes32 word, bool clear) external {
        uint256 i = bound(actorSeed, 0, actors.length - 1);
        bytes memory data =
            clear ? abi.encodeCall(PanelDesigns.clearDesign, ()) : abi.encodeCall(PanelDesigns.setDesign, (word));
        vm.deal(actors[i], 1);
        vm.prank(actors[i]);
        (bool ok,) = address(designs).call{value: 1, gas: 100_000}(data);
        assertFalse(ok, "payment unexpectedly accepted");
        assertEq(actors[i].balance, 1, "rejected payment consumed value");
        ++operations;
    }
}

/// No custody accounting exists in these contracts. The state machine is the
/// per-wallet registry: only that wallet's successful last write may determine
/// its word, regardless of interleaved updates, clears, and rejected payments.
/// forge-config: default.invariant.runs = 256
/// forge-config: default.invariant.depth = 64
/// forge-config: default.invariant.fail-on-revert = true
contract PanelDesignsInvariantTest is Test {
    PanelDesigns private designs;
    PanelDesignHandler private handler;
    address private untouched;

    function setUp() public {
        designs = new PanelDesigns();
        handler = new PanelDesignHandler(designs);
        untouched = makeAddr("invariant never written");
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = PanelDesignHandler.publish.selector;
        selectors[1] = PanelDesignHandler.erase.selector;
        selectors[2] = PanelDesignHandler.rejectedPayment.selector;
        targetContract(address(handler));
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_eachWalletMatchesItsOwnLastSuccessfulWrite() public view {
        for (uint256 i; i < 6; ++i) {
            assertEq(designs.designOf(handler.actors(i)), handler.expected(i), "cross-wallet or stale write");
        }
        assertEq(designs.designOf(untouched), bytes32(0));
        assertEq(designs.designOf(address(handler)), bytes32(0), "handler accidentally became caller");
        assertEq(designs.designOf(address(0)), bytes32(0));
        assertEq(address(designs).balance, 0, "nonpayable registry accepted ETH");
    }

    function invariant_batchReadsPreserveModelOrderAndDuplicates() public view {
        address[] memory query = new address[](14);
        bytes32[] memory wanted = new bytes32[](14);
        for (uint256 i; i < 6; ++i) {
            query[i] = handler.actors(5 - i);
            wanted[i] = handler.expected(5 - i);
            query[6 + i] = handler.actors(i);
            wanted[6 + i] = handler.expected(i);
        }
        query[12] = untouched;
        query[13] = address(handler);
        assertEq(designs.designsOf(query), wanted);
    }

    function afterInvariant() public view {
        assertGt(handler.operations(), 0, "handler was never exercised");
    }
}
