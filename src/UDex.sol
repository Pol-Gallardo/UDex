// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {Oracle} from "./Oracle.sol";
import {AggregatorV3Interface} from "@pluginV2/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeCast} from "openzeppelin-contracts/contracts/utils/math/SafeCast.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LibError} from "./lib/LibError.sol";

contract UDex is ERC4626, Ownable, ReentrancyGuard {
    //================================================================================
    // Libraries
    //================================================================================
    using Oracle for uint256;
    using SafeERC20 for IERC20;
    using SafeCast for int256;
    using SafeCast for uint256;

    //================================================================================
    // State Variables
    //================================================================================
    AggregatorV3Interface public immutable i_priceFeed;

    IERC20 public immutable i_xdc;

    PositionsSummary totalLongPositions;
    PositionsSummary totalShortPositions;

    mapping(address => Position) positions;
    uint256 public tradersCollateral;
    uint256 private positionFeeBasisPoints;
    uint256 public s_totalLiquidityDeposited;

    //================================================================================
    // Events
    //================================================================================

    event PositionOpened(
        address indexed user, bool isLong, uint256 collateral, uint256 size, uint256 xdcAmount, uint256 avgXdcPrice
    );

    event PositionDecreased(address indexed user, uint256 collateralDecreased, uint256 sizeDecreased);

    //================================================================================
    // Custom Structs
    //================================================================================
    struct Position {
        uint256 collateral;
        uint256 avgXdcPrice;
        uint256 xdcAmount;
        bool isLong;
        uint256 lastChangeTimestamp;
    }

    struct PositionsSummary {
        uint256 sizeInUsdt;
        uint256 sizeInXdc;
    }

    //================================================================================
    // Constants
    //================================================================================

    uint256 public constant MAX_LEVARAGE = 15;

    constructor(address priceFeed, IERC20 _xdc) ERC4626(_xdc) ERC20("UDex", "UDX") Ownable(msg.sender) {
        i_priceFeed = AggregatorV3Interface(priceFeed);
        i_xdc = IERC20(_xdc);
    }

    //================================================================================
    // Override ERC4626
    //================================================================================

    function totalAssets() public view virtual override returns (uint256) {
        int256 tradersPnL = getTradersPnL();
        if (tradersPnL > 0) {
            return super.totalAssets() - tradersPnL.toUint256() - tradersCollateral;
        }
        tradersPnL = -tradersPnL;
        return super.totalAssets() + tradersPnL.toUint256() - tradersCollateral;
    }

    function deposit(uint256 assets, address receiver) public override nonReentrant returns (uint256 shares) {
        uint256 newTotalLiquidity = s_totalLiquidityDeposited + assets;
        shares = super.deposit(assets, receiver);
        s_totalLiquidityDeposited = newTotalLiquidity;
    }

    function withdraw(uint256 assets, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 shares)
    {
        uint256 newTotalLiquidity = s_totalLiquidityDeposited - assets;
        shares = super.withdraw(assets, receiver, owner);
        s_totalLiquidityDeposited = newTotalLiquidity;
    }

    function mint(uint256 shares, address receiver) public override nonReentrant returns (uint256 assets) {
        assets = super.mint(shares, receiver);
        s_totalLiquidityDeposited += assets;
    }

    function redeem(uint256 shares, address receiver, address owner)
        public
        override
        nonReentrant
        returns (uint256 assets)
    {
        assets = super.redeem(shares, receiver, owner);
        s_totalLiquidityDeposited -= assets;
    }
    //================================================================================
    // Traders functionality
    //================================================================================

    function tryfunction(bool isTrue) public returns (bool) {
        return true;
    }

    function openPosition(uint256 size, uint256 collateral, uint256 currentXDCPrice, bool isLong) public {
        if (collateral <= 0) {
            revert LibError.UDex__ErrorInsufficientCollateral();
        }
        if (size <= 0) {
            revert LibError.UDex__ErrorSize();
        }
        if (positions[msg.sender].collateral != 0) {
            revert LibError.UDex__PositionAlreadyExist();
        }

        /* uint256 currentXDCPrice = getPrice(); */

        //createPosition
        Position memory position = Position({
            avgXdcPrice: currentXDCPrice, //review about decimals precision
            collateral: collateral, //same review
            xdcAmount: size / currentXDCPrice, // review
            isLong: isLong,
            lastChangeTimestamp: block.timestamp
        });
        _checkPositionHealth(position, currentXDCPrice);
        i_xdc.safeTransferFrom(msg.sender, address(this), collateral);

        //contract state
        tradersCollateral += position.collateral;
        positions[msg.sender] = position;
        _increasePositionsSumary(size, position.xdcAmount, isLong); //review decimals

        emit PositionOpened(msg.sender, position.isLong, size, collateral, position.xdcAmount, position.avgXdcPrice);
    }

    /*  */

    //================================================================================
    // Public utility functions
    //================================================================================
    function getPosition(address owner) public view returns (Position memory position) {
        Position memory requestedPosition = positions[owner];
        if (requestedPosition.collateral == 0) {
            revert LibError.UDex__PositionDoesNotExist();
        }
        return positions[owner];
    }

    function getTradersPnL() public view returns (int256) {
        int256 longPnL =
        //  200000e8 xdc   10000usdt
         getUsdtValue(totalLongPositions.sizeInXdc, 1).toInt256() - totalLongPositions.sizeInUsdt.toInt256();

        int256 shortPnL =
            totalShortPositions.sizeInUsdt.toInt256() - getUsdtValue(totalShortPositions.sizeInXdc, 1).toInt256();

        return (shortPnL + longPnL) / 1e18; //REVIEW
    }

    //================================================================================
    // Oracle Price
    //================================================================================
    /* function getPrice() public view returns (uint256) {
        return Oracle.getPrice(i_priceFeed);
    }

    function getUsdtValue(uint256 amount) public view returns (uint256) {
        uint256 usdtValue = amount.getConversionRateinUsdt(i_priceFeed);
        return (usdtValue);
    } */

    function getPrice(uint256 currentXDCPrice) public view returns (uint256) {
        return currentXDCPrice;
    }

    function getUsdtValue(uint256 amount, uint256 currentXDCPrice) public view returns (uint256) {
        uint256 xdcPrice = getPrice(currentXDCPrice);
        uint256 xdcAmountInUsdt = (xdcPrice * amount);
        return xdcAmountInUsdt;
    }
    //================================================================================
    // Internal functions
    //================================================================================

    function _increasePositionsSumary(uint256 sizeInUsdt, uint256 sizeInXdc, bool isLong) internal {
        if (isLong) {
            totalLongPositions.sizeInUsdt += sizeInUsdt;
            totalLongPositions.sizeInXdc += sizeInXdc;
        } else {
            totalShortPositions.sizeInUsdt += sizeInUsdt;
            totalShortPositions.sizeInXdc += sizeInXdc;
        }
    }

    function _decreasePositionsSummary(uint256 sizeInUsdt, uint256 sizeInXdc, bool isLong) internal {
        if (isLong) {
            totalLongPositions.sizeInUsdt -= sizeInUsdt;
            totalLongPositions.sizeInXdc -= sizeInXdc;
        } else {
            totalShortPositions.sizeInUsdt -= sizeInUsdt;
            totalShortPositions.sizeInXdc -= sizeInXdc;
        }
    }

    function _checkPositionHealth(Position memory position, uint256 currentXdcPrice) internal pure {
        int256 positionPnL = _calculatePositionPnL(position, currentXdcPrice);

        if (position.collateral.toInt256() + positionPnL <= 0) {
            revert LibError.UDex__InsufficientPositionCollateral();
        }

        uint256 positionCollateral = (position.collateral.toInt256() + positionPnL).toUint256();

        uint256 levarage = ((position.xdcAmount * position.avgXdcPrice) / positionCollateral); // review

        if (levarage >= MAX_LEVARAGE) {
            revert LibError.UDex__BreaksHealthFactor();
        }
    }

    function _calculatePositionPnL(Position memory position, uint256 currentXdcPrice) internal pure returns (int256) {
        int256 currentPositionValue = (position.xdcAmount * currentXdcPrice).toInt256();
        // 100000 * 0.05 = 5000
        int256 positionValueWhenCreated = (position.xdcAmount * position.avgXdcPrice).toInt256();
        // 100000 * 0.05 = 5000
        if (position.isLong) {
            return (currentPositionValue - positionValueWhenCreated);
        } else {
            return (positionValueWhenCreated - currentPositionValue);
        }
    } // review all function about decimals precision
}
