// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {DataTypes} from "../libraries/types/DataTypes.sol";

interface IVeloVotingEscrow {

    /**
     * @dev get tokenId's velo amount
     */
    function locked(uint256 tokenId) external view returns (DataTypes.LockedBalance memory);
}