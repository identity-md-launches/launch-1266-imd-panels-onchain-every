// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {PanelRenderer} from "src/PanelRenderer.sol";
import {PanelTestSupport} from "./helpers/PanelTestSupport.sol";

contract PanelPageAdversarialTest is PanelTestSupport {
    function setUp() public override {
        super.setUp();
        seats.reply(0, abi.encode(address(1)), false);
        seats.reply(31, abi.encode(address(uint160(0xabcdef))), false);
        seats.reply(1999, abi.encode(address(type(uint160).max)), false);
    }

    /// Covers all three padding cases at the minimum script size and around
    /// memory-word boundaries. Nonzero tail bytes catch overreads and lost bits.
    function test_base64PaddingAtMinimumAndMemoryWordBoundaries() public {
        uint256[12] memory lengths = [uint256(4), 5, 6, 31, 32, 33, 63, 64, 65, 95, 96, 97];
        bytes memory owners = _knownOwners();
        address wallet = address(type(uint160).max);
        bytes32 word = bytes32(type(uint256).max);
        vm.prank(wallet);
        designs.setDesign(word);
        for (uint256 i; i < lengths.length; ++i) {
            bytes memory data = new bytes(lengths[i]);
            for (uint256 j; j < data.length; ++j) {
                data[j] = bytes1(uint8(j));
            }
            data[data.length - 1] = 0xff;
            _setSource(data);
            assertEq(renderer.panelOf(wallet), _page(data, owners, wallet, word, block.chainid));
        }
    }

    /// Explicitly requires the standard '+' and '/' alphabet rather than base64url.
    function test_base64UsesStandardAlphabetAndZeroBytesAreNotTerminators() public {
        bytes memory data = hex"fbffff0000ff";
        assertEq(vm.toBase64(data), "+///AAD/");
        _setSource(data);
        assertEq(renderer.panelOf(address(0)), _page(data, _knownOwners(), address(0), bytes32(0), block.chainid));
    }

    // Foundry 1.8.3's vm.chainId accepts only uint64 values, although the EVM
    // instruction has a 256-bit result. Exercise the entire supported domain.
    function test_decimalChainIdHandlesZeroPowersOfTenAndSupportedMaximum() public {
        uint256[10] memory ids = [uint256(0), 1, 9, 10, 99, 100, 999, 1000, 10 ** 19, uint256(type(uint64).max)];
        bytes memory owners = _knownOwners();
        for (uint256 i; i < ids.length; ++i) {
            vm.chainId(ids[i]);
            assertEq(renderer.panelOf(address(0)), _page(source, owners, address(0), bytes32(0), ids[i]));
        }
    }

    /// The 40,000-byte owner buffer has a one-byte base64 tail; its last owner
    /// is all 0xff so the test observes every meaningful bit of that tail.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_pageEncodesArbitraryBinaryScriptAndFullWidthValues(
        bytes memory random,
        address wallet,
        bytes32 word,
        uint64 chainId
    ) public {
        bytes memory data = bytes.concat(hex"00fbff80", random);
        if (data.length > 512) data = _slice(data, 0, 512);
        _setSource(data);
        vm.prank(wallet);
        designs.setDesign(word);
        vm.chainId(chainId);
        assertEq(renderer.panelOf(wallet), _page(data, _knownOwners(), wallet, word, chainId));
    }

    function test_pageUsesCurrentOwnersAndDesignWithoutRequiringSeatOwnership() public {
        address wallet = makeAddr("wallet with no seat");
        bytes32 word = keccak256("first design");
        bytes memory owners = _knownOwners();
        vm.prank(wallet);
        designs.setDesign(word);
        assertEq(renderer.panelOf(wallet), _page(source, owners, wallet, word, block.chainid));

        word = bytes32(uint256(1));
        vm.prank(wallet);
        designs.setDesign(word);
        seats.reply(1999, abi.encode(wallet), false);
        _putOwner(owners, 1999, wallet);
        assertEq(renderer.panelOf(wallet), _page(source, owners, wallet, word, block.chainid));

        vm.prank(wallet);
        designs.clearDesign();
        seats.reply(0, "", true);
        _putOwner(owners, 0, address(0));
        assertEq(renderer.panelOf(wallet), _page(source, owners, wallet, bytes32(0), block.chainid));
    }

    function test_requesterAndTransactionContextCannotChangeThePage() public {
        address wallet = makeAddr("subject");
        bytes32 word = keccak256("opaque design");
        vm.prank(wallet);
        designs.setDesign(word);
        string memory expected = _page(source, _knownOwners(), wallet, word, block.chainid);
        address requester = makeAddr("unrelated requester");
        vm.prank(requester, requester);
        assertEq(renderer.panelOf(wallet), expected);
        vm.warp(type(uint64).max);
        vm.roll(type(uint64).max);
        vm.coinbase(requester);
        vm.prevrandao(keccak256("another block"));
        vm.fee(123);
        vm.txGasPrice(456);
        vm.prank(wallet, wallet);
        assertEq(renderer.panelOf(wallet), expected);
    }

    function test_designDependencyFailureCannotSilentlyProduceADefaultDesign() public {
        // This contract advertises the normal getter but always reverts with
        // a recognizable reason. A zero-design fallback would hide the failure.
        vm.etch(address(designs), hex"63c0ffee006000526004601cfd");
        vm.expectRevert(bytes(hex"c0ffee00"));
        renderer.panelOf(address(this));
        assertEq(renderer.script(), source, "script should not consult designs");
        assertEq(renderer.owners(), _knownOwners(), "owners should not consult designs");
    }

    function test_missingOrShortDesignRepliesRevertInsteadOfInventingAWord() public {
        vm.etch(address(designs), "");
        vm.expectRevert();
        renderer.panelOf(address(this));
        // Return 31 bytes from otherwise clean memory.
        vm.etch(address(designs), hex"601f6000f3");
        vm.expectRevert();
        renderer.panelOf(address(this));
    }

    function test_badScriptFailsBeforeCallingBrokenDesigns() public {
        vm.etch(address(designs), hex"63c0ffee006000526004601cfd");
        vm.etch(pieces[0], hex"00");
        vm.expectRevert(abi.encodeWithSelector(PanelRenderer.EmptyChunk.selector, 0));
        renderer.panelOf(address(this));
    }

    function test_everyRendererEntrypointRejectsEther() public {
        bytes[] memory calls = new bytes[](10);
        calls[0] = abi.encodeCall(PanelRenderer.panelOf, (address(this)));
        calls[1] = abi.encodeCall(PanelRenderer.script, ());
        calls[2] = abi.encodeCall(PanelRenderer.owners, ());
        calls[3] = abi.encodeCall(PanelRenderer.chunks, ());
        calls[4] = abi.encodeCall(renderer.seats, ());
        calls[5] = abi.encodeCall(renderer.designs, ());
        calls[6] = abi.encodeCall(renderer.scriptHash, ());
        calls[7] = abi.encodeCall(renderer.SEAT_COUNT, ());
        calls[8] = "";
        calls[9] = hex"ffffffff";
        vm.deal(address(this), calls.length);
        for (uint256 i; i < calls.length; ++i) {
            (bool ok,) = address(renderer).call{value: 1}(calls[i]);
            assertFalse(ok, "renderer accepted ETH");
        }
        assertEq(address(renderer).balance, 0);
        assertEq(address(this).balance, calls.length);
    }

    function test_unknownSelectorsAndMalformedWalletArgumentsRevert() public {
        _reject("");
        _reject(hex"ff");
        _reject(hex"ffffffff");
        _reject(abi.encodePacked(PanelRenderer.panelOf.selector));
        _reject(abi.encodePacked(PanelRenderer.panelOf.selector, bytes31(0)));
        _reject(abi.encodePacked(PanelRenderer.panelOf.selector, uint256(1) << 160));
    }

    function _knownOwners() private pure returns (bytes memory expected) {
        expected = new bytes(40_000);
        _putOwner(expected, 0, address(1));
        _putOwner(expected, 31, address(uint160(0xabcdef)));
        _putOwner(expected, 1999, address(type(uint160).max));
    }

    function _setSource(bytes memory data) private {
        for (uint256 i; i < 3; ++i) {
            vm.etch(pieces[i], abi.encodePacked(bytes1(0), data[i]));
        }
        vm.etch(pieces[3], bytes.concat(hex"00", _slice(data, 3, data.length - 3)));
        renderer = _renderer(keccak256(data));
    }

    function _reject(bytes memory data) private {
        (bool ok,) = address(renderer).call(data);
        assertFalse(ok, "malformed renderer call accepted");
    }
}
