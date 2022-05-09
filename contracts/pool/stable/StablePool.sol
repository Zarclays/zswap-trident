// SPDX-License-Identifier: GPL-3.0-or-later

pragma solidity >=0.8.0;

import {ERC20} from "@rari-capital/solmate/src/tokens/ERC20.sol";
import {ReentrancyGuard} from "@rari-capital/solmate/src/utils/ReentrancyGuard.sol";

import {IBentoBoxMinimal} from "../../interfaces/IBentoBoxMinimal.sol";
import {IMasterDeployer} from "../../interfaces/IMasterDeployer.sol";
import {IPool} from "../../interfaces/IPool.sol";
import {ITridentCallee} from "../../interfaces/ITridentCallee.sol";
import {IStablePoolFactory} from "../../interfaces/IStablePoolFactory.sol";

import {TridentMath} from "../../libraries/TridentMath.sol";

/// @dev Custom Errors
error ZeroAddress();
error IdenticalAddress();
error InvalidSwapFee();
error InsufficientLiquidityMinted();
error InvalidAmounts();
error InvalidInputToken();
error PoolUninitialized();
error Overflow();

/// @notice Trident exchange pool template with stable swap (solidly exchange) for swapping between tightly correlated assets
/// @dev The reserves are stored as bento shares.
///      The curve is applied to shares as well. This pool does not care about the underlying amounts.

