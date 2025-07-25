// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

interface IPriceOracle {
    function name() external view returns (string memory);

    function getQuote(uint256 inAmount, address base, address quote) external view returns (uint256 outAmount);

    function getQuotes(uint256 inAmount, address base, address quote)
        external
        view
        returns (uint256 bidOutAmount, uint256 askOutAmount);
}
