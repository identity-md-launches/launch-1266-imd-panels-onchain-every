// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface ISeats {
    function ownerOf(uint256 tokenId) external view returns (address);
}

interface IPanelDesigns {
    function designOf(address holder) external view returns (bytes32);
}

/// @notice Renders the published panel art using current seat owners and a wallet's design.
contract PanelRenderer {
    ISeats public immutable seats;
    IPanelDesigns public immutable designs;
    bytes32 public immutable scriptHash;
    uint256 public constant SEAT_COUNT = 2000;

    address private immutable _c0;
    address private immutable _c1;
    address private immutable _c2;
    address private immutable _c3;

    error EmptyChunk(uint256 index);
    error WrongScript(bytes32 got);

    /// @dev Dependencies are checked on reads so deployment also works on an empty chain.
    constructor(
        ISeats seats_,
        IPanelDesigns designs_,
        address c0,
        address c1,
        address c2,
        address c3,
        bytes32 expectedHash
    ) {
        seats = seats_;
        designs = designs_;
        _c0 = c0;
        _c1 = c1;
        _c2 = c2;
        _c3 = c3;
        scriptHash = expectedHash;
    }

    function chunks() public view returns (address[] memory pieces) {
        pieces = new address[](4);
        pieces[0] = _c0;
        pieces[1] = _c1;
        pieces[2] = _c2;
        pieces[3] = _c3;
    }

    function script() public view returns (bytes memory code) {
        address[] memory pieces = chunks();
        uint256[4] memory lengths;
        uint256 total;
        for (uint256 i; i < 4; ++i) {
            uint256 size = pieces[i].code.length;
            if (size < 2) revert EmptyChunk(i);
            lengths[i] = size - 1;
            total += size - 1;
        }

        code = new bytes(total);
        uint256 offset;
        for (uint256 i; i < 4; ++i) {
            address piece = pieces[i];
            uint256 length = lengths[i];
            assembly ("memory-safe") {
                extcodecopy(piece, add(add(code, 32), offset), 1, length)
            }
            offset += length;
        }
        bytes32 got = keccak256(code);
        if (got != scriptHash) revert WrongScript(got);
    }

    function owners() public view returns (bytes memory packed) {
        // Each overlapping word store writes 20 address bytes and 12 zero bytes.
        // Reserve the final store's extra bytes, then expose only the packed addresses.
        packed = new bytes(SEAT_COUNT * 20 + 12);
        address collection = address(seats);
        assembly ("memory-safe") {
            mstore(packed, mul(SEAT_COUNT, 20))
            let dest := add(packed, 32)
            for { let i := 0 } lt(i, SEAT_COUNT) { i := add(i, 1) } {
                mstore(0, shl(224, 0x6352211e)) // ownerOf(uint256)
                mstore(4, i)
                // Copy at most one word even if the dependency returns excess data.
                let ok := staticcall(gas(), collection, 0, 36, 0, 32)
                let holder := mload(0)
                if iszero(and(and(ok, iszero(lt(returndatasize(), 32))), iszero(shr(160, holder)))) {
                    holder := 0
                }
                mstore(dest, shl(96, holder))
                dest := add(dest, 20)
            }
        }
    }

    function panelOf(address wallet) external view returns (string memory) {
        string memory source = _base64(script());
        string memory holders = _base64(owners());
        string memory walletHex = _hex(uint256(uint160(wallet)), 20);
        string memory designHex = _hex(uint256(designs.designOf(wallet)), 32);
        return string.concat(
            '<!doctype html><html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">',
            "<title>IMD panel ",
            walletHex,
            '</title></head><body><script>(async()=>{const z=Uint8Array.from(atob("',
            source,
            '"),c=>c.charCodeAt(0));const t=await new Response(new Blob([z]).stream().pipeThrough(new DecompressionStream("gzip"))).text();(0,eval)(t);IMD.panel("',
            holders,
            '","',
            walletHex,
            '","',
            designHex,
            '",',
            _decimal(block.chainid),
            ")})()</script></body></html>"
        );
    }

    function _hex(uint256 value, uint256 length) private pure returns (string memory) {
        bytes16 digits = "0123456789abcdef";
        bytes memory out = new bytes(2 + length * 2);
        out[0] = "0";
        out[1] = "x";
        for (uint256 i = out.length; i > 2;) {
            out[--i] = digits[value & 15];
            value >>= 4;
        }
        return string(out);
    }

    function _decimal(uint256 value) private pure returns (string memory) {
        uint256 length = 1;
        for (uint256 rest = value; rest >= 10; rest /= 10) {
            ++length;
        }
        bytes memory out = new bytes(length);
        do {
            out[--length] = bytes1(uint8(48 + value % 10));
            value /= 10;
        } while (length != 0);
        return string(out);
    }

    function _base64(bytes memory data) private pure returns (string memory) {
        bytes memory table = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        bytes memory out = new bytes(4 * ((data.length + 2) / 3));
        assembly ("memory-safe") {
            let alphabet := add(table, 1)
            let remainder := mod(mload(data), 3)
            let end := add(data, sub(mload(data), remainder))
            let cursor := data
            let dest := add(out, 32)
            for {} lt(cursor, end) {} {
                cursor := add(cursor, 3)
                let value := mload(cursor)
                mstore8(dest, mload(add(alphabet, and(shr(18, value), 63))))
                mstore8(add(dest, 1), mload(add(alphabet, and(shr(12, value), 63))))
                mstore8(add(dest, 2), mload(add(alphabet, and(shr(6, value), 63))))
                mstore8(add(dest, 3), mload(add(alphabet, and(value, 63))))
                dest := add(dest, 4)
            }
            if remainder {
                // Read only through the final real byte, then zero-fill the partial
                // group. Bytes in the next allocation can never enter the encoding.
                let tail := shl(mul(sub(3, remainder), 8), mload(add(cursor, remainder)))
                mstore8(dest, mload(add(alphabet, and(shr(18, tail), 63))))
                mstore8(add(dest, 1), mload(add(alphabet, and(shr(12, tail), 63))))
                mstore8(add(dest, 2), mload(add(alphabet, and(shr(6, tail), 63))))
                mstore8(add(dest, 3), 0x3d)
                if eq(remainder, 1) { mstore8(add(dest, 2), 0x3d) }
            }
        }
        return string(out);
    }
}
