// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.13;

import {IPartialERC20} from "src/interfaces/IPartialERC20.sol";

interface IERC721WrapperBase is IPartialERC20 {
    function wrap(uint256 tokenId, address to) external;
    function unwrap(address from, uint256 tokenId, address to) external;
    function unwrap(address from, uint256 tokenId, uint256 amount, address to) external;
    function enableTokenIdAsCollateral(uint256 tokenId) external returns (bool enabled);
    function disableTokenIdAsCollateral(uint256 tokenId) external returns (bool disabled);
    function getEnabledTokenIds(address owner) external view returns (uint256[] memory);
    function totalTokenIdsEnabledBy(address owner) external view returns (uint256);
    function tokenIdOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function getQuote(uint256 inAmount, address base) external view returns (uint256 outAmount);
    function skim(address to) external;
    function enableCurrentSkimCandidateAsCollateral() external;
}
