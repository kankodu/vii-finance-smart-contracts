// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {IERC6909, ERC6909} from "lib/openzeppelin-contracts/contracts/token/ERC6909/draft-ERC6909.sol";
import {ERC6909TokenSupply} from
    "lib/openzeppelin-contracts/contracts/token/ERC6909/extensions/draft-ERC6909TokenSupply.sol";
import {EnumerableSet} from "lib/openzeppelin-contracts/contracts/utils/structs/EnumerableSet.sol";
import {Context} from "lib/openzeppelin-contracts/contracts/utils/Context.sol";
import {IERC721} from "lib/openzeppelin-contracts/contracts/token/ERC721/IERC721.sol";
import {EVCUtil} from "lib/ethereum-vault-connector/src/utils/EVCUtil.sol";
import {IEVC} from "lib/ethereum-vault-connector/src/interfaces/IEthereumVaultConnector.sol";
import {IPriceOracle} from "src/interfaces/IPriceOracle.sol";

interface IPartialERC20 {
    function balanceOf(address owner) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IERC721WrapperBase is IPartialERC20 {
    function wrap(uint256 tokenId, address to) external;
    function unwrap(uint256 tokenId, address to) external;
}

abstract contract ERC721WrapperBase is ERC6909TokenSupply, EVCUtil, IPartialERC20 {
    uint256 public constant FULL_AMOUNT = 1000 ether;
    uint256 public constant MAX_TOKENIDS_ALLOWED = 2;

    IERC721 public immutable underlying;
    IPriceOracle public immutable oracle;
    address public immutable unitOfAccount;

    using EnumerableSet for EnumerableSet.UintSet;

    mapping(address owner => EnumerableSet.UintSet) private _enabledTokenIds;

    error MaximumAllowedTokenIdsReached();
    error TokenIdNotOwnedByThisContract();
    error TokenIdIsAlreadyWrapped();

    event TokenIdEnabled(address indexed owner, uint256 indexed tokenId, bool enabled);

    constructor(address _evc, address _underlying, address _oracle, address _unitOfAccount) ERC6909() EVCUtil(_evc) {
        evc = IEVC(_evc);
        underlying = IERC721(_underlying);
        oracle = IPriceOracle(_oracle);
        unitOfAccount = _unitOfAccount;
    }

    ///@dev returns true if it wasn't already enabled, it was already enabled, it will return false
    function enableTokenIdAsCollateral(uint256 tokenId) public callThroughEVC returns (bool) {
        address sender = _msgSender();
        if (totalTokenIdsEnabledBy(sender) >= MAX_TOKENIDS_ALLOWED) revert MaximumAllowedTokenIdsReached();
        emit TokenIdEnabled(sender, tokenId, true);
        return _enabledTokenIds[_msgSender()].add(tokenId);
    }

    ///@dev returns true if it was enabled. if it was never enabled, it will return false
    function disableTokenIdAsCollateral(uint256 tokenId) external callThroughEVC returns (bool) {
        emit TokenIdEnabled(_msgSender(), tokenId, false);
        return _enabledTokenIds[_msgSender()].remove(tokenId);
    }

    function totalTokenIdsEnabledBy(address owner) public view returns (uint256) {
        return _enabledTokenIds[owner].length();
    }

    function tokenIdOfOwnerByIndex(address owner, uint256 index) public view returns (uint256) {
        return _enabledTokenIds[owner].at(index);
    }

    function _validatePosition(uint256 tokenId) internal view virtual;

    function wrap(uint256 tokenId, address to) public callThroughEVC {
        underlying.transferFrom(_msgSender(), address(this), tokenId);
        _wrap(tokenId, to);
    }

    /// @dev assumes that the tokenId is already owned by this address
    function _wrap(uint256 tokenId, address to) internal {
        _validatePosition(tokenId);
        _mint(to, tokenId, FULL_AMOUNT);
    }

    function _burnFrom(address from, uint256 tokenId, uint256 amount) internal virtual {
        address sender = _msgSender();
        if (from != sender && !isOperator(from, sender)) {
            _spendAllowance(from, sender, tokenId, amount);
        }
        _burn(from, tokenId, amount);
    }

    ///@dev to get the entire tokenId, use this function
    function unwrap(address from, uint256 tokenId, address to) public callThroughEVC {
        _burnFrom(from, tokenId, FULL_AMOUNT);
        underlying.transferFrom(address(this), to, tokenId);
    }

    function _unwrap(address to, uint256 tokenId, uint256 amount) internal virtual;

    function unwrap(address from, uint256 tokenId, uint256 amount, address to) public callThroughEVC {
        _burnFrom(from, tokenId, amount);
        _unwrap(to, tokenId, amount);
    }

    function _calculateValueOfTokenId(uint256 tokenId, uint256 amount) internal view virtual returns (uint256);

    /// @notice For regular EVK vaults, it returns the balance of the user in vault share terms, which is then converted into unitOfAccount terms by the price oracle.
    /// @dev For ERC721WrapperBase, this returns the sum value of each tokenId in unitOfAccount terms. When the vault calls the price oracle, it returns the value 1:1 because the price oracle for this collateral-only vault is configured to return 1:1.
    function balanceOf(address owner) public view returns (uint256 totalValue) {
        uint256 totalTokenIds = totalTokenIdsEnabledBy(owner);

        for (uint256 i = 0; i < totalTokenIds; i++) {
            uint256 tokenId = tokenIdOfOwnerByIndex(owner, i);
            totalValue += _calculateValueOfTokenId(tokenId, balanceOf(owner, tokenId));
        }
    }

    /// @notice For regular EVK vaults, it transfers the specified amount of vault shares from the sender to the receiver for regular EVK vaults.
    /// @dev For ERC721WrapperBase, transfers a proportional amount of ERC6909 tokens (calculated as FULL_AMOUNT * amount / balanceOf(sender)) for each enabled tokenId from the sender to the receiver.
    /// @dev no need to check if sender is being liquidated, sender can choose to do this at any time
    function transfer(address to, uint256 amount) public callThroughEVC returns (bool) {
        address sender = _msgSender();
        uint256 currentBalance = balanceOf(sender);

        uint256 totalTokenIds = totalTokenIdsEnabledBy(sender);

        for (uint256 i = 0; i < totalTokenIds; i++) {
            _transfer(sender, to, tokenIdOfOwnerByIndex(sender, i), normalizedToFull(amount, currentBalance)); //this concludes the liquidation. The liquidator can come back to do whatever they want with the ERC6909 tokens
        }
        return true;
    }

    function _update(address from, address to, uint256 id, uint256 amount) internal virtual override {
        super._update(from, to, id, amount);
        if (from != address(0)) evc.requireAccountStatusCheck(from);
    }

    function _msgSender() internal view virtual override(Context, EVCUtil) returns (address) {
        return EVCUtil._msgSender();
    }

    function getQuote(uint256 inAmount, address base) public view returns (uint256 outAmount) {
        if (evc.isControlCollateralInProgress()) {
            // mid-point price
            outAmount = oracle.getQuote(inAmount, base, unitOfAccount);
        } else {
            // ask price for liability
            (, outAmount) = oracle.getQuotes(inAmount, base, unitOfAccount);
        }
    }

    function proportionalShare(uint256 amount, uint256 part) internal pure returns (uint256) {
        return amount * part / FULL_AMOUNT;
    }

    function normalizedToFull(uint256 amount, uint256 currentBalance) internal pure returns (uint256) {
        return FULL_AMOUNT * amount / currentBalance;
    }

    function transfer(address receiver, uint256 id, uint256 amount)
        public
        virtual
        override(IERC6909, ERC6909)
        callThroughEVC
        returns (bool)
    {
        return super.transfer(receiver, id, amount);
    }

    function transferFrom(address sender, address receiver, uint256 id, uint256 amount)
        public
        virtual
        override(IERC6909, ERC6909)
        callThroughEVC
        returns (bool)
    {
        return super.transferFrom(sender, receiver, id, amount);
    }

    function getEnabledTokenIds(address owner) external view returns (uint256[] memory) {
        return _enabledTokenIds[owner].values();
    }
    ///@dev specific to the implementation, it should return the tokenId that needs to be skimmed

    function _getTokenIdToSkim() internal view virtual returns (uint256);

    function skim(address to) external callThroughEVC {
        uint256 tokenId = _getTokenIdToSkim();
        //in case the tokenId is not owned by this contract already, it will revert
        if (underlying.ownerOf(tokenId) != address(this)) {
            revert TokenIdNotOwnedByThisContract();
        }
        //in case someone tries to skim already wrapped tokenId, it will revert
        if (totalSupply(tokenId) > 0) {
            revert TokenIdIsAlreadyWrapped();
        }
        _wrap(tokenId, to);
    }

    function enableSkimmedTokenIdAsCollateral() public callThroughEVC {
        uint256 tokenId = _getTokenIdToSkim();
        enableTokenIdAsCollateral(tokenId);
    }
}
