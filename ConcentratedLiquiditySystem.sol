// SPDX-License-Identifier: BSD 3-Clause

pragma solidity 0.8.9;

import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "./interfaces/IMENToken.sol";
import "./interfaces/ILPToken.sol";
import "./interfaces/ILSD.sol";
import "./abstracts/BaseContract.sol";

contract ConcentratedLiquiditySystem is BaseContract {
  struct Config {
    uint minTokenReserved;
    uint minUsdtReserved;
  }
  Config public config;
  IMENToken public menToken;
  IBEP20 public usdtToken;
  ILPToken public lpToken;
  address public swapAddress;
  IUniswapV2Router02 public uniswapV2Router;
  uint private constant DECIMAL3 = 1000;
  IBEP20 public usdcToken;
  IBEP20 public daiToken;
  uint private constant DECIMAL9 = 1000000000;
  IBEP20 public stToken;
  ILSD public lsd;
  ILPToken public stLpToken;

  modifier onlySwapContract() {
    require(msg.sender == swapAddress, "ConcentratedLiquiditySystem: only swap contract");
    _;
  }

  event ConfigUpdated(uint minUsdtReserved, uint minTokenReserved, uint timestamp);
  event TokenBought(uint usdtAmount, uint swapedMeh, uint timestamp);
  event TokenSold(uint tokenAmount, uint swapedUsdt, uint timestamp);

  function initialize() public initializer {
    BaseContract.init();
  }

  function swapUSDForToken(uint _usdAmount) external onlySwapContract returns (uint) {
    uint tokenAmount = _usdAmount * DECIMAL9 / _getTokenPrice();
    uint contractBalance = menToken.balanceOf(address(this));
    require(contractBalance >= config.minTokenReserved, "ConcentratedLiquiditySystem: contract insufficient balance");
    if(contractBalance < tokenAmount) {
      menToken.releaseCLSAllocation(tokenAmount - contractBalance);
    }
    menToken.transfer(msg.sender, tokenAmount);
    return tokenAmount;
  }

  function swapTokenForUSDT(address _seller, uint _amount) external onlySwapContract returns (uint) {
    _takeFund(_amount);
    uint usdtAmount = _amount * _getTokenPrice() / DECIMAL9;
    uint contractBalance = usdtToken.balanceOf(address(this));
    require(contractBalance > usdtAmount && contractBalance >= config.minUsdtReserved, "ConcentratedLiquiditySystem: contract insufficient balance");
    usdtToken.transfer(_seller, usdtAmount);
    return usdtAmount;
  }

  // AUTH FUNCTIONS

  function updateConfig(uint _minUsdtReserved, uint _minTokenReserved) external onlyMn {
    config.minUsdtReserved = _minUsdtReserved;
    config.minTokenReserved = _minTokenReserved;
    emit ConfigUpdated(_minUsdtReserved, _minTokenReserved, block.timestamp);
  }

  function buyToken(uint _amount) external onlyContractCall {
    require(usdtToken.balanceOf(address(this)) >= _amount, "ConcentratedLiquiditySystem: contract insufficient balance");
    address[] memory path = new address[](2);
    path[0] = address(usdtToken);
    path[1] = address(menToken);
    uint currentMehBalance = menToken.balanceOf(address(this));

    uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(_amount, 0, path, address(this), block.timestamp);
    uint swappedMeh = menToken.balanceOf(address(this)) - currentMehBalance;
    emit TokenBought(_amount, swappedMeh, block.timestamp);
  }

  function sellToken(uint _amount) external onlyContractCall {
    uint contractBalance = menToken.balanceOf(address(this));
    if (contractBalance < _amount) {
      menToken.releaseCLSAllocation(_amount - contractBalance);
    }
    address[] memory path = new address[](2);
    path[0] = address(menToken);
    path[1] = address(usdtToken);
    uint currentUsdtBalance = usdtToken.balanceOf(address(this));
    uniswapV2Router.swapExactTokensForTokensSupportingFeeOnTransferTokens(_amount, 0, path, address(this), block.timestamp);
    uint swappedUsdt = usdtToken.balanceOf(address(this)) - currentUsdtBalance;
    emit TokenSold(_amount, swappedUsdt, block.timestamp);
  }

  function addLiquidity(uint _usdtAmount, uint _lpTokenBurnPercentage) external onlyContractCall {
    require(_lpTokenBurnPercentage <= 100 * DECIMAL3, "ConcentratedLiquiditySystem: burn percentage invalid");
    require(usdtToken.balanceOf(address(this)) >= _usdtAmount, "ConcentratedLiquiditySystem: contract insufficient usdt balance");
    uint tokenAmount = _usdtAmount * DECIMAL9 / _getTokenPrice();
    uint contractBalance = menToken.balanceOf(address(this));
    if (contractBalance < tokenAmount) {
      menToken.releaseCLSAllocation(tokenAmount - contractBalance);
    }
    uint lpBalanceBefore = lpToken.balanceOf(address(this));
    uniswapV2Router.addLiquidity(
      address(menToken),
      address(usdtToken),
      tokenAmount,
      _usdtAmount,
      0,
      0,
      address(this),
      block.timestamp
    );
    if (_lpTokenBurnPercentage > 0) {
      uint newLPAmount = lpToken.balanceOf(address(this)) - lpBalanceBefore;
      lpToken.transfer(address(0), newLPAmount * _lpTokenBurnPercentage / 100 / DECIMAL3);
    }
  }

  function addMenAndStMenLiquidity(uint _amount) external onlyContractCall {
    require(stToken.balanceOf(address(this)) >= _amount, "ConcentratedLiquiditySystem: insufficient stToken balance");
    uint menTokenBalance = menToken.balanceOf(address(this));
    if (menTokenBalance < _amount) {
      menToken.releaseCLSAllocation(_amount - menTokenBalance);
    }

    uniswapV2Router.addLiquidity(
      address(menToken),
      address(stToken),
        _amount,
        _amount,
      0,
      0,
      address(this),
      block.timestamp
    );
  }

  function removeLiquidity(uint _lpToken) external onlyMn {
    require(_lpToken <= lpToken.balanceOf(address(this)), "ConcentratedLiquiditySystem: contract insufficient balance");
    uniswapV2Router.removeLiquidity(
      address(menToken),
      address(usdtToken),
      _lpToken,
      0,
      0,
      address(this),
      block.timestamp
    );
  }

  function removeLiquidityMenAndStMen(uint _stLpToken) external onlyMn {
    require(_stLpToken <= stLpToken.balanceOf(address(this)), "ConcentratedLiquiditySystem: contract insufficient balance");
    uniswapV2Router.removeLiquidity(
      address(menToken),
      address(stToken),
      _stLpToken,
      0,
      0,
      address(this),
      block.timestamp
    );
  }

  function convertDAIToUsdt(uint _daiAmount) external onlyMn {
    require(daiToken.balanceOf(address(this)) >= _daiAmount, "ConcentratedLiquiditySystem: contract insufficient DAI balance");
    address[] memory path = new address[](2);
    path[0] = address(daiToken);
    path[1] = address(usdtToken);
    uniswapV2Router.swapExactTokensForTokens(_daiAmount, 0, path, address(this), block.timestamp);
  }

  function convertUsdcToUsdt(uint _usdcAmount) external onlyMn {
    require(usdcToken.balanceOf(address(this)) >= _usdcAmount, "ConcentratedLiquiditySystem: contract insufficient USDC balance");
    address[] memory path = new address[](2);
    path[0] = address(usdcToken);
    path[1] = address(usdtToken);
    uniswapV2Router.swapExactTokensForTokens(_usdcAmount, 0, path, address(this), block.timestamp);
  }

  function mint(uint _amount) external onlyMn {
    menToken.releaseCLSAllocation(_amount);
  }

  function mintStMen(uint _tokenAmount, uint _duration) external onlyMn {
    uint menTokenBalance = menToken.balanceOf(address(this));

    if (menTokenBalance < _tokenAmount) {
      menToken.releaseCLSAllocation(_tokenAmount - menTokenBalance);
    }

    lsd.mint(_tokenAmount, _duration);
  }

  function burnStMEN(uint _stAmount) external onlyMn {
    lsd.burn(_stAmount);
  }

  // PRIVATE FUNCTIONS

  function _getTokenPrice() private view returns (uint) {
    (uint r0, uint r1) = ILPToken(addressBook.get("LPToken")).getReserves();
    return r0 * DECIMAL9 / r1;
  }

  function _takeFund(uint _amount) private {
    require(menToken.allowance(msg.sender, address(this)) >= _amount, "ConcentratedLiquiditySystem: allowance invalid");
    require(menToken.balanceOf(msg.sender) >= _amount, "ConcentratedLiquiditySystem: insufficient balance");
    menToken.transferFrom(msg.sender, address(this), _amount);
  }

  function _initDependentContracts() override internal {
    uniswapV2Router = IUniswapV2Router02(addressBook.get("uniswapV2Router"));
    menToken = IMENToken(addressBook.get("menToken"));
    menToken.approve(address(uniswapV2Router), type(uint).max);
    usdtToken = IBEP20(addressBook.get("usdtToken"));
    usdtToken.approve(address(uniswapV2Router), type(uint).max);
    lpToken = ILPToken(addressBook.get("lpToken"));
    lpToken.approve(address(uniswapV2Router), type(uint).max);
    swapAddress = addressBook.get("swap");
    usdcToken = IBEP20(addressBook.get("usdcToken"));
    usdcToken.approve(address(uniswapV2Router), type(uint).max);
    daiToken = IBEP20(addressBook.get("daiToken"));
    daiToken.approve(address(uniswapV2Router), type(uint).max);
    stToken = IBEP20(addressBook.get("stToken"));
    stToken.approve(address(uniswapV2Router), type(uint).max);
    lsd = ILSD(addressBook.get("lsd"));
    menToken.approve(address(lsd), type(uint).max);
    stToken.approve(address(lsd), type(uint).max);
    stLpToken = ILPToken(addressBook.get("stLpToken"));
    stLpToken.approve(address(uniswapV2Router), type(uint).max);
  }
}
