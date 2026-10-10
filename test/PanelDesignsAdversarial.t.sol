// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PanelDesigns} from "src/PanelDesigns.sol";

contract PanelDesignWallet {
    function publish(PanelDesigns designs, bytes32 word) external {
        designs.setDesign(word);
    }

    function clear(PanelDesigns designs) external {
        designs.clearDesign();
    }
}

contract PanelDesignsAdversarialTest is Test {
    PanelDesigns private designs;
    address private alice;
    bytes32 private constant MAX_WORD = bytes32(type(uint256).max);

    function setUp() public {
        designs = new PanelDesigns();
        alice = makeAddr("design adversary");
    }

    function test_zeroMaximumAndRepeatedWritesEachEmitExactlyOneEvent() public {
        _setAndCheckEvent(alice, MAX_WORD);
        _setAndCheckEvent(alice, MAX_WORD);
        _setAndCheckEvent(alice, bytes32(uint256(1)));
        _setAndCheckEvent(alice, bytes32(0));
        _clearAndCheckEvent(alice);
        _clearAndCheckEvent(alice);
    }

    /// Contract wallets own their designs; sharing an origin does not share a word.
    function test_contractWalletUsesImmediateCallerInsteadOfOrigin() public {
        PanelDesignWallet wallet = new PanelDesignWallet();
        _setAndCheckEvent(alice, MAX_WORD);
        vm.prank(alice, alice);
        wallet.publish(designs, bytes32(uint256(1)));
        assertEq(designs.designOf(address(wallet)), bytes32(uint256(1)));
        assertEq(designs.designOf(alice), MAX_WORD);
        vm.prank(alice, alice);
        wallet.clear(designs);
        assertEq(designs.designOf(address(wallet)), bytes32(0));
        assertEq(designs.designOf(alice), MAX_WORD);
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_opaqueWordsSurviveOverwriteAndClear(address holder, bytes32 first, bytes32 last) public {
        _setAndCheckEvent(holder, first);
        _setAndCheckEvent(holder, last);
        _clearAndCheckEvent(holder);
        _setAndCheckEvent(holder, first);
    }

    /// A complete batch oracle includes duplicates, never-written wallets, and
    /// both extreme address values; it is independent of designOf().
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_batchPreservesLengthOrderAndDuplicates(uint256 seed, bytes32[4] memory words) public {
        address[4] memory actors = [address(0), address(1), alice, address(type(uint160).max)];
        for (uint256 i; i < actors.length; ++i) {
            vm.prank(actors[i]);
            designs.setDesign(words[i]);
        }
        uint256 length = bound(seed, 0, 96);
        address[] memory query = new address[](length);
        bytes32[] memory expected = new bytes32[](length);
        address untouched = makeAddr("never published");
        for (uint256 i; i < length; ++i) {
            uint256 which = uint256(keccak256(abi.encode(seed, i))) % 5;
            query[i] = which == 4 ? untouched : actors[which];
            expected[i] = which == 4 ? bytes32(0) : words[which];
        }
        assertEq(designs.designsOf(query), expected);
    }

    function test_allEntrypointsRejectEtherAndLeaveDesignUntouched() public {
        _setAndCheckEvent(alice, MAX_WORD);
        address[] memory holders = new address[](1);
        holders[0] = alice;
        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(PanelDesigns.setDesign, (bytes32(uint256(7))));
        calls[1] = abi.encodeCall(PanelDesigns.clearDesign, ());
        calls[2] = abi.encodeCall(designs.designOf, (alice));
        calls[3] = abi.encodeCall(PanelDesigns.designsOf, (holders));
        calls[4] = "";
        calls[5] = hex"ffffffff";
        vm.deal(alice, 6);
        for (uint256 i; i < calls.length; ++i) {
            vm.prank(alice);
            (bool ok,) = address(designs).call{value: 1}(calls[i]);
            assertFalse(ok, "unexpected payable path");
        }
        assertEq(alice.balance, 6);
        assertEq(address(designs).balance, 0);
        assertEq(designs.designOf(alice), MAX_WORD);
    }

    function test_unknownEmptyAndTruncatedCallsRevertWithoutWriting() public {
        _setAndCheckEvent(alice, MAX_WORD);
        _reject("");
        _reject(hex"ff");
        _reject(hex"ffffffff");
        _reject(abi.encodePacked(PanelDesigns.setDesign.selector));
        _reject(abi.encodePacked(PanelDesigns.setDesign.selector, bytes31(0)));
        _reject(abi.encodePacked(designs.designOf.selector, bytes31(0)));
        _reject(abi.encodePacked(PanelDesigns.designsOf.selector, uint256(32), uint256(1)));
        // The array points past calldata, or an address word has nonzero upper bits.
        _reject(abi.encodePacked(PanelDesigns.designsOf.selector, type(uint256).max));
        _reject(abi.encodePacked(designs.designOf.selector, type(uint256).max));
        _reject(abi.encodePacked(PanelDesigns.designsOf.selector, uint256(32), uint256(1), type(uint256).max));
    }

    function test_stateChangingEntrypointsCannotExecuteInStaticContext() public {
        designs.setDesign(MAX_WORD);
        (bool setOk,) =
            address(designs).staticcall{gas: 100_000}(abi.encodeCall(PanelDesigns.setDesign, (bytes32(uint256(1)))));
        (bool clearOk,) = address(designs).staticcall{gas: 100_000}(abi.encodeCall(PanelDesigns.clearDesign, ()));
        assertFalse(setOk);
        assertFalse(clearOk);
        assertEq(designs.designOf(address(this)), MAX_WORD);
    }

    function _reject(bytes memory data) private {
        vm.recordLogs();
        vm.prank(alice);
        (bool ok,) = address(designs).call(data);
        assertFalse(ok, "malformed call accepted");
        assertEq(vm.getRecordedLogs().length, 0, "rejected call emitted a log");
        assertEq(designs.designOf(alice), MAX_WORD);
    }

    function _setAndCheckEvent(address holder, bytes32 word) private {
        vm.recordLogs();
        vm.prank(holder);
        designs.setDesign(word);
        _checkEvent(holder, word);
        assertEq(designs.designOf(holder), word);
    }

    function _clearAndCheckEvent(address holder) private {
        vm.recordLogs();
        vm.prank(holder);
        designs.clearDesign();
        _checkEvent(holder, bytes32(0));
        assertEq(designs.designOf(holder), bytes32(0));
    }

    function _checkEvent(address holder, bytes32 word) private view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].emitter, address(designs));
        assertEq(logs[0].topics.length, 2);
        assertEq(logs[0].topics[0], keccak256("DesignSet(address,bytes32)"));
        assertEq(logs[0].topics[1], bytes32(uint256(uint160(holder))));
        assertEq(logs[0].data, abi.encode(word));
    }
}
