// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ISeats} from "src/PanelRenderer.sol";
import {PanelTestSupport} from "./helpers/PanelTestSupport.sol";

contract PanelOwnersAdversarialTest is PanelTestSupport {
    function test_everyShortLengthAndEveryDirtyHighBitIsRejected() public {
        address valid = address(type(uint160).max);
        bytes memory expected = new bytes(40_000);
        // Alternate invalid and clean responses so a short response cannot
        // reuse the previous call's scratch-memory address.
        for (uint256 length; length < 32; ++length) {
            seats.reply(2 * length, _slice(abi.encode(valid), 0, length), false);
            seats.reply(2 * length + 1, abi.encode(valid), false);
            _putOwner(expected, 2 * length + 1, valid);
        }
        for (uint256 bit = 160; bit < 256; ++bit) {
            seats.reply(64 + bit - 160, abi.encode((uint256(1) << bit) | uint160(valid)), false);
        }
        seats.reply(1999, abi.encode(valid), false);
        _putOwner(expected, 1999, valid);
        assertEq(renderer.owners(), expected);
    }

    function test_cleanAddressAcceptsAllTrailingDataShapesIncludingLargeReplies() public {
        uint256[7] memory lengths = [uint256(32), 33, 63, 64, 65, 4096, 65_536];
        bytes memory expected = new bytes(40_000);
        for (uint256 i; i < lengths.length; ++i) {
            address holder = address(uint160(type(uint160).max - i));
            bytes memory data = new bytes(lengths[i]);
            bytes memory word = abi.encode(holder);
            for (uint256 j; j < 32; ++j) {
                data[j] = word[j];
            }
            if (lengths[i] > 32) {
                data[32] = 0xff;
                data[lengths[i] - 1] = 0xff;
            }
            seats.reply(i, data, false);
            _putOwner(expected, i, holder);
        }
        assertEq(renderer.owners(), expected);
    }

    function test_revertsNeverBecomeOwnersEvenWithCleanAddressOrLargeRevertData() public {
        bytes memory expected = new bytes(40_000);
        address holder = makeAddr("valid after failure");
        seats.reply(0, abi.encode(holder), false);
        seats.reply(1, abi.encode(holder), true);
        seats.reply(2, "", true);
        seats.reply(3, abi.encodeWithSignature("Error(string)", "burned seat"), true);
        bytes memory large = new bytes(65_536);
        bytes memory word = abi.encode(holder);
        for (uint256 i; i < 32; ++i) {
            large[i] = word[i];
        }
        seats.reply(1998, large, true);
        seats.reply(1999, abi.encode(holder), false);
        _putOwner(expected, 0, holder);
        _putOwner(expected, 1999, holder);
        assertEq(renderer.owners(), expected);
    }

    function test_queriesExactlySeatsZeroThrough1999() public {
        for (uint256 id; id < 2000; ++id) {
            vm.expectCall(address(seats), abi.encodeCall(ISeats.ownerOf, (id)), uint64(1));
        }
        assertEq(renderer.owners(), new bytes(40_000));
    }

    function test_noCodeAndStopOnlySeatsYieldExactlyFortyThousandZeroBytes() public {
        vm.etch(address(seats), "");
        assertEq(renderer.owners(), new bytes(40_000));
        vm.etch(address(seats), hex"00");
        assertEq(renderer.owners(), new bytes(40_000));
    }

    function test_transfersBurnsAndRemintsAreReflectedOnEveryRead() public {
        address alice = makeAddr("seat alice");
        address bob = makeAddr("seat bob");
        bytes memory expected = new bytes(40_000);
        seats.reply(0, abi.encode(alice), false);
        seats.reply(1999, abi.encode(alice), false);
        _putOwner(expected, 0, alice);
        _putOwner(expected, 1999, alice);
        assertEq(renderer.owners(), expected);

        seats.reply(0, abi.encode(bob), false);
        seats.reply(1999, abi.encode(alice), true);
        _putOwner(expected, 0, bob);
        _putOwner(expected, 1999, address(0));
        assertEq(renderer.owners(), expected);

        seats.reply(1999, abi.encode(bob), false);
        _putOwner(expected, 1999, bob);
        assertEq(renderer.owners(), expected);
    }

    /// forge-config: default.fuzz.runs = 256
    function testFuzz_arbitraryRepliesDoNotCorruptAdjacentPackedOwners(uint256 seed, address holder, uint96 highSeed)
        public
    {
        uint256 id = bound(seed, 0, 1999);
        uint256 length = bound(seed >> 16, 0, 96);
        bool fail = (seed & (1 << 32)) != 0;
        bool dirty = (seed & (1 << 33)) != 0;
        uint256 high = dirty ? bound(uint256(highSeed), 1, type(uint96).max) : 0;
        bytes memory data = new bytes(length);
        bytes32 word = bytes32((high << 160) | uint160(holder));
        for (uint256 i; i < length; ++i) {
            data[i] = i < 32 ? word[i] : bytes1(0xff);
        }
        seats.reply(id, data, fail);

        bytes memory expected = new bytes(40_000);
        address neighbor = address(type(uint160).max);
        uint256 before = (id + 1999) % 2000;
        uint256 afterId = (id + 1) % 2000;
        seats.reply(before, abi.encode(neighbor), false);
        seats.reply(afterId, abi.encode(neighbor), false);
        _putOwner(expected, before, neighbor);
        _putOwner(expected, afterId, neighbor);
        if (!fail && !dirty && length >= 32) _putOwner(expected, id, holder);
        assertEq(renderer.owners(), expected);
    }
}
