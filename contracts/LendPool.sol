// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {IAToken} from "./interfaces/IAToken.sol";
import {IDebtToken} from "./interfaces/IDebtToken.sol";
import {ILendPoolLoan} from "./interfaces/ILendPoolLoan.sol";
import {ILendPool} from "./interfaces/ILendPool.sol";
import {IWETH} from "./interfaces/IWETH.sol";
// import {IReserveOracleGetter} from "../interfaces/IReserveOracleGetter.sol";
// import {INFTOracleGetter} from "../interfaces/INFTOracleGetter.sol";
import {ILendPoolAddressesProvider} from "./interfaces/ILendPoolAddressesProvider.sol";
import {Errors} from "./libraries/helpers/Errors.sol";
import {WadRayMath} from "./libraries/math/WadRayMath.sol";
import {PercentageMath} from "./libraries/math/PercentageMath.sol";
import {GenericLogic} from "./libraries/logic/GenericLogic.sol";
import {ReserveLogic} from "./libraries/logic/ReserveLogic.sol";
import {NftLogic} from "./libraries/logic/NftLogic.sol";
import {ValidationLogic} from "./libraries/logic/ValidationLogic.sol";
import {ReserveConfiguration} from "./libraries/configuration/ReserveConfiguration.sol";
import {NftConfiguration} from "./libraries/configuration/NftConfiguration.sol";
import {DataTypes} from "./libraries/types/DataTypes.sol";
import {LendPoolStorage} from "./LendPoolStorage.sol";
// import {LendPoolStorageExt} from "./LendPoolStorageExt.sol";

