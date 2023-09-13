// SPDX-License-Identifier: GPL

pragma solidity 0.8.9;

import "../libs/app/Auth.sol";
import "../interfaces/IAddressBook.sol";

import '@openzeppelin/contracts/token/ERC20/ERC20.sol';
import '../libs/uniswap-core/contracts/FixedPoint96.sol';
import '../libs/uniswap-core/contracts/FullMath.sol';
import '../libs/uniswap-core/contracts/interfaces/IUniswapV3Pool.sol';
import '../libs/uniswap-core/contracts/interfaces/IUniswapV3Factory.sol';

abstract contract BaseContract is Auth {
  using FullMath for uint;

  uint constant DECIMAL12 = 1e12;
  function init() virtual internal {
    Auth.init(msg.sender);
  }

  function convertDecimal18ToDecimal6(uint _amount) internal pure returns (uint) {
    return _amount / DECIMAL12;
  }

  function getTokenPrice(address _poolAddress, uint _tokenInDecimals) internal view returns (uint256 price) {
    IUniswapV3Pool pool = IUniswapV3Pool(_poolAddress);
    (uint160 sqrtPriceX96,,,,,,) =  pool.slot0();
    uint256 numerator1 = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
    uint256 numerator2 = 10 ** _tokenInDecimals;
    return FullMath.mulDiv(numerator1, numerator2, 1 << 192);
  }
}
