// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IdentityToken } from "../src/IdentityToken.sol";
import { DataTypes } from "../src/libraries/DataTypes.sol";
import { Errors } from "../src/libraries/Errors.sol";
import { Events } from "../src/libraries/Events.sol";

contract IdentityTokenTest is Test {
    IdentityToken public identityToken;
    address public alice = address(0x1);
    address public bob = address(0x2);

    function setUp() public {
        identityToken = new IdentityToken();
    }

    function test_Mint() public {
        vm.prank(alice);
        uint256 tokenId = identityToken.mint();

        assertEq(tokenId, 1);
        assertEq(identityToken.ownerOf(1), alice);
        assertEq(identityToken.balanceOf(alice), 1);
    }

    function test_SetAttribute() public {
        // Alice mints a token
        vm.prank(alice);
        uint256 tokenId = identityToken.mint();

        // Alice sets her name
        vm.prank(alice);
        identityToken.setAttribute(tokenId, "name", bytes("Alice Nakamoto"));

        bytes32 keyHash = keccak256(abi.encodePacked("name"));
        bytes memory retrievedValue = identityToken.attributes(tokenId, keyHash);

        assertEq(string(retrievedValue), "Alice Nakamoto");
    }

    function test_Endorse() public {
        // Mint tokens for Alice and Bob
        vm.prank(alice);
        uint256 aliceId = identityToken.mint();

        vm.prank(bob);
        uint256 bobId = identityToken.mint();

        // Alice endorses Bob as a "Colleague"
        bytes32 connectionType = keccak256(abi.encodePacked("Colleague"));
        uint256 validUntil = block.timestamp + 365 days;

        vm.prank(alice);
        identityToken.endorse(aliceId, bobId, connectionType, validUntil);

        // Fetch the endorsement from Bob's token
        (
            uint256 endorserTokenId,
            bytes32 storedConnectionType,
            ,
            uint256 storedValidUntil,
            uint256 revokedAt
        ) = identityToken.endorsements(bobId, 0);

        assertEq(endorserTokenId, aliceId);
        assertEq(storedConnectionType, connectionType);
        assertEq(storedValidUntil, validUntil);
        assertEq(revokedAt, 0);
    }

    function test_RevertIf_NotOwnerSetsAttribute() public {
        vm.prank(alice);
        uint256 tokenId = identityToken.mint();

        vm.prank(bob);
        vm.expectRevert(Errors.NotTokenOwner.selector);
        identityToken.setAttribute(tokenId, "name", bytes("Hacker Bob"));
    }

    // --- deleteAttribute ---

    function test_DeleteAttribute() public {
        vm.prank(alice);
        uint256 tokenId = identityToken.mint();

        vm.prank(alice);
        identityToken.setAttribute(tokenId, "email", bytes("alice@example.com"));

        vm.prank(alice);
        identityToken.deleteAttribute(tokenId, "email");

        bytes32 keyHash = keccak256(abi.encodePacked("email"));
        bytes memory value = identityToken.attributes(tokenId, keyHash);

        assertEq(value.length, 0);
    }

    function test_DeleteAttribute_EmitsEvent() public {
        vm.prank(alice);
        uint256 tokenId = identityToken.mint();

        vm.prank(alice);
        identityToken.setAttribute(tokenId, "email", bytes("alice@example.com"));

        bytes32 keyHash = keccak256(abi.encodePacked("email"));

        vm.prank(alice);
        vm.expectEmit(true, true, false, false);
        emit Events.AttributeDeleted(tokenId, keyHash);
        identityToken.deleteAttribute(tokenId, "email");
    }

    function test_RevertIf_NotOwnerDeletesAttribute() public {
        vm.prank(alice);
        uint256 tokenId = identityToken.mint();

        vm.prank(alice);
        identityToken.setAttribute(tokenId, "email", bytes("alice@example.com"));

        vm.prank(bob);
        vm.expectRevert(Errors.NotTokenOwner.selector);
        identityToken.deleteAttribute(tokenId, "email");
    }

    function test_DeleteAttribute_NeverSet_DoesNotRevert() public {
        vm.prank(alice);
        uint256 tokenId = identityToken.mint();

        vm.prank(alice);
        identityToken.deleteAttribute(tokenId, "nonexistent");

        bytes32 keyHash = keccak256(abi.encodePacked("nonexistent"));
        bytes memory value = identityToken.attributes(tokenId, keyHash);

        assertEq(value.length, 0);
    }

    function test_DeleteAttribute_Twice_DoesNotRevert() public {
        vm.prank(alice);
        uint256 tokenId = identityToken.mint();

        vm.prank(alice);
        identityToken.setAttribute(tokenId, "email", bytes("alice@example.com"));

        vm.prank(alice);
        identityToken.deleteAttribute(tokenId, "email");

        vm.prank(alice);
        identityToken.deleteAttribute(tokenId, "email");
    }

    function test_DeleteAttribute_ThenReSet() public {
        vm.prank(alice);
        uint256 tokenId = identityToken.mint();

        vm.prank(alice);
        identityToken.setAttribute(tokenId, "email", bytes("alice@example.com"));

        vm.prank(alice);
        identityToken.deleteAttribute(tokenId, "email");

        vm.prank(alice);
        identityToken.setAttribute(tokenId, "email", bytes("new@example.com"));

        bytes32 keyHash = keccak256(abi.encodePacked("email"));
        bytes memory value = identityToken.attributes(tokenId, keyHash);

        assertEq(string(value), "new@example.com");
    }
}
