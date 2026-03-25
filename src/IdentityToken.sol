// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC721 } from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import { IERC165 } from "@openzeppelin/contracts/utils/introspection/IERC165.sol";
import { DataTypes } from "./libraries/DataTypes.sol";
import { Errors } from "./libraries/Errors.sol";
import { Events } from "./libraries/Events.sol";
import { IIdentityToken } from "./interfaces/IIdentityToken.sol";

contract IdentityToken is ERC721, IIdentityToken {
    error NonTransferable();

    uint256 private constant BACKUP_TIMELOCK = 7 days;

    uint256 private _nextTokenId = 1;

    bool private _recovering;

    // wallet => tokenId (enforce one identity per wallet)
    mapping(address => uint256) public ownerToTokenId;

    // tokenId => IdentityState
    mapping(uint256 => DataTypes.IdentityState) public identityStates;

    // tokenId => attribute keyHash => attribute value
    mapping(uint256 => mapping(bytes32 => bytes)) public attributes;

    // tokenId => array of Endorsements
    mapping(uint256 => DataTypes.Endorsement[]) public endorsements;

    modifier onlyTokenOwner(uint256 tokenId) {
        if (ownerOf(tokenId) != msg.sender) revert Errors.NotTokenOwner();
        _;
    }

    modifier notCompromised(uint256 tokenId) {
        if (identityStates[tokenId].isCompromised) revert Errors.IdentityCompromised();
        _;
    }

    modifier onlyBackupWallet(uint256 tokenId) {
        if (identityStates[tokenId].backupWallet != msg.sender) revert Errors.NotBackupWallet();
        _;
    }

    constructor() ERC721("IdentityToken", "IDT") {}

    function supportsInterface(bytes4 interfaceId) public view override(ERC721, IERC165) returns (bool) {
        return super.supportsInterface(interfaceId);
    }

    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        address from = _ownerOf(tokenId);

        // prevent transfers (only mint, burn, or explicit recovery allowed)
        if (!_recovering && from != address(0) && to != address(0)) revert NonTransferable();

        address prevOwner = super._update(to, tokenId, auth);

        // maintain ownerToTokenId mapping
        if (from != address(0)) {
            delete ownerToTokenId[from];
        }

        if (to != address(0)) {
            ownerToTokenId[to] = tokenId;
        }

        return prevOwner;
    }

    /**
     * @dev Mints a new self-issued identity token to the caller.
     */
    function mint() external returns (uint256) {
        if (balanceOf(msg.sender) != 0) revert Errors.AlreadyHasIdentity();

        uint256 tokenId = _nextTokenId++;

        _mint(msg.sender, tokenId);

        ownerToTokenId[msg.sender] = tokenId;

        return tokenId;
    }

    /**
     * @dev Sets a metadata attribute (e.g., name, social link) for an identity.
     */
    function setAttribute(
        uint256 tokenId,
        string calldata key,
        bytes calldata value
    ) external onlyTokenOwner(tokenId) notCompromised(tokenId) {
        _setAttribute(tokenId, key, value);
    }

    /**
     * @dev Returns the raw bytes value for a given string key on a token.
     *      Convenience wrapper: callers supply the human-readable key string
     *      instead of computing keccak256 manually.
     */
    function getAttribute(uint256 tokenId, string calldata key) external view returns (bytes memory) {
        return attributes[tokenId][keccak256(abi.encodePacked(key))];
    }

    /**
     * @dev Sets multiple attributes in a single transaction.
     *      keys and values must have equal length.
     *      Emits AttributeSet for every entry.
     */
    function setAttributesBatch(
        uint256 tokenId,
        string[] calldata keys,
        bytes[] calldata values
    ) external onlyTokenOwner(tokenId) notCompromised(tokenId) {
        if (keys.length != values.length) revert Errors.ArrayLengthMismatch();

        for (uint256 i = 0; i < keys.length; i++) {
            _setAttribute(tokenId, keys[i], values[i]);
        }
    }

    /**
     * @dev Convenience setter for the "name" attribute.
     */
    function setName(uint256 tokenId, string calldata name) external onlyTokenOwner(tokenId) notCompromised(tokenId) {
        _setAttribute(tokenId, "name", bytes(name));
    }

    /**
     * @dev Convenience setter for the "github" attribute.
     */
    function setGithub(
        uint256 tokenId,
        string calldata github
    ) external onlyTokenOwner(tokenId) notCompromised(tokenId) {
        _setAttribute(tokenId, "github", bytes(github));
    }

    /**
     * @notice Deletes an attribute for a given identity token.
     * @dev Hashes the provided key using keccak256 and removes the stored value.
     *      Emits {AttributeDeleted}. If the key does not exist, this is a no-op.
     */

    function deleteAttribute(
        uint256 tokenId,
        string calldata key
    ) external onlyTokenOwner(tokenId) notCompromised(tokenId) {
        bytes32 keyHash = keccak256(abi.encodePacked(key));

        delete attributes[tokenId][keyHash];

        emit Events.AttributeDeleted(tokenId, keyHash);
    }

    /**
     * @dev Allows an identity to endorse another identity.
     */
    function endorse(
        uint256 fromTokenId,
        uint256 toTokenId,
        bytes32 connectionType,
        uint256 validUntil
    ) external onlyTokenOwner(fromTokenId) notCompromised(fromTokenId) {
        if (fromTokenId == toTokenId) revert Errors.SelfEndorsement();
        if (_ownerOf(toTokenId) == address(0)) revert Errors.TargetInvalid();

        DataTypes.Endorsement[] storage list = endorsements[toTokenId];

        // prevent duplicate active endorsements
        for (uint256 i = 0; i < list.length; i++) {
            DataTypes.Endorsement storage e = list[i];

            bool active = e.revokedAt == 0 && (e.validUntil == 0 || e.validUntil >= block.timestamp);

            if (active && e.endorserTokenId == fromTokenId && e.connectionType == connectionType) {
                revert Errors.DuplicateEndorsement();
            }
        }

        DataTypes.Endorsement memory newEndorsement = DataTypes.Endorsement({
            endorserTokenId: fromTokenId,
            connectionType: connectionType,
            timestamp: block.timestamp,
            validUntil: validUntil,
            revokedAt: 0
        });

        endorsements[toTokenId].push(newEndorsement);

        emit Events.EndorsementGiven(fromTokenId, toTokenId, connectionType, validUntil);
    }

    // -------------------------------------------------------------------------
    // Backup Wallet Management
    // -------------------------------------------------------------------------

    /**
     * @dev Initiates a timelocked backup wallet change. The pending address is
     *      stored; the caller must call finalizeBackupUpdate after BACKUP_TIMELOCK
     *      has elapsed to commit the change.
     */
    function initiateBackupUpdate(
        uint256 tokenId,
        address newBackup
    ) external onlyTokenOwner(tokenId) notCompromised(tokenId) {
        DataTypes.IdentityState storage state = identityStates[tokenId];
        state.pendingBackupWallet = newBackup;
        state.backupUnlockTime = block.timestamp + BACKUP_TIMELOCK;
        emit Events.BackupUpdateInitiated(tokenId, newBackup, state.backupUnlockTime);
    }

    /**
     * @dev Finalizes a pending backup wallet change after the timelock has passed.
     */
    function finalizeBackupUpdate(uint256 tokenId) external onlyTokenOwner(tokenId) notCompromised(tokenId) {
        DataTypes.IdentityState storage state = identityStates[tokenId];
        if (state.pendingBackupWallet == address(0)) revert Errors.NoPendingUpdate();
        if (block.timestamp < state.backupUnlockTime) revert Errors.TimelockActive();

        address newBackup = state.pendingBackupWallet;
        state.backupWallet = newBackup;
        state.pendingBackupWallet = address(0);
        state.backupUnlockTime = 0;

        emit Events.BackupUpdated(tokenId, newBackup);
    }

    // -------------------------------------------------------------------------
    // Compromise & Recovery
    // -------------------------------------------------------------------------

    /**
     * @dev Marks a token as compromised, freezing all attribute and endorsement
     *      operations. Callable by the token owner or its registered backup wallet.
     */
    function flagCompromised(uint256 tokenId) external {
        DataTypes.IdentityState storage state = identityStates[tokenId];
        if (ownerOf(tokenId) != msg.sender && state.backupWallet != msg.sender) {
            revert Errors.NotTokenOwner();
        }
        state.isCompromised = true;
        emit Events.IdentityCompromised(tokenId);
    }

    /**
     * @dev Recovers a compromised (or otherwise inaccessible) identity by
     *      transferring it to a new owner. Only the registered backup wallet
     *      may call this. Clears the isCompromised flag post-transfer.
     */
    function recoverIdentity(uint256 tokenId, address newOwner) external onlyBackupWallet(tokenId) {
        if (balanceOf(newOwner) != 0) revert Errors.AlreadyHasIdentity();

        address currentOwner = ownerOf(tokenId);

        _recovering = true;
        _transfer(currentOwner, newOwner, tokenId);
        _recovering = false;

        identityStates[tokenId].isCompromised = false;

        emit Events.IdentityRecovered(tokenId, newOwner);
    }

    // -------------------------------------------------------------------------
    // Endorsement Revocation
    // -------------------------------------------------------------------------

    /**
     * @dev Allows the original endorser to revoke a previously given endorsement.
     * @param targetTokenId The token that received the endorsement.
     * @param index         The position of the endorsement in endorsements[targetTokenId].
     */
    function revokeEndorsement(uint256 targetTokenId, uint256 index) external {
        DataTypes.Endorsement[] storage list = endorsements[targetTokenId];

        if (index >= list.length) revert Errors.IndexOutOfBounds();

        DataTypes.Endorsement storage e = list[index];

        uint256 callerTokenId = ownerToTokenId[msg.sender];
        if (callerTokenId == 0 || e.endorserTokenId != callerTokenId) revert Errors.NotEndorser();

        if (e.revokedAt != 0) revert Errors.AlreadyRevoked();

        e.revokedAt = block.timestamp;

        emit Events.EndorsementRevoked(e.endorserTokenId, targetTokenId, index);
    }

    // -------------------------------------------------------------------------
    // Internal
    // -------------------------------------------------------------------------

    /**
     * @dev Core write path shared by setAttribute, setAttributesBatch, and
     *      the typed helper setters. Hashes the key, stores the value, and
     *      emits AttributeSet with the original key string for off-chain indexing.
     */
    function _setAttribute(uint256 tokenId, string memory key, bytes memory value) internal {
        bytes32 keyHash = keccak256(abi.encodePacked(key));

        attributes[tokenId][keyHash] = value;

        emit Events.AttributeSet(tokenId, keyHash, key, value);
    }

    // Identity helpers

    /// @notice Returns true if the address owns any identity token.
    function hasIdentity(address owner) external view returns (bool) {
        return balanceOf(owner) > 0;
    }

    /// @notice Returns full metadata for a given token.
    function getIdentity(uint256 tokenId) external view returns (DataTypes.Identity memory) {
        address owner = _requireOwned(tokenId);
        DataTypes.IdentityState storage state = identityStates[tokenId];
        return
            DataTypes.Identity({
                tokenId: tokenId,
                owner: owner,
                isCompromised: state.isCompromised,
                backupWallet: state.backupWallet,
                pendingBackupWallet: state.pendingBackupWallet,
                backupUnlockTime: state.backupUnlockTime,
                validUntil: state.validUntil,
                endorsementCount: endorsements[tokenId].length
            });
    }

    /// @notice Returns all token IDs owned by an address (0 or 1 given soulbound constraint).
    function getIdentityByOwner(address owner) external view returns (uint256[] memory) {
        uint256 tokenId = ownerToTokenId[owner];
        if (tokenId == 0) {
            return new uint256[](0);
        }
        uint256[] memory result = new uint256[](1);
        result[0] = tokenId;
        return result;
    }

    /// @notice Returns true if the token has at least one active (non-revoked, non-expired) endorsement.
    function isVerified(uint256 tokenId) external view returns (bool) {
        DataTypes.Endorsement[] storage list = endorsements[tokenId];
        for (uint256 i = 0; i < list.length; i++) {
            DataTypes.Endorsement storage e = list[i];
            bool active = e.revokedAt == 0 && (e.validUntil == 0 || e.validUntil >= block.timestamp);
            if (active) return true;
        }
        return false;
    }

    /// @notice Returns true if the token's validUntil is set and has passed.
    function isExpired(uint256 tokenId) external view returns (bool) {
        uint256 validUntil = identityStates[tokenId].validUntil;
        return validUntil != 0 && block.timestamp > validUntil;
    }
}