import {AddressUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/AddressUpgradeable.sol";
import {IERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import {SafeERC20Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import {IERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721Upgradeable.sol";
import {IERC721ReceiverUpgradeable} from
    "@openzeppelin/contracts-upgradeable/token/ERC721/IERC721ReceiverUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

/**
 * @title LendPool contract
 * @dev Folk from bend-lending-protocol
 * - Users can:
 *   # Deposit
 *   # Withdraw
 *   # Borrow
 *   # Repay
 *   # Auction
 *   # Liquidate
 * - To be covered by a proxy contract, owned by the LendPoolAddressesProvider of the specific market
 * - All admin functions are callable by the LendPoolConfigurator contract defined also in the
 *   LendPoolAddressesProvider
 * @author Bend
 *
 */
// !!! For Upgradable: DO NOT ADJUST Inheritance Order !!!
contract LendPool is Initializable, ILendPool, LendPoolStorage, IERC721ReceiverUpgradeable {
    using WadRayMath for uint256;
    using PercentageMath for uint256;
    using SafeERC20Upgradeable for IERC20Upgradeable;
    using ReserveLogic for DataTypes.ReserveData;
    using NftLogic for DataTypes.NftData;
    using ReserveConfiguration for DataTypes.ReserveConfigurationMap;
    using NftConfiguration for DataTypes.NftConfigurationMap;

    /*//////////////////////////////////////////////////////////////
                                MODIFIERS
    //////////////////////////////////////////////////////////////*/
    uint8 internal constant _not_entered = 1;
    uint8 internal constant _entered = 2;
    uint8 internal _entered_state;

    modifier nonReentrant() {
        require(_entered_state == _not_entered);
        _entered_state = _entered;
        _;
        _entered_state = _not_entered;
    }

    modifier whenNotPaused() {
        _whenNotPaused();
        _;
    }

    modifier onlyLendPoolConfigurator() {
        _onlyLendPoolConfigurator();
        _;
    }

    function _whenNotPaused() internal view {
        require(!_paused, Errors.LP_IS_PAUSED);
    }

    function _onlyLendPoolConfigurator() internal view {
        require(_addressesProvider.getLendPoolConfigurator() == msg.sender, Errors.LP_CALLER_NOT_LEND_POOL_CONFIGURATOR);
    }

    /**
     * @dev Function is invoked by the proxy contract when the LendPool contract is added to the
     * LendPoolAddressesProvider of the market.
     * - Caching the address of the LendPoolAddressesProvider in order to reduce gas consumption
     *   on subsequent operations
     * @param provider The address of the LendPoolAddressesProvider
     *
     */
    function initialize(ILendPoolAddressesProvider provider, address weth) public initializer {
        _maxNumberOfReserves = 32;
        _maxNumberOfNfts = 256;

        _addressesProvider = provider;
        WETH = IWETH(weth);
        WETH.approve(address(provider.getLendPool()), type(uint256).max);
    }

    /**
     * @dev Deposits an `amount` of underlying asset into the reserve, receiving in return overlying aTokens.
     * - E.g. User deposits 100 USDC and gets in return 100 bUSDC
     * @param asset The address of the underlying asset to deposit
     * @param amount The amount to be deposited
     * @param onBehalfOf The address that will receive the aTokens, same as msg.sender if the user
     *   wants to receive them on his own wallet, or a different address if the beneficiary of aTokens
     *   is a different wallet
     * @param referralCode Code used to register the integrator originating the operation, for potential rewards.
     *   0 if the action is executed directly by the user, without any middle-man
     *
     */
    function deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode)
        external
        override
        nonReentrant
        whenNotPaused
    {
        _deposit(asset, amount, onBehalfOf, referralCode);
    }

    function depositETH(address onBehalfOf, uint16 referralCode) external payable override nonReentrant {
        _checkValidCallerAndOnBehalfOf(onBehalfOf);

        WETH.deposit{value: msg.value}();
        _deposit(address(WETH), msg.value, onBehalfOf, referralCode);
    }

    function _deposit(address asset, uint256 amount, address onBehalfOf, uint16 referralCode) internal {
        require(onBehalfOf != address(0), Errors.VL_INVALID_ONBEHALFOF_ADDRESS);

        DataTypes.ReserveData storage reserve = _reserves[asset];
        address aToken = reserve.aTokenAddress;
        require(aToken != address(0), Errors.VL_INVALID_RESERVE_ADDRESS);

        ValidationLogic.validateDeposit(reserve, amount);

        reserve.updateState();
        reserve.updateInterestRates(asset, aToken, amount, 0);

        IERC20Upgradeable(asset).safeTransferFrom(msg.sender, aToken, amount);

        IAToken(aToken).mint(onBehalfOf, amount, reserve.liquidityIndex);

        emit Deposit(msg.sender, asset, amount, onBehalfOf, referralCode);
    }

    function _checkValidCallerAndOnBehalfOf(address onBehalfOf) internal view {
        require(
            (onBehalfOf == msg.sender) || (_callerWhitelists[msg.sender] == true),
            Errors.CALLER_NOT_ONBEHALFOF_OR_IN_WHITELIST
        );
    }

    /**
     * @dev Withdraws an `amount` of underlying asset from the reserve, burning the equivalent aTokens owned
     * E.g. User has 100 bUSDC, calls withdraw() and receives 100 USDC, burning the 100 bUSDC
     * @param asset The address of the underlying asset to withdraw
     * @param amount The underlying amount to be withdrawn
     *   - Send the value type(uint256).max in order to withdraw the whole aToken balance
     * @param to Address that will receive the underlying, same as msg.sender if the user
     *   wants to receive it on his own wallet, or a different address if the beneficiary is a
     *   different wallet
     * @return The final amount withdrawn
     *
     */
    function withdraw(address asset, uint256 amount, address to)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        return _withdraw(asset, amount, to);
    }

    function withdrawETH(uint256 amount, address to) external override nonReentrant {
        _checkValidCallerAndOnBehalfOf(to);

        DataTypes.ReserveData memory reserveData = _reserves[address(WETH)];

        IAToken bWETH = IAToken(reserveData.aTokenAddress); //当前只有WETH--0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2

        uint256 userBalance = bWETH.balanceOf(msg.sender);
        uint256 amountToWithdraw = amount;

        // if amount is equal to uint(-1), the user wants to redeem everything
        if (amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }

        bWETH.transferFrom(msg.sender, address(this), amountToWithdraw);
        _withdraw(address(WETH), amountToWithdraw, address(this));

        WETH.withdraw(amountToWithdraw);
        _safeTransferETH(to, amountToWithdraw);
    }

    function _withdraw(address asset, uint256 amount, address to) internal returns (uint256) {
        require(to != address(0), Errors.VL_INVALID_TARGET_ADDRESS);

        DataTypes.ReserveData storage reserve = _reserves[asset];
        address aToken = reserve.aTokenAddress;
        require(aToken != address(0), Errors.VL_INVALID_RESERVE_ADDRESS);

        uint256 userBalance = IAToken(aToken).balanceOf(msg.sender);

        uint256 amountToWithdraw = amount;

        if (amount == type(uint256).max) {
            amountToWithdraw = userBalance;
        }

        ValidationLogic.validateWithdraw(reserve, amountToWithdraw, userBalance);

        reserve.updateState();
        reserve.updateInterestRates(asset, aToken, 0, amountToWithdraw);

        IAToken(aToken).burn(msg.sender, to, amountToWithdraw, reserve.liquidityIndex);

        emit Withdraw(msg.sender, asset, amountToWithdraw, to);

        return amountToWithdraw;
    }

    struct ExecuteBorrowLocalVars {
        address initiator;
        uint256 ltv;
        uint256 liquidationThreshold;
        uint256 liquidationBonus;
        uint256 loanId;
        address reserveOracle;
        address nftOracle;
        address loanAddress;
    }

    /**
     * @dev Allows users to borrow a specific `amount` of the reserve underlying asset
     * - E.g. User borrows 100 USDC, receiving the 100 USDC in his wallet
     *   and lock collateral asset in contract
     * @param asset The address of the underlying asset to borrow
     * @param amount The amount to be borrowed
     * @param nftAsset The address of the underlying nft used as collateral
     * @param nftTokenId The token ID of the underlying nft used as collateral
     * @param onBehalfOf Address of the user who will receive the loan. Should be the address of the borrower itself
     * calling the function if he wants to borrow against his own collateral
     * @param referralCode Code used to register the integrator originating the operation, for potential rewards.
     *   0 if the action is executed directly by the user, without any middle-man
     *
     */
    function borrow(
        address asset,
        uint256 amount,
        address nftAsset,
        uint256 nftTokenId,
        address onBehalfOf,
        uint16 referralCode
    ) external override nonReentrant whenNotPaused {
        _borrow(asset, amount, nftAsset, nftTokenId, onBehalfOf, referralCode);
    }

    function borrowETH(uint256 amount, address nftAsset, uint256 nftTokenId, address onBehalfOf, uint16 referralCode)
        external
        override
        nonReentrant
    {
        _checkValidCallerAndOnBehalfOf(onBehalfOf);
        address loanAddress = _addressesProvider.getLendPoolLoan();
        uint256 loanId = ILendPoolLoan(loanAddress).getCollateralLoanId(nftAsset, nftTokenId);
        if (loanId == 0) {
            IERC721Upgradeable(nftAsset).safeTransferFrom(msg.sender, address(this), nftTokenId);
        }

        _borrow(address(WETH), amount, nftAsset, nftTokenId, onBehalfOf, referralCode);
        WETH.withdraw(amount);
        _safeTransferETH(onBehalfOf, amount);
    }

    function _borrow(
        address asset,
        uint256 amount,
        address nftAsset,
        uint256 nftTokenId,
        address onBehalfOf,
        uint16 referralCode
    ) internal {
        //https://etherscan.io/tx/0x0c41512360a5178b7e52af90b8946238a89eb615571fb459adb6d5d4bea2fda6
        require(onBehalfOf != address(0), Errors.VL_INVALID_ONBEHALFOF_ADDRESS);

        ExecuteBorrowLocalVars memory vars;
        vars.initiator = msg.sender;

        DataTypes.ReserveData storage reserveData = _reserves[asset];
        DataTypes.NftData storage nftData = _nfts[nftAsset];

        // update state MUST BEFORE get borrow amount which is depent on latest borrow index
        reserveData.updateState();

        // Convert asset amount to ETH
        vars.reserveOracle = _addressesProvider.getReserveOracle();
        vars.nftOracle = _addressesProvider.getNFTOracle();
        vars.loanAddress = _addressesProvider.getLendPoolLoan();

        vars.loanId = ILendPoolLoan(vars.loanAddress).getCollateralLoanId(nftAsset, nftTokenId);

        ValidationLogic.validateBorrow(
            onBehalfOf,
            asset,
            amount,
            reserveData,
            nftAsset,
            nftData,
            vars.loanAddress,
            vars.loanId,
            vars.reserveOracle,
            vars.nftOracle
        );

        if (vars.loanId == 0) {
            IERC721Upgradeable(nftAsset).safeTransferFrom(msg.sender, address(this), nftTokenId);

            vars.loanId = ILendPoolLoan(vars.loanAddress).createLoan(
                vars.initiator,
                onBehalfOf,
                nftAsset,
                nftTokenId,
                nftData.bNftAddress,
                asset,
                amount,
                reserveData.variableBorrowIndex
            );
        } else {
            ILendPoolLoan(vars.loanAddress).updateLoan(
                vars.initiator, vars.loanId, amount, 0, reserveData.variableBorrowIndex
            );
        }

        IDebtToken(reserveData.debtTokenAddress).mint(
            vars.initiator, onBehalfOf, amount, reserveData.variableBorrowIndex
        );

        // update interest rate according latest borrow amount (utilizaton)
        reserveData.updateInterestRates(asset, reserveData.aTokenAddress, 0, amount);

        IAToken(reserveData.aTokenAddress).transferUnderlyingTo(vars.initiator, amount);

        emit Borrow(
            vars.initiator,
            asset,
            amount,
            nftAsset,
            nftTokenId,
            onBehalfOf,
            reserveData.currentVariableBorrowRate,
            vars.loanId,
            referralCode
        );
    }

    struct RepayLocalVars {
        address initiator;
        address poolLoan;
        address onBehalfOf;
        uint256 loanId;
        bool isUpdate;
        uint256 borrowAmount;
        uint256 repayAmount;
    }

    /**
     * @notice Repays a borrowed `amount` on a specific reserve, burning the equivalent loan owned
     * - E.g. User repays 100 USDC, burning loan and receives collateral asset
     * @param nftAsset The address of the underlying NFT used as collateral
     * @param nftTokenId The token ID of the underlying NFT used as collateral
     * @param amount The amount to repay
     *
     */
    function repay(address nftAsset, uint256 nftTokenId, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256, bool)
    {
        return _repay(nftAsset, nftTokenId, amount);
    }

    function repayETH(address nftAsset, uint256 nftTokenId, uint256 amount)
        external
        payable
        override
        nonReentrant
        returns (uint256, bool)
    {
        address cachedPoolLoan = _addressesProvider.getLendPoolLoan();
        uint256 loanId = ILendPoolLoan(cachedPoolLoan).getCollateralLoanId(nftAsset, nftTokenId);
        require(loanId > 0, "collateral loan id not exist");

        (address reserveAsset, uint256 repayDebtAmount) =
            ILendPoolLoan(cachedPoolLoan).getLoanReserveBorrowAmount(loanId);
        require(reserveAsset == address(WETH), "loan reserve not WETH");

        if (amount < repayDebtAmount) {
            repayDebtAmount = amount;
        }

        require(msg.value >= repayDebtAmount, "msg.value is less than repay amount");

        WETH.deposit{value: repayDebtAmount}();
        (uint256 paybackAmount, bool burn) = _repay(nftAsset, nftTokenId, amount);

        // refund remaining dust eth
        if (msg.value > repayDebtAmount) {
            _safeTransferETH(msg.sender, msg.value - repayDebtAmount);
        }

        return (paybackAmount, burn);
    }

    function _repay(address nftAsset, uint256 nftTokenId, uint256 amount) internal returns (uint256, bool) {
        //https://etherscan.io/tx/0xf8a9d6eb9840d7c546acde1bf808dc43fbb1d764468bfc6d826e0aff8ab2a955
        RepayLocalVars memory vars;
        vars.initiator = msg.sender;

        vars.poolLoan = _addressesProvider.getLendPoolLoan();

        vars.loanId = ILendPoolLoan(vars.poolLoan).getCollateralLoanId(nftAsset, nftTokenId);
        require(vars.loanId != 0, Errors.LP_NFT_IS_NOT_USED_AS_COLLATERAL);

        DataTypes.LoanData memory loanData = ILendPoolLoan(vars.poolLoan).getLoan(vars.loanId);

        DataTypes.ReserveData storage reserveData = _reserves[loanData.reserveAsset];
        DataTypes.NftData storage nftData = _nfts[loanData.nftAsset];

        // update state MUST BEFORE get borrow amount which is depent on latest borrow index
        reserveData.updateState();

        (, vars.borrowAmount) = ILendPoolLoan(vars.poolLoan).getLoanReserveBorrowAmount(vars.loanId);

        ValidationLogic.validateRepay(reserveData, nftData, loanData, amount, vars.borrowAmount);

        vars.repayAmount = vars.borrowAmount;
        vars.isUpdate = false;
        if (amount < vars.repayAmount) {
            vars.isUpdate = true;
            vars.repayAmount = amount;
        }

        if (vars.isUpdate) {
            ILendPoolLoan(vars.poolLoan).updateLoan(
                vars.initiator, vars.loanId, 0, vars.repayAmount, reserveData.variableBorrowIndex
            );
        } else {
            ILendPoolLoan(vars.poolLoan).repayLoan(
                vars.initiator, vars.loanId, nftData.bNftAddress, vars.repayAmount, reserveData.variableBorrowIndex
            );
        }

        IDebtToken(reserveData.debtTokenAddress).burn(
            loanData.borrower, vars.repayAmount, reserveData.variableBorrowIndex
        );

        // update interest rate according latest borrow amount (utilizaton)
        reserveData.updateInterestRates(loanData.reserveAsset, reserveData.aTokenAddress, vars.repayAmount, 0);

        // transfer repay amount to aToken
        IERC20Upgradeable(loanData.reserveAsset).safeTransferFrom(
            vars.initiator, reserveData.aTokenAddress, vars.repayAmount
        );

        // transfer erc721 to borrower
        if (!vars.isUpdate) {
            IERC721Upgradeable(loanData.nftAsset).safeTransferFrom(address(this), loanData.borrower, nftTokenId);
        }

        emit Repay(
            vars.initiator,
            loanData.reserveAsset,
            vars.repayAmount,
            loanData.nftAsset,
            loanData.nftTokenId,
            loanData.borrower,
            vars.loanId
        );

        return (vars.repayAmount, !vars.isUpdate);
    }

    /**
     * @dev Function to auction a non-healthy position collateral-wise
     * - The bidder want to buy collateral asset of the user getting liquidated
     * @param nftAsset The address of the underlying NFT used as collateral
     * @param nftTokenId The token ID of the underlying NFT used as collateral
     * @param bidPrice The bid price of the bidder want to buy underlying NFT
     * @param onBehalfOf Address of the user who will get the underlying NFT, same as msg.sender if the user
     *   wants to receive them on his own wallet, or a different address if the beneficiary of NFT
     *   is a different wallet
     *
     */
    function auction(address nftAsset, uint256 nftTokenId, uint256 bidPrice, address onBehalfOf)
        external
        override
        nonReentrant
        whenNotPaused
    {
        address poolLiquidator = _addressesProvider.getLendPoolLiquidator();

        //solium-disable-next-line
        (bool success, bytes memory result) = poolLiquidator.delegatecall(
            abi.encodeWithSignature(
                "auction(address,uint256,uint256,address)", nftAsset, nftTokenId, bidPrice, onBehalfOf
            )
        );

        _verifyCallResult(success, result, Errors.LP_DELEGATE_CALL_FAILED);
    }

    /**
     * @notice Redeem a NFT loan which state is in Auction
     * - E.g. User repays 100 USDC, burning loan and receives collateral asset
     * @param nftAsset The address of the underlying NFT used as collateral
     * @param nftTokenId The token ID of the underlying NFT used as collateral
     * @param amount The amount to repay the debt and bid fine
     *
     */
    function redeem(address nftAsset, uint256 nftTokenId, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        address poolLiquidator = _addressesProvider.getLendPoolLiquidator();

        //solium-disable-next-line
        (bool success, bytes memory result) = poolLiquidator.delegatecall(
            abi.encodeWithSignature("redeem(address,uint256,uint256)", nftAsset, nftTokenId, amount)
        );

        bytes memory resultData = _verifyCallResult(success, result, Errors.LP_DELEGATE_CALL_FAILED);

        uint256 repayAmount = abi.decode(resultData, (uint256));

        return (repayAmount);
    }

    /**
     * @dev Function to liquidate a non-healthy position collateral-wise
     * - The caller (liquidator) buy collateral asset of the user getting liquidated, and receives
     *   the collateral asset
     * @param nftAsset The address of the underlying NFT used as collateral
     * @param nftTokenId The token ID of the underlying NFT used as collateral
     *
     */
    function liquidate(address nftAsset, uint256 nftTokenId, uint256 amount)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256)
    {
        address poolLiquidator = _addressesProvider.getLendPoolLiquidator();

        //solium-disable-next-line
        (bool success, bytes memory result) = poolLiquidator.delegatecall(
            abi.encodeWithSignature("liquidate(address,uint256,uint256)", nftAsset, nftTokenId, amount)
        );

        bytes memory resultData = _verifyCallResult(success, result, Errors.LP_DELEGATE_CALL_FAILED);

        uint256 extraAmount = abi.decode(resultData, (uint256));

        return (extraAmount);
    }

    function onERC721Received(address operator, address from, uint256 tokenId, bytes calldata data)
        external
        pure
        override
        returns (bytes4)
    {
        operator;
        from;
        tokenId;
        data;
        return IERC721ReceiverUpgradeable.onERC721Received.selector;
    }

    /**
     * @dev Returns the configuration of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return The configuration of the reserve
     *
     */
    function getReserveConfiguration(address asset)
        external
        view
        override
        returns (DataTypes.ReserveConfigurationMap memory)
    {
        return _reserves[asset].configuration;
    }

    /**
     * @dev Returns the configuration of the NFT
     * @param asset The address of the asset of the NFT
     * @return The configuration of the NFT
     *
     */
    function getNftConfiguration(address asset) external view override returns (DataTypes.NftConfigurationMap memory) {
        return _nfts[asset].configuration;
    }

    /**
     * @dev Returns the normalized income normalized income of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return The reserve's normalized income
     */
    function getReserveNormalizedIncome(address asset) external view override returns (uint256) {
        return _reserves[asset].getNormalizedIncome();
    }

    /**
     * @dev Returns the normalized variable debt per unit of asset
     * @param asset The address of the underlying asset of the reserve
     * @return The reserve normalized variable debt
     */
    function getReserveNormalizedVariableDebt(address asset) external view override returns (uint256) {
        return _reserves[asset].getNormalizedDebt();
    }

    /**
     * @dev Returns the state and configuration of the reserve
     * @param asset The address of the underlying asset of the reserve
     * @return The state of the reserve
     *
     */
    function getReserveData(address asset) external view override returns (DataTypes.ReserveData memory) {
        return _reserves[asset];
    }

    /**
     * @dev Returns the state and configuration of the nft
     * @param asset The address of the underlying asset of the nft
     * @return The state of the nft
     *
     */
    function getNftData(address asset) external view override returns (DataTypes.NftData memory) {
        return _nfts[asset];
    }

    /**
     * @dev Returns the loan data of the NFT
     * @param nftAsset The address of the NFT
     * @param reserveAsset The address of the Reserve
     * @return totalCollateralInETH the total collateral in ETH of the NFT
     * @return totalCollateralInReserve the total collateral in Reserve of the NFT
     * @return availableBorrowsInETH the borrowing power in ETH of the NFT
     * @return availableBorrowsInReserve the borrowing power in Reserve of the NFT
     * @return ltv the loan to value of the user
     * @return liquidationThreshold the liquidation threshold of the NFT
     * @return liquidationBonus the liquidation bonus of the NFT
     *
     */
    function getNftCollateralData(address nftAsset, address reserveAsset)
        external
        view
        override
        returns (
            uint256 totalCollateralInETH,
            uint256 totalCollateralInReserve,
            uint256 availableBorrowsInETH,
            uint256 availableBorrowsInReserve,
            uint256 ltv,
            uint256 liquidationThreshold,
            uint256 liquidationBonus
        )
    {
        DataTypes.NftData storage nftData = _nfts[nftAsset];

        DataTypes.ReserveData storage reserveData = _reserves[reserveAsset];

        (ltv, liquidationThreshold, liquidationBonus) = nftData.configuration.getCollateralParams();

        (totalCollateralInETH, totalCollateralInReserve) = GenericLogic.calculateNftCollateralData(
            reserveAsset,
            reserveData,
            nftAsset,
            nftData,
            _addressesProvider.getReserveOracle(),
            _addressesProvider.getNFTOracle()
        );

        availableBorrowsInETH = GenericLogic.calculateAvailableBorrows(totalCollateralInETH, 0, ltv);
        availableBorrowsInReserve = GenericLogic.calculateAvailableBorrows(totalCollateralInReserve, 0, ltv);
    }

    /**
     * @dev Returns the debt data of the NFT
     * @param nftAsset The address of the NFT
     * @param nftTokenId The token id of the NFT
     * @return loanId the loan id of the NFT
     * @return reserveAsset the address of the Reserve
     * @return totalCollateral the total power of the NFT
     * @return totalDebt the total debt of the NFT
     * @return availableBorrows the borrowing power left of the NFT
     * @return healthFactor the current health factor of the NFT
     *
     */
    function getNftDebtData(address nftAsset, uint256 nftTokenId)
        external
        view
        override
        returns (
            uint256 loanId,
            address reserveAsset,
            uint256 totalCollateral,
            uint256 totalDebt,
            uint256 availableBorrows,
            uint256 healthFactor
        )
    {
        DataTypes.NftData storage nftData = _nfts[nftAsset];

        (uint256 ltv, uint256 liquidationThreshold,) = nftData.configuration.getCollateralParams();

        loanId = ILendPoolLoan(_addressesProvider.getLendPoolLoan()).getCollateralLoanId(nftAsset, nftTokenId);
        if (loanId == 0) {
            return (0, address(0), 0, 0, 0, 0);
        }

        DataTypes.LoanData memory loan = ILendPoolLoan(_addressesProvider.getLendPoolLoan()).getLoan(loanId);

        reserveAsset = loan.reserveAsset;
        DataTypes.ReserveData storage reserveData = _reserves[reserveAsset];

        (, totalCollateral) = GenericLogic.calculateNftCollateralData(
            reserveAsset,
            reserveData,
            nftAsset,
            nftData,
            _addressesProvider.getReserveOracle(),
            _addressesProvider.getNFTOracle()
        );

        (, totalDebt) = GenericLogic.calculateNftDebtData(
            reserveAsset,
            reserveData,
            _addressesProvider.getLendPoolLoan(),
            loanId,
            _addressesProvider.getReserveOracle()
        );

        availableBorrows = GenericLogic.calculateAvailableBorrows(totalCollateral, totalDebt, ltv);

        if (loan.state == DataTypes.LoanState.Active) {
            healthFactor =
                GenericLogic.calculateHealthFactorFromBalances(totalCollateral, totalDebt, liquidationThreshold);
        }
    }

    /**
     * @dev Returns the auction data of the NFT
     * @param nftAsset The address of the NFT
     * @param nftTokenId The token id of the NFT
     * @return loanId the loan id of the NFT
     * @return bidderAddress the highest bidder address of the loan
     * @return bidPrice the highest bid price in Reserve of the loan
     * @return bidBorrowAmount the borrow amount in Reserve of the loan
     * @return bidFine the penalty fine of the loan
     *
     */
    function getNftAuctionData(address nftAsset, uint256 nftTokenId)
        external
        view
        override
        returns (uint256 loanId, address bidderAddress, uint256 bidPrice, uint256 bidBorrowAmount, uint256 bidFine)
    {
        DataTypes.NftData storage nftData = _nfts[nftAsset];

        loanId = ILendPoolLoan(_addressesProvider.getLendPoolLoan()).getCollateralLoanId(nftAsset, nftTokenId);
        if (loanId != 0) {
            DataTypes.LoanData memory loan = ILendPoolLoan(_addressesProvider.getLendPoolLoan()).getLoan(loanId);
            bidderAddress = loan.bidderAddress;
            bidPrice = loan.bidPrice;
            bidBorrowAmount = loan.bidBorrowAmount;
            bidFine = loan.bidPrice.percentMul(nftData.configuration.getRedeemFine());
        }
    }

    struct GetLiquidationPriceLocalVars {
        address poolLoan;
        uint256 loanId;
        uint256 thresholdPrice;
        uint256 liquidatePrice;
        uint256 paybackAmount;
        uint256 remainAmount;
    }

    function getNftLiquidatePrice(address nftAsset, uint256 nftTokenId)
        external
        view
        override
        returns (uint256 liquidatePrice, uint256 paybackAmount)
    {
        GetLiquidationPriceLocalVars memory vars;

        vars.poolLoan = _addressesProvider.getLendPoolLoan();
        vars.loanId = ILendPoolLoan(vars.poolLoan).getCollateralLoanId(nftAsset, nftTokenId);
        if (vars.loanId == 0) {
            return (0, 0);
        }

        DataTypes.LoanData memory loanData = ILendPoolLoan(vars.poolLoan).getLoan(vars.loanId);

        DataTypes.ReserveData storage reserveData = _reserves[loanData.reserveAsset];
        DataTypes.NftData storage nftData = _nfts[nftAsset];

        (vars.paybackAmount, vars.thresholdPrice, vars.liquidatePrice) = GenericLogic.calculateLoanLiquidatePrice(
            vars.loanId,
            loanData.reserveAsset,
            reserveData,
            loanData.nftAsset,
            nftData,
            vars.poolLoan,
            _addressesProvider.getReserveOracle(),
            _addressesProvider.getNFTOracle()
        );

        if (vars.liquidatePrice < vars.paybackAmount) {
            vars.liquidatePrice = vars.paybackAmount;
        }

        return (vars.liquidatePrice, vars.paybackAmount);
    }

    /**
     * @dev Validates and finalizes an aToken transfer
     * - Only callable by the overlying aToken of the `asset`
     * @param asset The address of the underlying asset of the aToken
     * @param from The user from which the aToken are transferred
     * @param to The user receiving the aTokens
     * @param amount The amount being transferred/withdrawn
     * @param balanceFromBefore The aToken balance of the `from` user before the transfer
     * @param balanceToBefore The aToken balance of the `to` user before the transfer
     */
    function finalizeTransfer(
        address asset,
        address from,
        address to,
        uint256 amount,
        uint256 balanceFromBefore,
        uint256 balanceToBefore
    ) external view override whenNotPaused {
        asset;
        from;
        to;
        amount;
        balanceFromBefore;
        balanceToBefore;

        DataTypes.ReserveData storage reserve = _reserves[asset];
        require(msg.sender == reserve.aTokenAddress, Errors.LP_CALLER_MUST_BE_AN_ATOKEN);

        ValidationLogic.validateTransfer(from, reserve);
    }

    /**
     * @dev Returns the list of the initialized reserves
     *
     */
    function getReservesList() external view override returns (address[] memory) {
        address[] memory _activeReserves = new address[](_reservesCount);

        for (uint256 i = 0; i < _reservesCount; i++) {
            _activeReserves[i] = _reservesList[i];
        }
        return _activeReserves;
    }

    /**
     * @dev Returns the list of the initialized nfts
     *
     */
    function getNftsList() external view override returns (address[] memory) {
        address[] memory _activeNfts = new address[](_nftsCount);

        for (uint256 i = 0; i < _nftsCount; i++) {
            _activeNfts[i] = _nftsList[i];
        }
        return _activeNfts;
    }

    /**
     * @dev Set the _pause state of the pool
     * - Only callable by the LendPoolConfigurator contract
     * @param val `true` to pause the pool, `false` to un-pause it
     */
    function setPause(bool val) external override onlyLendPoolConfigurator {
        _paused = val;
        if (_paused) {
            emit Paused();
        } else {
            emit Unpaused();
        }
    }

    /**
     * @dev Returns if the LendPool is paused
     */
    function paused() external view override returns (bool) {
        return _paused;
    }

    /**
     * @dev Returns the cached LendPoolAddressesProvider connected to this contract
     *
     */
    function getAddressesProvider() external view override returns (ILendPoolAddressesProvider) {
        return _addressesProvider;
    }

    function setMaxNumberOfReserves(uint256 val) external override onlyLendPoolConfigurator {
        _maxNumberOfReserves = val;
    }

    /**
     * @dev Returns the maximum number of reserves supported to be listed in this LendPool
     */
    function getMaxNumberOfReserves() public view override returns (uint256) {
        return _maxNumberOfReserves;
    }

    function setMaxNumberOfNfts(uint256 val) external override onlyLendPoolConfigurator {
        _maxNumberOfNfts = val;
    }

    /**
     * @dev Returns the maximum number of nfts supported to be listed in this LendPool
     */
    function getMaxNumberOfNfts() public view override returns (uint256) {
        return _maxNumberOfNfts;
    }

    /**
     * @dev Initializes a reserve, activating it, assigning an aToken and nft loan and an
     * interest rate strategy
     * - Only callable by the LendPoolConfigurator contract
     * @param asset The address of the underlying asset of the reserve
     * @param aTokenAddress The address of the aToken that will be assigned to the reserve
     * @param debtTokenAddress The address of the debtToken that will be assigned to the reserve
     * @param interestRateAddress The address of the interest rate strategy contract
     *
     */
    function initReserve(address asset, address aTokenAddress, address debtTokenAddress, address interestRateAddress)
        external
        override
        onlyLendPoolConfigurator
    {
        require(AddressUpgradeable.isContract(asset), Errors.LP_NOT_CONTRACT);
        _reserves[asset].init(aTokenAddress, debtTokenAddress, interestRateAddress);
        _addReserveToList(asset);
    }

    /**
     * @dev Initializes a nft, activating it, assigning nft loan and an
     * interest rate strategy
     * - Only callable by the LendPoolConfigurator contract
     * @param asset The address of the underlying asset of the nft
     *
     */
    function initNft(address asset, address bNftAddress) external override onlyLendPoolConfigurator {
        require(AddressUpgradeable.isContract(asset), Errors.LP_NOT_CONTRACT);
        _nfts[asset].init(bNftAddress);
        _addNftToList(asset);

        require(_addressesProvider.getLendPoolLoan() != address(0), Errors.LPC_INVALIED_LOAN_ADDRESS);
        IERC721Upgradeable(asset).setApprovalForAll(_addressesProvider.getLendPoolLoan(), true);

        ILendPoolLoan(_addressesProvider.getLendPoolLoan()).initNft(asset, bNftAddress);
    }

    /**
     * @dev Updates the address of the interest rate strategy contract
     * - Only callable by the LendPoolConfigurator contract
     * @param asset The address of the underlying asset of the reserve
     * @param rateAddress The address of the interest rate strategy contract
     *
     */
    function setReserveInterestRateAddress(address asset, address rateAddress)
        external
        override
        onlyLendPoolConfigurator
    {
        _reserves[asset].interestRateAddress = rateAddress;
    }

    /**
     * @dev Sets the configuration bitmap of the reserve as a whole
     * - Only callable by the LendPoolConfigurator contract
     * @param asset The address of the underlying asset of the reserve
     * @param configuration The new configuration bitmap
     *
     */
    function setReserveConfiguration(address asset, uint256 configuration) external override onlyLendPoolConfigurator {
        _reserves[asset].configuration.data = configuration;
    }

    /**
     * @dev Sets the configuration bitmap of the NFT as a whole
     * - Only callable by the LendPoolConfigurator contract
     * @param asset The address of the asset of the NFT
     * @param configuration The new configuration bitmap
     *
     */
    function setNftConfiguration(address asset, uint256 configuration) external override onlyLendPoolConfigurator {
        _nfts[asset].configuration.data = configuration;
    }

    function _addReserveToList(address asset) internal {
        uint256 reservesCount = _reservesCount;

        require(reservesCount < _maxNumberOfReserves, Errors.LP_NO_MORE_RESERVES_ALLOWED);

        bool reserveAlreadyAdded = _reserves[asset].id != 0 || _reservesList[0] == asset;

        if (!reserveAlreadyAdded) {
            _reserves[asset].id = uint8(reservesCount);
            _reservesList[reservesCount] = asset;

            _reservesCount = reservesCount + 1;
        }
    }

    function _addNftToList(address asset) internal {
        uint256 nftsCount = _nftsCount;

        require(nftsCount < _maxNumberOfNfts, Errors.LP_NO_MORE_NFTS_ALLOWED);

        bool nftAlreadyAdded = _nfts[asset].id != 0 || _nftsList[0] == asset;

        if (!nftAlreadyAdded) {
            _nfts[asset].id = uint8(nftsCount);
            _nftsList[nftsCount] = asset;

            _nftsCount = nftsCount + 1;
        }
    }

    function _verifyCallResult(bool success, bytes memory returndata, string memory errorMessage)
        internal
        pure
        returns (bytes memory)
    {
        if (success) {
            return returndata;
        } else {
            // Look for revert reason and bubble it up if present
            if (returndata.length > 0) {
                // The easiest way to bubble the revert reason is using memory via assembly
                assembly {
                    let returndata_size := mload(returndata)
                    revert(add(32, returndata), returndata_size)
                }
            } else {
                revert(errorMessage);
            }
        }
    }

    function _safeTransferETH(address to, uint256 value) internal {
        (bool success,) = to.call{value: value}(new bytes(0));
        require(success, "ETH_TRANSFER_FAILED");
    }
}
