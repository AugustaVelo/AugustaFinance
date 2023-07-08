// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {DataTypes} from "./libraries/types/DataTypes.sol";
import {ReserveLogic} from "./libraries/logic/ReserveLogic.sol";
import {NftLogic} from "./libraries/logic/NftLogic.sol";
import {ILendPoolAddressesProvider} from "./interfaces/ILendPoolAddressesProvider.sol";
import {IWETH} from "./interfaces/IWETH.sol";

contract LendPoolStorage {
    using ReserveLogic for DataTypes.ReserveData;
    using NftLogic for DataTypes.NftData;

    ILendPoolAddressesProvider internal _addressesProvider;

    mapping(address => DataTypes.ReserveData) internal _reserves;
    mapping(address => DataTypes.NftData) internal _nfts;

    mapping(uint256 => address) internal _reservesList;
    uint256 internal _reservesCount;

    mapping(uint256 => address) internal _nftsList;
    uint256 internal _nftsCount;

    bool internal _paused;

    uint256 internal _maxNumberOfReserves;
    uint256 internal _maxNumberOfNfts;

    IWETH internal WETH;
    mapping(address => bool) internal _callerWhitelists;

    // !!! Never add new variable at here, because this contract is inherited by LendPool !!!
    // !!! Add new variable at LendPool directly !!!
}
