// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title Schema
 * @notice Pre-computed keccak256 key hashes for standard identity attributes.
 *         These match the hashing logic in IdentityToken.setAttribute:
 *         keccak256(abi.encodePacked(key))
 *
 *         Usage:
 *           bytes memory name = identityToken.attributes(tokenId, Schema.NAME);
 */
library Schema {
    bytes32 internal constant NAME = keccak256(abi.encodePacked("name"));
    bytes32 internal constant AGE = keccak256(abi.encodePacked("age"));
    bytes32 internal constant NATIONALITY = keccak256(abi.encodePacked("nationality"));
    bytes32 internal constant RESIDENCE = keccak256(abi.encodePacked("residence"));
    bytes32 internal constant GITHUB = keccak256(abi.encodePacked("github"));
    bytes32 internal constant LINKEDIN = keccak256(abi.encodePacked("linkedin"));
    bytes32 internal constant TWITTER = keccak256(abi.encodePacked("twitter"));
    bytes32 internal constant PHONE = keccak256(abi.encodePacked("phone"));
    bytes32 internal constant EMAIL = keccak256(abi.encodePacked("email"));
}
