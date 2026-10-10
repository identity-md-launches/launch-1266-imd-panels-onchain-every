// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice Each wallet may publish or clear its own opaque panel design.
contract PanelDesigns {
    mapping(address holder => bytes32) public designOf;

    event DesignSet(address indexed holder, bytes32 design);

    function setDesign(bytes32 design) external {
        designOf[msg.sender] = design;
        emit DesignSet(msg.sender, design);
    }

    function clearDesign() external {
        delete designOf[msg.sender];
        emit DesignSet(msg.sender, bytes32(0));
    }

    function designsOf(address[] calldata holders) external view returns (bytes32[] memory words) {
        words = new bytes32[](holders.length);
        for (uint256 i; i < holders.length; ++i) {
            words[i] = designOf[holders[i]];
        }
    }
}