contract StablePool is IPool, ERC20, ReentrancyGuard {
    event Mint(address indexed sender, uint256 amount0, uint256 amount1, address indexed recipient);
    event Burn(address indexed sender, uint256 amount0, uint256 amount1, address indexed recipient);
    event Sync(uint256 reserve0, uint256 reserve1);

    uint256 internal constant MINIMUM_LIQUIDITY = 1000;

    uint256 internal constant MAX_FEE = 10000; // @dev 100%.
    uint256 public immutable swapFee;
    uint256 internal immutable MAX_FEE_MINUS_SWAP_FEE;

    IBentoBoxMinimal public immutable bento;
    IMasterDeployer public immutable masterDeployer;
    address public immutable token0;
    address public immutable token1;

    uint256 public barFee;
    address public barFeeTo;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public kLast;

    uint256 internal reserve0;
    uint256 internal reserve1;
    uint256 internal immutable decimal0;
    uint256 internal immutable decimal1;
    uint32 internal blockTimestampLast;

    bytes32 public constant poolIdentifier = "Trident:StablePool";

    constructor() ERC20("Sushi Stable LP Token", "SSLP", 18) {
        (bytes memory _deployData, IMasterDeployer _masterDeployer) = IStablePoolFactory(msg.sender).getDeployData();

        (address _token0, address _token1, uint256 _swapFee, bool _twapSupport) = abi.decode(
            _deployData,
            (address, address, uint256, bool)
        );

        // Factory ensures that the tokens are sorted.
        if (_token0 == address(0)) revert ZeroAddress();
        if (_token0 == _token1) revert IdenticalAddress();
        if (_swapFee > MAX_FEE) revert InvalidSwapFee();

        token0 = _token0;
        token1 = _token1;
        swapFee = _swapFee;

        // This is safe from underflow - `swapFee` cannot exceed `MAX_FEE` per previous check.
        unchecked {
            MAX_FEE_MINUS_SWAP_FEE = MAX_FEE - _swapFee;
        }

        decimal0 = 10**ERC20(_token0).decimals();
        decimal1 = 10**ERC20(_token0).decimals();

        barFee = _masterDeployer.barFee();
        barFeeTo = _masterDeployer.barFeeTo();
        bento = IBentoBoxMinimal(_masterDeployer.bento());
        masterDeployer = _masterDeployer;
        if (_twapSupport) blockTimestampLast = uint32(block.timestamp);
    }

    /// @dev Mints LP tokens - should be called via the router after transferring `bento` tokens.
    /// The router must ensure that sufficient LP tokens are minted by using the return value.
    function mint(bytes calldata data) public override nonReentrant returns (uint256 liquidity) {
        address recipient = abi.decode(data, (address));
        (uint256 _reserve0, uint256 _reserve1, uint32 _blockTimestampLast) = _getReserves();
        (uint256 balance0, uint256 balance1) = _balance();

        uint256 amount0 = balance0 - _reserve0;
        uint256 amount1 = balance1 - _reserve1;

        uint256 _totalSupply = _mintFee(_reserve0, _reserve1);

        if (_totalSupply == 0) {
            if (amount0 == 0 || amount1 == 0) revert InvalidAmounts();
            liquidity = TridentMath.sqrt(amount0 * amount1) - MINIMUM_LIQUIDITY;
            _mint(address(0), MINIMUM_LIQUIDITY);
        } else {
            liquidity = TridentMath.min((amount0 * _totalSupply) / _reserve0, (amount1 * _totalSupply) / _reserve1);
        }
        if (liquidity == 0) revert InsufficientLiquidityMinted();
        _mint(recipient, liquidity);
        _update(balance0, balance1, _reserve0, _reserve1, _blockTimestampLast);
        kLast = _k(balance0, balance1);
        emit Mint(msg.sender, amount0, amount1, recipient);
    }

    /// @dev Burns LP tokens sent to this contract. The router must ensure that the user gets sufficient output tokens.
    function burn(bytes calldata data) public override nonReentrant returns (TokenAmount[] memory withdrawnAmounts) {
        (address recipient, bool unwrapBento) = abi.decode(data, (address, bool));
        (uint256 _reserve0, uint256 _reserve1, uint32 _blockTimestampLast) = _getReserves();
        (uint256 balance0, uint256 balance1) = _balance();
        uint256 liquidity = balanceOf[address(this)];

        uint256 _totalSupply = _mintFee(_reserve0, _reserve1);

        uint256 amount0 = (liquidity * balance0) / _totalSupply;
        uint256 amount1 = (liquidity * balance1) / _totalSupply;

        _burn(address(this), liquidity);
        _transfer(token0, amount0, recipient, unwrapBento);
        _transfer(token1, amount1, recipient, unwrapBento);
        // This is safe from underflow - amounts are lesser figures derived from balances.
        unchecked {
            balance0 -= amount0;
            balance1 -= amount1;
        }
        _update(balance0, balance1, _reserve0, _reserve1, _blockTimestampLast);
        kLast = _k(balance0, balance1);

        withdrawnAmounts = new TokenAmount[](2);
        withdrawnAmounts[0] = TokenAmount({token: address(token0), amount: amount0});
        withdrawnAmounts[1] = TokenAmount({token: address(token1), amount: amount1});
        emit Burn(msg.sender, amount0, amount1, recipient);
    }

    /// @dev Swaps one token for another. The router must prefund this contract and ensure there isn't too much slippage.
    function swap(bytes calldata data) public override nonReentrant returns (uint256 amountOut) {
        (address tokenIn, address recipient, bool unwrapBento) = abi.decode(data, (address, address, bool));
        (uint256 _reserve0, uint256 _reserve1, uint32 _blockTimestampLast) = _getReserves();
        if (_reserve0 == 0) revert PoolUninitialized();
        (uint256 balance0, uint256 balance1) = _balance();
        uint256 amountIn;
        address tokenOut;
        unchecked {
            if (tokenIn == token0) {
                tokenOut = token1;
                amountIn = balance0 - _reserve0;
                amountOut = _getAmountOut(amountIn, token0, _reserve0, _reserve1);
                balance1 -= amountOut;
            } else {
                if (tokenIn != token1) revert InvalidInputToken();
                tokenOut = token0;
                amountIn = balance1 - reserve1;
                amountOut = _getAmountOut(amountIn, token1, _reserve1, _reserve0);
                balance0 -= amountOut;
            }
        }
        _transfer(tokenOut, amountOut, recipient, unwrapBento);
        _update(balance0, balance1, _reserve0, _reserve1, _blockTimestampLast);
        emit Swap(recipient, tokenIn, tokenOut, amountIn, amountOut);
    }

    /// @dev Updates `barFee` and `barFeeTo` for Trident protocol.
    function updateBarParameters() public {
        barFee = masterDeployer.barFee();
        barFeeTo = masterDeployer.barFeeTo();
    }

    function _getReserves()
        internal
        view
        returns (
            uint256 _reserve0,
            uint256 _reserve1,
            uint32 _blockTimestampLast
        )
    {
        _reserve0 = reserve0;
        _reserve1 = reserve1;
        _blockTimestampLast = blockTimestampLast;
    }

    function _balance() internal view returns (uint256 balance0, uint256 balance1) {
        balance0 = bento.balanceOf(token0, address(this));
        balance1 = bento.balanceOf(token1, address(this));
    }

    function _update(
        uint256 balance0,
        uint256 balance1,
        uint256 _reserve0,
        uint256 _reserve1,
        uint32 _blockTimestampLast
    ) internal {
        if (balance0 > type(uint256).max || balance1 > type(uint256).max) revert Overflow();
        if (_blockTimestampLast == 0) {
            // TWAP support is disabled for gas efficiency.
            reserve0 = balance0;
            reserve1 = balance1;
        } else {
            uint32 blockTimestamp = uint32(block.timestamp);
            if (blockTimestamp != _blockTimestampLast && _reserve0 != 0 && _reserve1 != 0) {
                unchecked {
                    uint32 timeElapsed = blockTimestamp - _blockTimestampLast;
                    price0CumulativeLast += (reserve1 / reserve0) * timeElapsed;
                    price1CumulativeLast += (reserve0 / reserve1) * timeElapsed;
                }
            }

            reserve0 = balance0;
            reserve1 = balance1;
            blockTimestampLast = blockTimestamp;
        }
        emit Sync(balance0, balance1);
    }

    function _mintFee(uint256 _reserve0, uint256 _reserve1) internal returns (uint256 _totalSupply) {
        _totalSupply = totalSupply;
        uint256 _kLast = kLast;
        if (_kLast != 0) {
            uint256 computed = _k(_reserve0, _reserve1);
            if (computed > _kLast) {
                // `barFee` % of increase in liquidity.
                uint256 _barFee = barFee;
                uint256 numerator = _totalSupply * (computed - _kLast) * _barFee;
                uint256 denominator = (MAX_FEE - _barFee) * computed + _barFee * _kLast;
                uint256 liquidity = numerator / denominator;

                if (liquidity != 0) {
                    _mint(barFeeTo, liquidity);
                    _totalSupply += liquidity;
                }
            }
        }
    }

    function _k(uint256 x, uint256 y) internal view returns (uint256) {
        uint256 _x = (x * 1e18) / decimal0;
        uint256 _y = (y * 1e18) / decimal1;
        uint256 _a = (_x * _y) / 1e18;
        uint256 _b = ((_x * _x) / 1e18 + (_y * _y) / 1e18);
        return (_a * _b) / 1e18; // x3y+y3x >= k
    }

    function _f(uint256 x0, uint256 y) internal pure returns (uint256) {
        return (x0 * ((((y * y) / 1e18) * y) / 1e18)) / 1e18 + (((((x0 * x0) / 1e18) * x0) / 1e18) * y) / 1e18;
    }

    function _d(uint256 x0, uint256 y) internal pure returns (uint256) {
        return (3 * x0 * ((y * y) / 1e18)) / 1e18 + ((((x0 * x0) / 1e18) * x0) / 1e18);
    }

    function _get_y(
        uint256 x0,
        uint256 xy,
        uint256 y
    ) internal pure returns (uint256) {
        for (uint256 i = 0; i < 255; i++) {
            uint256 y_prev = y;
            uint256 k = _f(x0, y);
            if (k < xy) {
                uint256 dy = ((xy - k) * 1e18) / _d(x0, y);
                y = y + dy;
            } else {
                uint256 dy = ((k - xy) * 1e18) / _d(x0, y);
                y = y - dy;
            }
            if (y > y_prev) {
                if (y - y_prev <= 1) {
                    return y;
                }
            } else {
                if (y_prev - y <= 1) {
                    return y;
                }
            }
        }
        return y;
    }

    function _getAmountOut(
        uint256 amountIn,
        address tokenIn,
        uint256 _reserve0,
        uint256 _reserve1
    ) internal view returns (uint256) {
        amountIn = (amountIn * MAX_FEE_MINUS_SWAP_FEE) / MAX_FEE;
        uint256 xy = _k(_reserve0, _reserve1);
        _reserve0 = (_reserve0 * 1e18) / decimal0;
        _reserve1 = (_reserve1 * 1e18) / decimal1;
        (uint256 reserveA, uint256 reserveB) = tokenIn == token0 ? (_reserve0, _reserve1) : (_reserve1, _reserve0);
        amountIn = tokenIn == token0 ? (amountIn * 1e18) / decimal0 : (amountIn * 1e18) / decimal1;
        uint256 y = reserveB - _get_y(amountIn + reserveA, xy, reserveB);
        return (y * (tokenIn == token0 ? decimal1 : decimal0)) / 1e18;
    }

    function getAmountOut(bytes calldata data) public view override returns (uint256 finalAmountOut) {
        (address tokenIn, uint256 amountIn) = abi.decode(data, (address, uint256));
        (uint256 _reserve0, uint256 _reserve1, ) = _getReserves();
        finalAmountOut = _getAmountOut(amountIn, tokenIn, _reserve0, _reserve1);
    }

    function _transfer(
        address token,
        uint256 shares,
        address to,
        bool unwrapBento
    ) internal {
        if (unwrapBento) {
            bento.withdraw(token, address(this), to, 0, shares);
        } else {
            bento.transfer(token, address(this), to, shares);
        }
    }

    function getAssets() public view returns (address[] memory assets) {
        assets = new address[](2);
        assets[0] = token0;
        assets[1] = token1;
    }

    /// @dev Returned values are in terms of BentoBox "shares".
    function getReserves()
        public
        view
        returns (
            uint256 _reserve0,
            uint256 _reserve1,
            uint32 _blockTimestampLast
        )
    {
        return _getReserves();
    }

    /// @dev Returned values are the native ERC20 token amounts.
    function getNativeReserves()
        public
        view
        returns (
            uint256 _nativeReserve0,
            uint256 _nativeReserve1,
            uint32 _blockTimestampLast
        )
    {
        (uint256 _reserve0, uint256 _reserve1, uint32 __blockTimestampLast) = _getReserves();
        _nativeReserve0 = bento.toAmount(token0, _reserve0, false);
        _nativeReserve1 = bento.toAmount(token1, _reserve1, false);
        _blockTimestampLast = __blockTimestampLast;
    }

    function burnSingle(bytes calldata data) external override returns (uint256 amountOut) {}

    function flashSwap(bytes calldata data) external override returns (uint256 finalAmountOut) {}

    function getAmountIn(bytes calldata data) external view override returns (uint256 finalAmountIn) {}
}