// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {DataTypes} from "../libraries/types/DataTypes.sol";
import {Errors} from "../libraries/helpers/Errors.sol";
import {ILendPoolLoan} from "../interfaces/ILendPoolLoan.sol";
import {ILendPool} from "../interfaces/ILendPool.sol";
import {ILendPoolAddressesProvider} from "../interfaces/ILendPoolAddressesProvider.sol";
import {IExchangeMarketProvider} from "../interfaces/auguster/IExchangeMarketProvider.sol";

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";

contract ExchangeMarketProvider is IExchangeMarketProvider {


     function getCollateralAmount(ILendPoolAddressesProvider provider, address nftAsset) external override view returns(uint256) {
        ILendPoolLoan poolLoan = ILendPoolLoan(provider.getLendPoolLoan());
        return poolLoan.getNftCollateralAmount(nftAsset);
     }


    
    /**
     * @dev list all valid nfts
     */
    function listValidNfts(ILendPoolAddressesProvider provider, address nftAsset, uint256 from, uint256 size) external view override returns(uint256[] memory) {
        ILendPoolLoan poolLoan = ILendPoolLoan(provider.getLendPoolLoan());
        return new uint256[](1);

    }


    /**
     * @dev list the loan data of nft tokenId's
     */
    function listNftLoansData(
        ILendPoolAddressesProvider provider, 
        address nftAsset, 
        uint256[] memory nftTokenIds
    ) external view override returns (DataTypes.AggregatedLoanData[] memory) {

        require(nftTokenIds.length > 0, Errors.LP_INCONSISTENT_PARAMS);

        ILendPool lendPool = ILendPool(provider.getLendPool());
        ILendPoolLoan poolLoan = ILendPoolLoan(provider.getLendPoolLoan());

        DataTypes.AggregatedLoanData[] memory loansData = new DataTypes.AggregatedLoanData[](nftTokenIds.length);

        for (uint256 i = 0; i < nftTokenIds.length; i++) {
            DataTypes.AggregatedLoanData memory loanData = loansData[i];
            // NFT debt data
            (
                loanData.loanId,
                loanData.reserveAsset,
                loanData.totalCollateralInReserve,
                loanData.totalDebtInReserve,
                loanData.availableBorrowsInReserve,
                loanData.healthFactor
            ) = lendPool.getNftDebtData(nftAsset, nftTokenIds[i]);

            DataTypes.LoanData memory loan = poolLoan.getLoan(loanData.loanId);
            loanData.state = uint256(loan.state);

            (loanData.liquidatePrice, ) = lendPool.getNftLiquidatePrice(nftAsset, nftTokenIds[i]);

            // NFT auction data
            (, loanData.bidderAddress, loanData.bidPrice, loanData.bidBorrowAmount, loanData.bidFine) = lendPool
                .getNftAuctionData(nftAsset, nftTokenIds[i]);
        }

        return loansData;
    }

}