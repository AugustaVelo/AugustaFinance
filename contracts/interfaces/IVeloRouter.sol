// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

interface IVeloRouter {
    function getAmountOut(uint amountIn, address tokenIn, address tokenOut) external view returns (uint amount, bool stable);
}