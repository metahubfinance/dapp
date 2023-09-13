// SPDX-License-Identifier: BSD 3-Clause

pragma solidity 0.8.9;

import "./libs/zeppelin/token/BEP20/IBEP20.sol";
import "./libs/app/Auth.sol";
import "./interfaces/IMENToken.sol";
import "./interfaces/ICitizen.sol";
import "./interfaces/ILPToken.sol";
import "./interfaces/ITaxManager.sol";
import "./interfaces/INFTPass.sol";
import "./abstracts/BaseContract.sol";
import "./interfaces/IShareManager.sol";
import "./interfaces/ISwap.sol";
import "./interfaces/IVault.sol";

contract Vault is BaseContract {
  struct User {
    uint joinedAt;
    uint balance;
    uint balanceCredited;
    uint refCredited;
    uint deposited;
    uint depositedInUsd;
    uint depositedAndCompounded;
    uint depositedAndCompoundedInUsd;
    uint lastCheckin;
    uint[] claims;
    uint directQualifiedF1;
    uint qualifiedLevel;
    uint autoCompoundExpire;
    bool locked;
    uint totalClaimed;
    mapping (address => bool) levelUpFromF1;
  }
  struct Airdrop {
    uint lastAirdropped;
    uint userUpLineAirdropAmountThisWeek;
    uint userHorizontalAirdropAmountThisWeek;
  }
  struct Transfer {
    uint allowed;
    uint used;
  }
  struct Config {
    uint systemClaimHardCap;
    uint userClaimHardCap;
    uint f1QualifyCheckpoint;
    uint secondsInADay;
    uint minRateClaimCheckpoint;
    uint maxUpLineAirdropAmountPerWeek;
    uint maxHorizontalLineAirdropAmountPerWeek;
    uint maxDepositAmountInUsd;
    uint systemTodayClaimed;
    uint systemLastClaimed;
    uint vestingStartedAt;
    bool pauseAirdrop;
    uint refLevels;
  }
  struct ArrayConfig {
    uint[] refBonusPercentages;
    uint[] interestPercentages;
    uint[2] levelConditions;
  }
  IMENToken public menToken;
  ICitizen public citizen;
  ILPToken public lpToken;
  IShareManager public shareManager;
  ITaxManager public taxManager;
  INFTPass public nftPass;
  IBEP20 public stToken;
  Config public config;
  ArrayConfig private arrayConfig;
  ISwap public swap;
  uint private constant DECIMAL3 = 1000;
  uint private constant DECIMAL9 = 1000000000;
  bool private internalCalling;
  uint constant MAX_USER_LEVEL = 30;
  mapping (address => User) public users;
  mapping (address => Airdrop) public airdropAble;
  mapping (address => Transfer) public transferable;
  mapping (uint => uint) public autoCompoundPrices;
  mapping (address => bool) wlv;
  mapping (address => uint) public userTotalClaimedInUsd;

  event Airdropped(address indexed sender, address receiver, uint amount, uint timestamp);
  event ArrayConfigUpdated(
    uint[] refBonusPercentages,
    uint[] interestPercentages,
    uint[2] levelConditions,
    uint timestamp
  );
  event AutoCompoundBought(address indexed user, uint extraDay, uint newExpireTimestamp, uint price, uint day);
  event AutoCompoundPriceSet(uint day, uint price);
  event BalanceTransferred(address indexed sender, address receiver, uint amount, uint timestamp);
  event Compounded(address indexed user, uint todayReward, uint timestamp);
  event ConfigUpdated(
    uint secondInADay,
    uint maxUpLineAirdropAmountPerWeek,
    uint maxHorizontalLineAirdropAmountPerWeek,
    uint maxDepositAmountInUsd,
    bool pauseAirdrop,
    uint systemClaimHardCap,
    uint userClaimHardCap,
    uint f1QualifyCheckpoint,
    uint refLevels,
    uint timestamp
  );
  event CompoundedFor(address[] users, uint[] todayRewards, bytes32 fingerPrint, uint timestamp);
  event Claimed(address indexed user, uint todayReward, uint timestamp, uint tokenPrice);
  event Deposited(address indexed user, uint amount, uint timestamp, IVault.DepositType depositType, uint tokenPrice);
  event RefBonusSent(address[31] users, uint[31] amounts, uint timestamp, address sender);

  modifier onlyMenToken() {
    require(msg.sender == address(menToken), "Vault: onlyMenToken");
    _;
  }

  function initialize() public initializer {
    BaseContract.init();
    arrayConfig.refBonusPercentages = [0, 300, 100, 100, 100, 50, 50, 50, 50, 50, 10, 10, 10, 10, 10, 10, 10, 10, 10, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5];
    arrayConfig.interestPercentages = [8, 7, 7, 7, 7, 7, 7, 7, 6, 6, 6, 6, 6, 6, 6, 5, 5, 5, 5, 5, 5, 5, 4, 4, 4, 4, 4, 4, 4, 3];
    arrayConfig.levelConditions = [10, 1000];
    config.systemClaimHardCap = 100_000e6;
    config.userClaimHardCap = 1000e6;
    config.f1QualifyCheckpoint = 200e6;
    config.minRateClaimCheckpoint = 22;
    config.secondsInADay = 86_400;
    config.maxDepositAmountInUsd = 5000e6;
    config.refLevels = 30;
  }

  function deposit(uint _amount) external {
    internalCalling = true;
    _takeFundMEN(_amount);
    depositFor(msg.sender, _amount, IVault.DepositType.vaultDeposit);
    internalCalling = false;
  }

  function depositFor(address _userAddress, uint _amount, IVault.DepositType _depositType) public {
    require(internalCalling || msg.sender == address(swap), "Vault: only swap");
    require(citizen.isCitizen(_userAddress), "Vault: Please register first");
    User storage user = users[_userAddress];
    _validateUser(user);
    require(_amount > 0, "Vault: invalid amount");
    uint depositAmountInUsd;
    uint tokenPrice = getTokenPrice();
    depositAmountInUsd = _amount * tokenPrice / DECIMAL9;
    require(user.depositedInUsd + depositAmountInUsd <= config.maxDepositAmountInUsd, "Vault: max deposit reached");
    _checkF1QualifyCheckpoint(user, _userAddress, depositAmountInUsd);
    _increaseDeposit(user, _amount, depositAmountInUsd);
    _increaseBalance(user, _amount * 2, false);
    if (user.joinedAt == 0) {
      user.joinedAt = block.timestamp;
      user.lastCheckin = _getStartOfDayTimestamp();
    }
    _bonusReferral(_userAddress, _amount);
    emit Deposited(_userAddress, _amount * 2, block.timestamp, _depositType, tokenPrice);
  }

  function airdrop(address _userAddress, uint _amount) public {
    require(citizen.isCitizen(msg.sender) && citizen.isCitizen(_userAddress), "Vault: Please register first");
    _resetAirdropStatisticIfNeed();
    User storage sender = users[msg.sender];
    _validateUser(sender);
    uint depositAmountInUsd = _amount * getTokenPrice() / DECIMAL9;
    bool validSender = _validateAndUpdateAirdropStatistic(_userAddress, depositAmountInUsd);
    require(validSender && _amount > 0, "Vault: data invalid");
    _takeFundMEN(_amount);
    User storage user = users[_userAddress];
    require(user.depositedInUsd + depositAmountInUsd <= config.maxDepositAmountInUsd, "Vault: max deposit reached");
    _checkF1QualifyCheckpoint(user, _userAddress, depositAmountInUsd);
    _increaseDeposit(user, _amount, depositAmountInUsd);
    _increaseBalance(user, _amount * 2, false);
    if (user.joinedAt == 0) {
      user.joinedAt = block.timestamp;
    }
    _bonusReferral(_userAddress, _amount);
    emit Airdropped(msg.sender, _userAddress, _amount, block.timestamp);
  }

  function transfer(address _receiver, uint _amount) external {
    require(_receiver != msg.sender, "Vault: receiver invalid");
    require(_amount > 0, "Vault: amount invalid");
    User storage sender = users[msg.sender];
    _validateSenderAndUpdateTransferStatistic(sender, _amount);
    sender.balance -= _amount;

    User storage receiver = users[_receiver];
    _increaseBalance(receiver, _amount, false);
    uint depositAmount = _amount / 2;
    uint depositAmountInUsd = _amount * getTokenPrice() / 2 / DECIMAL9;
    receiver.deposited += depositAmount;
    receiver.depositedAndCompounded += depositAmount;
    receiver.depositedInUsd += depositAmountInUsd;
    receiver.depositedAndCompoundedInUsd += depositAmountInUsd;
    emit BalanceTransferred(msg.sender, _receiver, _amount, block.timestamp);
  }

  function compound() external {
    uint todayReward = _compound(users[msg.sender], msg.sender, false);
    emit Compounded(msg.sender, todayReward, block.timestamp);
  }

  function claim() external {
    User storage user = users[msg.sender];
    require(user.autoCompoundExpire < _getNextDayTimestamp(), "Vault: your auto compound is running");
    uint todayReward = getUserTodayReward(msg.sender);
    _checkin(user);
    require(todayReward > 0, "Vault: no reward");
    _validateClaimCap(user, todayReward);
    _checkMintTokenIfNeeded(todayReward);
    user.balance -= todayReward;
    user.totalClaimed += todayReward;
    uint tokenPrice = getTokenPrice();
    menToken.transfer(msg.sender, todayReward);
    _bonusReferral(msg.sender, todayReward);
    emit Claimed(msg.sender, todayReward, block.timestamp, tokenPrice);
  }

  function buyAutoCompound(uint _days) external payable {
    require(autoCompoundPrices[_days] == msg.value && msg.value > 0, "Vault: data invalid");
    payable(contractCall).transfer(msg.value);
    uint extraDay = config.secondsInADay * _days;
    User storage user = users[msg.sender];
    if (user.autoCompoundExpire == 0 || user.autoCompoundExpire <= block.timestamp) {
      user.autoCompoundExpire = _getNextDayTimestamp() + extraDay;
    } else {
      user.autoCompoundExpire += extraDay;
    }
    emit AutoCompoundBought(msg.sender, extraDay, user.autoCompoundExpire, msg.value, _days);
  }

  function getArrayConfigs() external view returns (uint[] memory, uint[] memory, uint[2] memory) {
    return (arrayConfig.refBonusPercentages, arrayConfig.interestPercentages, arrayConfig.levelConditions);
  }

  function getUserTodayReward(address _userAddress) public view returns (uint) {
    User storage user = users[_userAddress];
    if (user.lastCheckin == _getStartOfDayTimestamp()) {
      return 0;
    }
    uint startTimestampOfPrevious28Day = _getStartOfDayTimestamp() - config.secondsInADay * 28;
    uint userClaimsInPrevious28Day = _getUserClaimSince(user, startTimestampOfPrevious28Day);
    return user.balance * arrayConfig.interestPercentages[userClaimsInPrevious28Day] / DECIMAL3;
  }

  function getUserClaimAndBonusPercentage(address _userAddress) public view returns (uint, uint) {
    uint startTimestampOfPrevious28Day = _getStartOfDayTimestamp() - config.secondsInADay * 28;
    User storage user = users[_userAddress];
    // max out
    if (user.balanceCredited > 0 && user.balanceCredited >= user.depositedAndCompounded * 12) {
      return (0, arrayConfig.interestPercentages[29]);
    }
    uint totalClaims = 0;
    if (user.claims.length > 0) {
      for(uint i = user.claims.length - 1; i > 0; i--) {
        if(user.claims[i] > startTimestampOfPrevious28Day && totalClaims < 28) {
          totalClaims += 1;
        }
      }
      if (user.claims[0] > startTimestampOfPrevious28Day) {
        totalClaims += 1;
      }
    }
    if (startTimestampOfPrevious28Day < user.joinedAt || startTimestampOfPrevious28Day < config.vestingStartedAt) {
      return (totalClaims, arrayConfig.interestPercentages[15]); // default 0.5% for first 28 days
    }
    if (user.claims.length == 0) {
      return (0, arrayConfig.interestPercentages[0]);
    }
    if (user.claims.length == 1) {
      if (user.claims[0] > startTimestampOfPrevious28Day) {
        return (1, arrayConfig.interestPercentages[1]);
      } else {
        return (0, arrayConfig.interestPercentages[0]);
      }
    }
    return (totalClaims, arrayConfig.interestPercentages[totalClaims]);
  }

  function getUserClaims(address _userAddress) external view returns (uint[] memory) {
    return users[_userAddress].claims;
  }

  function getUserAirdropAmountThisWeek(address _userAddress) external view returns (uint, uint) {
    uint startOfWeek = block.timestamp - (block.timestamp - config.vestingStartedAt) % (config.secondsInADay * 7);
    if(airdropAble[_userAddress].lastAirdropped < startOfWeek) {
      return (0, 0);
    }
    return (airdropAble[_userAddress].userUpLineAirdropAmountThisWeek, airdropAble[_userAddress].userHorizontalAirdropAmountThisWeek);
  }

  function getUserInfo(address _userAddress) external view returns (uint, uint) {
    if (_userAddress == addressBook.get("taxManager")) {
      return (999999999e6, userTotalClaimedInUsd[_userAddress]);
    }
    return (users[_userAddress].depositedAndCompounded, userTotalClaimedInUsd[_userAddress]);
  }

  // AUTH FUNCTIONS

  function setAutoCompoundPrice(uint _days, uint _price) external onlyMn {
    autoCompoundPrices[_days] = _price;
    emit AutoCompoundPriceSet(_days, _price);
  }

  function compoundFor(address[] calldata _users, bytes32 _fingerPrint) public onlyContractCall {
    uint[] memory todayRewards = new uint[](_users.length);
    User storage user;
    for(uint i = 0; i < _users.length; i++) {
      user = users[_users[i]];
      require(user.autoCompoundExpire >= _getNextDayTimestamp(), "Vault: user expire");
      todayRewards[i] = _compound(user, _users[i], true);
    }
    emit CompoundedFor(_users, todayRewards, _fingerPrint, block.timestamp);
  }

  function updateQualifiedLevel(address _user1Address, address _user2Address) external {
    address shareAddress = addressBook.get("shareManager");
    if(!(_user1Address == address(0) || _user1Address == shareAddress)) {
      _updateQualifiedLevel(_user1Address, nftPass.balanceOf(_user1Address), stToken.balanceOf(_user1Address));
    }
    if(!(_user2Address == address(0) || _user2Address == shareAddress)) {
      _updateQualifiedLevel(_user2Address, nftPass.balanceOf(_user2Address), stToken.balanceOf(_user2Address));
    }
  }

  function updateConfig(
    uint _secondsInADay,
    uint _maxUpLineAirdropAmountPerWeek,
    uint _maxHorizontalLineAirdropAmountPerWeek,
    uint _maxDepositAmountInUsd,
    bool _isPaused,
    uint _systemClaimHardCap,
    uint _userClaimHardCap,
    uint _f1QualifyCheckpoint,
    uint _refLevels
  ) external onlyMn {
    require(_refLevels > 0 && _refLevels <= 30, "Vault: _refLevels invalid");
    config.secondsInADay = _secondsInADay;
    config.maxUpLineAirdropAmountPerWeek = _maxUpLineAirdropAmountPerWeek;
    config.maxHorizontalLineAirdropAmountPerWeek = _maxHorizontalLineAirdropAmountPerWeek;
    config.maxDepositAmountInUsd = _maxDepositAmountInUsd;
    config.pauseAirdrop = _isPaused;
    config.systemClaimHardCap = _systemClaimHardCap;
    config.userClaimHardCap = _userClaimHardCap;
    config.f1QualifyCheckpoint = _f1QualifyCheckpoint;
    config.refLevels = _refLevels;
    emit ConfigUpdated(
      _secondsInADay,
      _maxUpLineAirdropAmountPerWeek,
      _maxHorizontalLineAirdropAmountPerWeek,
      _maxDepositAmountInUsd,
      _isPaused,
      _systemClaimHardCap,
      _userClaimHardCap,
      _f1QualifyCheckpoint,
      _refLevels,
      block.timestamp
    );
  }

  function updateArrayConfig(
    uint[] calldata _interestPercentages,
    uint[] calldata _refBonusPercentages,
    uint[2] calldata _levelConditions
  ) external onlyMn {
    uint refBonusPercentages;
    for (uint i = 0; i < _refBonusPercentages.length; i++) {
      refBonusPercentages += _refBonusPercentages[i];
    }
    require(refBonusPercentages == 1000, "Vault: refBonusPercentages invalid");
    arrayConfig.interestPercentages = _interestPercentages;
    arrayConfig.refBonusPercentages = _refBonusPercentages;
    arrayConfig.levelConditions = _levelConditions;
    emit ArrayConfigUpdated(_interestPercentages, _refBonusPercentages, _levelConditions, block.timestamp);
  }

  function updateTransfer(address _user, uint _allowed) external onlyMn {
    transferable[_user].allowed = _allowed;
  }

  function startVesting(uint _timestamp) external onlyMn {
    require(_timestamp > block.timestamp && config.vestingStartedAt == 0, "Vault: timestamp must be in the future or vesting had started already");
    config.vestingStartedAt = _timestamp;
  }

  function updateWaitingStatus(address _user, bool _wait) external onlyMn {
    users[_user].locked = _wait;
  }

  function swlv(address _user, bool _wlv) external onlyMn {
    wlv[_user] = _wlv;
  }

  function updateUserTotalClaimedInUSD(address _user, uint _usd) external onlyMenToken {
    userTotalClaimedInUsd[_user] += _usd;
  }

  // PRIVATE FUNCTIONS

  function _increaseBalance(User storage _user, uint _amount, bool _refBonus) private returns (uint) {
    if (_refBonus && _user.deposited == 0) {
      return 0;
    }
    uint increaseAble = _amount;
    if (_user.depositedAndCompounded > 0 && _user.balanceCredited + _amount > (_user.depositedAndCompounded * 12)) {
      increaseAble = _user.depositedAndCompounded * 12 - _user.balanceCredited;
    }
    _user.balance += increaseAble;
    _user.balanceCredited += increaseAble;
    if (_refBonus) {
      _user.refCredited += increaseAble;
    }
    return increaseAble;
  }

  function _increaseDeposit(User storage _user, uint _amount, uint _amountInUsd) private {
    _user.deposited += _amount;
    _user.depositedInUsd += _amountInUsd;
    _user.depositedAndCompounded += _amount;
    _user.depositedAndCompoundedInUsd += _amountInUsd;
  }

  function _checkF1QualifyCheckpoint(User storage _user, address _userAddress, uint _depositAmountInUsd) private {
    if (_user.depositedAndCompoundedInUsd + _depositAmountInUsd >= config.f1QualifyCheckpoint) {
      _increaseInviterDirectQualifiedF1(_userAddress);
    }
  }

  function _checkMintTokenIfNeeded(uint _targetBalance) private {
    uint contractBalance = menToken.balanceOf(address(this));
    if (contractBalance >= _targetBalance) {
      return;
    }
    menToken.releaseMintingAllocation(_targetBalance - contractBalance);
  }

  function _compound(User storage _user, address _userAddress, bool _autoCompound) private returns (uint) {
    if (!_autoCompound) {
      require(_user.autoCompoundExpire < _getNextDayTimestamp(), "Vault: your auto compound is running");
    }
    uint todayReward = getUserTodayReward(_userAddress);
    _checkin(_user);
    uint todayRewardInUsd = todayReward * getTokenPrice() / DECIMAL9;
    _checkF1QualifyCheckpoint(_user, _userAddress, todayRewardInUsd);
    _user.balance += todayReward;
    _user.balanceCredited += todayReward * 2;
    _user.depositedAndCompounded += todayReward;
    _user.depositedAndCompoundedInUsd += todayRewardInUsd;
    _bonusReferral(_userAddress, todayReward);
    return todayReward;
  }

  function _getUserClaimSince(User storage _user, uint _timestamp) private view returns (uint) {
    // max out
    if (_user.balanceCredited > 0 && _user.balanceCredited >= _user.depositedAndCompounded * 12) {
      return 29;
    }
    if (_timestamp < _user.joinedAt || _timestamp < config.vestingStartedAt) {
      return 15; // default 0.5% for first 28 days
    }
    if (_user.claims.length == 0) {
      return 0;
    }
    if (_user.claims.length == 1) {
      if (_user.claims[0] > _timestamp) {
        return 1;
      } else {
        return 0;
      }
    }
    uint totalClaims = 0;
    for(uint i = _user.claims.length - 1; i > 0; i--) {
      if(_user.claims[i] < _timestamp || totalClaims >= config.minRateClaimCheckpoint) {
        return totalClaims;
      }
      totalClaims += 1;
    }
    if (_user.claims.length < config.minRateClaimCheckpoint && _user.claims[0] < _timestamp) {
      totalClaims += 1;
    }
    return totalClaims;
  }

  function _checkin(User storage _user) private {
    require(config.vestingStartedAt > 0, "Vault: please wait for more time");
    require(_user.joinedAt > 0, "Vault: please deposit first");
    _validateUser(_user);
    require(block.timestamp - _user.lastCheckin >= config.secondsInADay, "Vault: please wait more time");
    _user.lastCheckin = _getStartOfDayTimestamp();
  }

  function _bonusReferral(address _userAddress, uint _amount) private {
    address[31] memory refAddresses;
    uint[31] memory refAmounts;
    address inviterAddress;
    address senderAddress = _userAddress;
    uint refBonusAmount;
    uint defaultRefBonusAmount = 0;
    User storage inviter;
    address defaultInviter = citizen.defaultInviter();
    for (uint i = 1; i <= config.refLevels; i++) {
      inviterAddress = citizen.getInviter(_userAddress);
      if (inviterAddress == address(0)) {
        break;
      }
      refBonusAmount = (_amount * arrayConfig.refBonusPercentages[i] / DECIMAL3);
      inviter = users[inviterAddress];
      if (
        (i == 1 || inviter.qualifiedLevel >= i || wlv[inviterAddress]) &&
        (inviterAddress != defaultInviter)
      ) {
        refBonusAmount = _increaseBalance(inviter, refBonusAmount, true);
        if (refBonusAmount > 0) {
          refAddresses[i - 1] = inviterAddress;
          refAmounts[i - 1] = refBonusAmount;
        }
      } else {
        defaultRefBonusAmount += refBonusAmount;
      }
      _userAddress = inviterAddress;
    }
    if (config.refLevels < 30) {
      uint refBonusPercentageLeft;
      for (uint i = 30; i > config.refLevels; i--) {
        refBonusPercentageLeft += arrayConfig.refBonusPercentages[i];
      }
      defaultRefBonusAmount += (_amount * refBonusPercentageLeft / DECIMAL3);
    }
    if (defaultRefBonusAmount > 0) {
      User storage defaultAcc = users[defaultInviter];
      defaultAcc.balance += defaultRefBonusAmount;
      defaultAcc.balanceCredited += defaultRefBonusAmount;
      defaultAcc.refCredited += defaultRefBonusAmount;
      refAddresses[30] = defaultInviter;
      refAmounts[30] = defaultRefBonusAmount;
    }
    emit RefBonusSent(refAddresses, refAmounts, block.timestamp, senderAddress);
  }

  function _increaseInviterDirectQualifiedF1(address _userAddress) private {
    address inviterAddress = _getInviter(_userAddress);
    User storage inviter = users[inviterAddress];
    if (inviter.levelUpFromF1[_userAddress]) {
      return;
    }
    inviter.levelUpFromF1[_userAddress] = true;
    inviter.directQualifiedF1 += 1;
    _updateQualifiedLevel(inviterAddress, nftPass.balanceOf(inviterAddress), stToken.balanceOf(inviterAddress));
  }

  function _updateQualifiedLevel(address _userAddress, uint _nftBalance, uint _stBalance) private {
    (uint nftStocked, uint stStocked) = shareManager.getUserHolding(_userAddress);
    uint nftPoint = (_nftBalance + nftStocked) / arrayConfig.levelConditions[0];
    uint stPoint = (_stBalance + stStocked) / arrayConfig.levelConditions[1] / 1e6;
    User storage user = users[_userAddress];
    uint newLevel = user.directQualifiedF1 + nftPoint + stPoint;
    user.qualifiedLevel = newLevel > MAX_USER_LEVEL
      ? MAX_USER_LEVEL
      : newLevel;
  }

  function _getInviter(address _userAddress) private returns (address) {
    address defaultInviter = citizen.defaultInviter();
    if (_userAddress == defaultInviter) {
      return address(0);
    }
    address inviterAddress = citizen.getInviter(_userAddress);
    if (inviterAddress == address(0)) {
      inviterAddress = defaultInviter;
    }
    return inviterAddress;
  }

  function _takeFundMEN(uint _amount) private {
    require(menToken.allowance(msg.sender, address(this)) >= _amount, "Vault: please call approve function first");
    require(menToken.balanceOf(msg.sender) >= _amount, "Vault: insufficient balance");
    menToken.transferFrom(msg.sender, address(this), _amount);
  }

  function getTokenPrice() public view returns (uint) {
    (uint r0, uint r1) = lpToken.getReserves();
    return r0 * DECIMAL9 / r1;
  }

  function _getNextDayTimestamp() private view returns (uint) {
    return block.timestamp - block.timestamp % config.secondsInADay + config.secondsInADay;
  }

  function _getStartOfDayTimestamp() private view returns (uint) {
    return block.timestamp - block.timestamp % config.secondsInADay;
  }

  function _resetAirdropStatisticIfNeed() private {
    uint startOfWeek = block.timestamp - (block.timestamp - config.vestingStartedAt) % (config.secondsInADay * 7);
    if(airdropAble[msg.sender].lastAirdropped < startOfWeek) {
      delete airdropAble[msg.sender].userUpLineAirdropAmountThisWeek;
      delete airdropAble[msg.sender].userHorizontalAirdropAmountThisWeek;
    }
  }

  function _validateSenderAndUpdateTransferStatistic(User storage _sender, uint _amount) private {
    _validateUser(_sender);
    require(_sender.balance >= _amount, "Vault: insufficient vault balance");
    require(transferable[msg.sender].used + _amount <= transferable[msg.sender].allowed, "Vault: transfer amount exceeded allowance");
    transferable[msg.sender].used += _amount;
  }

  function _validateAndUpdateAirdropStatistic(address _receiverAddress, uint _amount) private returns (bool) {
    if(config.pauseAirdrop) {
      return false;
    }
    Airdrop storage airdropInfo = airdropAble[msg.sender];
    bool isInDownLine = citizen.isSameLine(_receiverAddress, msg.sender);
    if (isInDownLine) {
      airdropInfo.lastAirdropped = block.timestamp;
      return true;
    }
    bool isInUpLine = citizen.isSameLine(msg.sender, _receiverAddress);
    bool valid;
    if (isInUpLine) {
      valid = config.maxUpLineAirdropAmountPerWeek >= (airdropInfo.userUpLineAirdropAmountThisWeek + _amount);
      if(valid) {
        airdropInfo.lastAirdropped = block.timestamp;
        airdropInfo.userUpLineAirdropAmountThisWeek += _amount;
      }
    } else {
      valid = config.maxHorizontalLineAirdropAmountPerWeek >= (airdropInfo.userHorizontalAirdropAmountThisWeek + _amount);
      if (valid) {
        airdropInfo.lastAirdropped = block.timestamp;
        airdropInfo.userHorizontalAirdropAmountThisWeek += _amount;
      }
    }
    return valid;
  }

  function _validateClaimCap(User storage _user, uint _todayReward) private {
    if (config.systemLastClaimed < _getStartOfDayTimestamp()) {
      config.systemTodayClaimed = 0;
    }
    require(config.systemTodayClaimed + _todayReward <= config.systemClaimHardCap, "Vault: system hard cap reached");
    config.systemTodayClaimed += _todayReward;
    config.systemLastClaimed = block.timestamp;

    require(_todayReward <= config.userClaimHardCap, "Vault: user hard cap reached");
    _user.claims.push(block.timestamp);
  }

  function _validateUser(User storage _user) private view {
    require(!_user.locked, "Vault: user is locked");
  }

  function _initDependentContracts() override internal {
    menToken = IMENToken(addressBook.get("menToken"));
    lpToken = ILPToken(addressBook.get("lpToken"));
    shareManager = IShareManager(addressBook.get("shareManager"));
    taxManager = ITaxManager(addressBook.get("taxManager"));
    nftPass = INFTPass(addressBook.get("nftPass"));
    citizen = ICitizen(addressBook.get("citizen"));
    stToken = IBEP20(addressBook.get("stToken"));
    swap = ISwap(addressBook.get("swap"));
  }
}
