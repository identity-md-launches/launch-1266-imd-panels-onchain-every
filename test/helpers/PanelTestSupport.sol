// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {PanelDesigns} from "src/PanelDesigns.sol";
import {PanelRenderer, ISeats, IPanelDesigns} from "src/PanelRenderer.sol";

/// Raw responses let tests distinguish failed calls, short ABI data, dirty words,
/// and valid addresses followed by arbitrary trailing bytes.
contract PanelSeatReplies {
    mapping(uint256 => bytes) private responses;
    mapping(uint256 => bool) private failures;

    function reply(uint256 id, bytes memory data, bool fail) external {
        responses[id] = data;
        failures[id] = fail;
    }

    fallback() external {
        require(msg.sig == ISeats.ownerOf.selector && msg.data.length == 36, "unexpected query");
        uint256 id = abi.decode(msg.data[4:], (uint256));
        require(id < 2000, "unexpected seat");
        bytes memory data = responses[id];
        bool fail = failures[id];
        assembly ("memory-safe") {
            if fail { revert(add(data, 32), mload(data)) }
            return(add(data, 32), mload(data))
        }
    }
}

abstract contract PanelTestSupport is Test {
    PanelDesigns internal designs;
    PanelSeatReplies internal seats;
    PanelRenderer internal renderer;
    address[4] internal pieces;
    bytes internal source = hex"00ff807f";

    function setUp() public virtual {
        designs = new PanelDesigns();
        seats = new PanelSeatReplies();
        for (uint256 i; i < 4; ++i) {
            pieces[i] = makeAddr(string.concat("adversarial chunk ", vm.toString(i)));
            vm.etch(pieces[i], abi.encodePacked(bytes1(0), source[i]));
        }
        renderer = _renderer(keccak256(source));
    }

    function _renderer(bytes32 expectedHash) internal returns (PanelRenderer) {
        return new PanelRenderer(
            ISeats(address(seats)),
            IPanelDesigns(address(designs)),
            pieces[0],
            pieces[1],
            pieces[2],
            pieces[3],
            expectedHash
        );
    }

    /// Independent packing oracle: no overlapping stores or assembly.
    function _putOwner(bytes memory packed, uint256 id, address holder) internal pure {
        bytes20 word = bytes20(holder);
        for (uint256 j; j < 20; ++j) {
            packed[id * 20 + j] = word[j];
        }
    }

    function _slice(bytes memory data, uint256 start, uint256 length) internal pure returns (bytes memory out) {
        out = new bytes(length);
        for (uint256 i; i < length; ++i) {
            out[i] = data[start + i];
        }
    }

    /// The README template, using Foundry's independent encoders. Callers supply
    /// the expected owners and design, never values obtained from the renderer.
    function _page(bytes memory code, bytes memory owners, address wallet, bytes32 design, uint256 chainId)
        internal
        pure
        returns (string memory)
    {
        string memory w = vm.toLowercase(vm.toString(wallet));
        return string.concat(
            '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">',
            "<title>IMD panel ",
            w,
            '</title></head><body><script>(async()=>{const z=Uint8Array.from(atob("',
            vm.toBase64(code),
            '"),c=>c.charCodeAt(0));const t=await new Response(new Blob([z]).stream().pipeThrough(new DecompressionStream("gzip"))).text();(0,eval)(t);IMD.panel("',
            vm.toBase64(owners),
            '","',
            w,
            '","',
            vm.toLowercase(vm.toString(design)),
            '",',
            vm.toString(chainId),
            ")})()</script></body></html>"
        );
    }
}
