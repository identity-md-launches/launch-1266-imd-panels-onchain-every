// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {PanelRenderer, ISeats, IPanelDesigns} from "src/PanelRenderer.sol";
import {PanelTestSupport} from "./helpers/PanelTestSupport.sol";

contract PanelScriptAdversarialTest is PanelTestSupport {
    /// Rehearse the actual launch addresses offline. The account-access trace
    /// also catches reads whose failures a constructor might silently swallow.
    function test_launchConstructorDoesNotAccessAnyDependency() public {
        address collection = 0x0000eC93127BAA929E58E97dd0095A2BFb38ec1D;
        address[4] memory chunks = [
            0xFc016403Ea7DAEA4582936E1c8D8D709E17593ab,
            0x0CE16147f1e69D151252f000e8Be3647a120c897,
            0x8E604EeBBC9D49e919b7D3de8534018a87292bE0,
            0xCB8Ecec7902E55A62C34de38c950a907851ae298
        ];
        bytes32 hash = 0xd2c66890e2d2dc456f117c14ff12435ffc6fa56b73ab7955f0d838d8ae76cb76;
        for (uint256 i; i < 4; ++i) {
            assertEq(chunks[i].code.length, 0);
        }
        assertEq(collection.code.length, 0);
        vm.startStateDiffRecording();
        PanelRenderer deployed = new PanelRenderer(
            ISeats(collection), IPanelDesigns(address(designs)), chunks[0], chunks[1], chunks[2], chunks[3], hash
        );
        Vm.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        assertGt(accesses.length, 0, "empty deployment trace");
        for (uint256 i; i < accesses.length; ++i) {
            assertTrue(accesses[i].account != collection, "constructor read seats");
            assertTrue(accesses[i].account != address(designs), "constructor read designs");
            for (uint256 j; j < 4; ++j) {
                assertTrue(accesses[i].account != chunks[j], "constructor read chunk");
            }
        }
        assertEq(address(deployed.seats()), collection);
        assertEq(address(deployed.designs()), address(designs));
        assertEq(deployed.scriptHash(), hash);
        assertEq(deployed.SEAT_COUNT(), 2000);
        address[] memory actual = deployed.chunks();
        assertEq(actual.length, 4);
        for (uint256 i; i < 4; ++i) {
            assertEq(actual[i], chunks[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(PanelRenderer.EmptyChunk.selector, 0));
        deployed.script();
    }

    function test_emptyAndStopOnlyChunksAreRejectedAtEveryIndex() public {
        for (uint256 i; i < 4; ++i) {
            bytes memory original = pieces[i].code;
            vm.etch(pieces[i], "");
            _expectEmpty(i);
            vm.etch(pieces[i], hex"00");
            _expectEmpty(i);
            vm.etch(pieces[i], original);
        }
        assertEq(renderer.script(), source);
    }

    /// Even with an incorrect script hash, length failures take precedence and
    /// always name the earliest missing chunk, for all 15 nonempty subsets.
    function test_allMissingChunkCombinationsReportFirstIndexBeforeHashMismatch() public {
        renderer = _renderer(bytes32(0));
        for (uint256 mask = 1; mask < 16; ++mask) {
            uint256 first = 4;
            for (uint256 i; i < 4; ++i) {
                if ((mask & (1 << i)) != 0) {
                    vm.etch(pieces[i], i % 2 == 0 ? bytes("") : bytes(hex"00"));
                    if (first == 4) first = i;
                } else {
                    vm.etch(pieces[i], abi.encodePacked(bytes1(0), source[i]));
                }
            }
            _expectEmpty(first);
        }
    }

    function test_everyReadRechecksChangedCodeAndAcceptsRestoration() public {
        assertEq(renderer.script(), source);
        assertEq(
            renderer.panelOf(address(this)), _page(source, new bytes(40_000), address(this), bytes32(0), block.chainid)
        );
        for (uint256 i; i < 4; ++i) {
            bytes memory original = pieces[i].code;
            bytes memory changed = _slice(source, 0, source.length);
            changed[i] = bytes1(uint8(changed[i]) ^ 1);
            vm.etch(pieces[i], abi.encodePacked(bytes1(0), changed[i]));
            _expectWrong(keccak256(changed));
            vm.etch(pieces[i], original);
            assertEq(renderer.script(), source);
        }
        assertEq(
            renderer.panelOf(address(this)), _page(source, new bytes(40_000), address(this), bytes32(0), block.chainid)
        );
    }

    function test_changedChunkLengthCannotServeStaleScript() public {
        assertEq(renderer.script(), source);
        vm.etch(pieces[3], abi.encodePacked(bytes1(0), source[3], hex"01"));
        _expectWrong(keccak256(bytes.concat(source, hex"01")));
        vm.etch(pieces[3], hex"00");
        _expectEmpty(3);
    }

    function test_onlyTheFirstByteIsSkippedAndChunksAreNeverCalled() public {
        // Non-STOP prefixes are deliberately permitted by the extraction spec.
        // INVALID at byte zero also proves no chunk is executed as a contract.
        for (uint256 i; i < 4; ++i) {
            vm.etch(pieces[i], abi.encodePacked(bytes1(0xfe), source[i]));
        }
        assertEq(renderer.script(), source);
    }

    function test_repeatedChunkAddressesAreReadOncePerPosition() public {
        vm.etch(pieces[0], hex"0000ff");
        PanelRenderer repeated = new PanelRenderer(
            ISeats(address(seats)),
            IPanelDesigns(address(designs)),
            pieces[0],
            pieces[0],
            pieces[0],
            pieces[0],
            keccak256(hex"00ff00ff00ff00ff")
        );
        assertEq(repeated.script(), hex"00ff00ff00ff00ff");
        address[] memory actual = repeated.chunks();
        for (uint256 i; i < 4; ++i) {
            assertEq(actual[i], pieces[0]);
        }
    }

    /// Fuzz both payload and cut positions; the hash oracle is over the input
    /// before splitting, not over anything returned by script().
    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_unevenChunkBoundariesPreserveAllBytes(bytes memory random, uint256 a, uint256 b, uint256 c)
        public
    {
        // Four mandatory nonempty pieces; fuzzed bytes include zeros and 0xff.
        bytes memory data = bytes.concat(hex"00ff807f", random);
        if (data.length > 1024) data = _slice(data, 0, 1024);
        uint256 cut1 = bound(a, 1, data.length - 3);
        uint256 cut2 = bound(b, cut1 + 1, data.length - 2);
        uint256 cut3 = bound(c, cut2 + 1, data.length - 1);
        uint256[5] memory cuts = [uint256(0), cut1, cut2, cut3, data.length];
        for (uint256 i; i < 4; ++i) {
            vm.etch(pieces[i], bytes.concat(hex"00", _slice(data, cuts[i], cuts[i + 1] - cuts[i])));
        }
        PanelRenderer varied = _renderer(keccak256(data));
        assertEq(varied.script(), data);
        assertEq(varied.scriptHash(), keccak256(data));
    }

    function _expectEmpty(uint256 i) private {
        vm.expectRevert(abi.encodeWithSelector(PanelRenderer.EmptyChunk.selector, i));
        renderer.script();
        vm.expectRevert(abi.encodeWithSelector(PanelRenderer.EmptyChunk.selector, i));
        renderer.panelOf(address(this));
    }

    function _expectWrong(bytes32 actualHash) private {
        vm.expectRevert(abi.encodeWithSelector(PanelRenderer.WrongScript.selector, actualHash));
        renderer.script();
        vm.expectRevert(abi.encodeWithSelector(PanelRenderer.WrongScript.selector, actualHash));
        renderer.panelOf(address(this));
    }
}
