// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {ILendPoolAddressesProvider} from "../ILendPoolAddressesProvider.sol";
import {DataTypes} from "../../libraries/types/DataTypes.sol";

interface IExchangeMarketProvider {

    /**
     * @dev get all collateral amount
     */
    function getCollateralAmount(ILendPoolAddressesProvider provider, address nftAsset) external view returns(uint256);


    /**
     * @dev batch list valid nfts
     */
    function listValidNfts(
        ILendPoolAddressesProvider provider, 
        address nftAsset, 
        uint256 from, uint256 size
        ) external view returns(uint256[] memory);


    /**
     * @dev list the loan data of nft tokenId's
     */
    function listNftLoansData(
        ILendPoolAddressesProvider provider, 
        address nftAsset, 
        uint256[] memory nftTokenIds
    ) external view returns (DataTypes.AggregatedLoanData[] memory);
   

}