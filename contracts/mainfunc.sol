// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IUniswapV2Factory {
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}
interface IUniswapV2Router {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB);
}

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import "@openzeppelin/contracts/access/AccessControl.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract mainfunc is ERC20, ERC20Pausable, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // immutable state (set once in constructor)
    IERC20 public token;   // the external token this helper may work with (if needed)
    address public immutable routerAddress;
    IUniswapV2Factory public immutable factory;

    // Constants
    uint256 public constant DECIMALS = 18;
    uint256 public constant MAX_SUPPLY = 1e8 * 1e18;
    uint256 public constant MIN_RESERVE = 1e5 * 1e18;
    uint256 public constant MAX_STAKE_PER_USER = 99999 * 1e18;
    uint256 public constant REWARD_RATE_PER_DAY = 20;
    uint256 public lastMintTime;

    // Configurable Parameters
    uint256 public feePercent = 1; // 1%
    uint256 public rewardRatePerDay = REWARD_RATE_PER_DAY;
    uint256 dailyCap = 500000 * 1e18; 

    // Roles
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant BURNER_ROLE = keccak256("BURNER_ROLE");

    // Staking Data
    mapping(address => uint256) public stakes;
    mapping(address => uint256) public stakeTimestamps;
    mapping(address => uint256) public rewards;
    mapping(address => mapping(uint256 => uint256)) public userDayReward;
    mapping(address => uint256) public claimCooldown;
    // Events
    event Log(address indexed user, uint256 amount);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardClaimed(address indexed user, uint256 amount);
    event AutoMint(uint256 amount);
    event LiquidityAdded(
        address indexed user,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );
    event LiquidityRemoved(
        address indexed user,
        address indexed tokenA,
        address indexed tokenB,
        uint256 amountA,
        uint256 amountB,
        uint256 liquidity
    );
    event FeePercentUpdated(uint256 newFee);
    event RewardRateUpdated(uint256 newRate);


    constructor(
        string memory tokenName,
        string memory tokenSymbol,
        address tokenAddr,
        address routerAddr
    ) ERC20(tokenName, tokenSymbol) {
        require(routerAddr != address(0), "invalid router");
        require(tokenAddr != address(0), "invalid token");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);

        token = IERC20(tokenAddr);
        routerAddress = routerAddr;

        address factoryAddress = address(0xF62c03E08ada871A0bEb309762E260a7a6a880E6);
        factory = IUniswapV2Factory(factoryAddress);
    }

    // === Modifiers ===
    modifier onlyAdmin() {
        require(hasRole(DEFAULT_ADMIN_ROLE, msg.sender), "Not admin");
        _;
    }

    modifier onlyMinter() {
        require(hasRole(MINTER_ROLE, msg.sender), "Not minter");
        _;
    }

    modifier onlyBurner() {
        require(hasRole(BURNER_ROLE, msg.sender), "Not burner");
        _;
    }

    modifier maxSupplyCheck(uint256 amount) {
        require(totalSupply() + amount <= MAX_SUPPLY, "Max supply exceeded");
        _;
    }

    modifier mintCooldown()  {
        require(block.timestamp >= lastMintTime + 5 hours, "cooldown");
        _;
    }

    // Correct override for pausability hooks
    function _update(address from, address to, uint256 value) internal virtual override(ERC20, ERC20Pausable) whenNotPaused {
        super._update(from, to, value);
    }



    // === Core Functions ===
    function mint(address to, uint256 amount) external onlyMinter maxSupplyCheck(amount) whenNotPaused {
        _mint(to, amount);
    }

    function burn(address account, uint256 amount) external onlyBurner whenNotPaused {
        require(balanceOf(account) >= amount, "Insufficient balance");
        _burn(account, amount);
    }

    function myBurn(uint256 amount) external whenNotPaused {
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        _burn(msg.sender, amount);
    }

    // === Transfer Logic (with fee) ===
    function _transferCoin(
        address sender,
        address recipient,
        uint256 amount
    )  internal whenNotPaused {
        require(sender != address(0) && recipient != address(0), "Zero address");

        uint256 feeAmount = (amount * feePercent) / 100;
        uint256 transferAmount = amount - feeAmount;

        if (feeAmount > 0) {
            _transfer(sender, address(this), feeAmount);  // إرسال الرسوم للعقد
        }
        _transfer(sender, recipient, transferAmount);
    }

    function transfer(address recipient, uint256 amount)
        public
        override
        whenNotPaused
        returns (bool)
    {
        _transferCoin(msg.sender, recipient, amount);
        emit Log(msg.sender, amount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override whenNotPaused returns (bool) {
        require(allowance(sender, msg.sender) >= amount, "Insufficient allowance");
        _spendAllowance(sender, msg.sender, amount);
        _transferCoin(sender, recipient, amount);
        return true;
    }

    function approve(address spender, uint256 value) public override whenNotPaused returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    // === Staking Logic ===
    function pendingReward(address user) public view returns (uint256) {
        uint256 staked = stakes[user];
        if (staked == 0 || stakeTimestamps[user] <= 0) return 0;

        uint256 secondsStaked = block.timestamp - stakeTimestamps[user];
        if (secondsStaked <= 0) return 0;

        uint256 rate = rewardRatePerDay;
        if (staked <= 500_000 * 1e18) {
            // safer math, no underflow
            uint256 diff = (500000 * 1e18) - staked;
            rate += (diff * 70) / (500000 * 1e18);
        } else if (staked > 500000 * 1e18 && rate > 5) {
            rate -= 5;
        }

 
        return (staked * rate * secondsStaked) / (1 days * 100);
    }

    function autoMintIfLow() internal mintCooldown {
        uint256 currentBalance = balanceOf(address(this));
        if (currentBalance < MIN_RESERVE) {
            uint256 mintAmount = MIN_RESERVE - currentBalance;
            if (mintAmount > 1e5 * 1e18) mintAmount = 1e5 * 1e18;
            require(totalSupply() + mintAmount <= MAX_SUPPLY, "Max supply reached");
            _mint(address(this), mintAmount);
            lastMintTime = block.timestamp;

            emit AutoMint(mintAmount);
        }
    }

    function updateReward(address user) internal {
        uint256 reward = pendingReward(user);
        uint256 day = block.timestamp / 1 days;

        if (reward > 0) {
            rewards[user] += reward;
            stakeTimestamps[user] = block.timestamp;
            userDayReward[user][day] += reward;
        }
    }

    // === User Functions ===
    function stake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be > 0");
        require(balanceOf(msg.sender) >= amount, "Insufficient balance");
        require(stakes[msg.sender] + amount <= MAX_STAKE_PER_USER, "Max stake exceeded");

        if (balanceOf(address(this)) < amount) {
            autoMintIfLow();
            require(balanceOf(address(this)) >= amount, "Insufficient contract balance");
        }

        if (stakeTimestamps[msg.sender] != 0) {
            updateReward(msg.sender);
        } else {
            stakeTimestamps[msg.sender] = block.timestamp;
        }

        _transfer(msg.sender, address(this), amount);
        stakes[msg.sender] += amount;
        emit Staked(msg.sender, amount);
    }

    function withdrawStake(uint256 amount) external nonReentrant whenNotPaused {
        require(amount > 0, "Amount must be > 0");
        require(stakes[msg.sender] >= amount, "Insufficient staked");

        updateReward(msg.sender);
        stakes[msg.sender] -= amount;

        if (balanceOf(address(this)) < amount) {
            autoMintIfLow();
            require(balanceOf(address(this)) >= amount, "Insufficient contract balance");
        }

        _transfer(address(this), msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    function claimReward() external nonReentrant whenNotPaused {
        uint256 day = block.timestamp / 1 days;
        uint256 available = dailyCap - userDayReward[msg.sender][day];
        updateReward(msg.sender);
        uint256 earned = userDayReward[msg.sender][day];
        require(rewards[msg.sender] > 0, "No reward available");
        require(claimCooldown[msg.sender] <= day, "Claim cooldown active");
        if (earned > available){
            earned = dailyCap;
            rewards[msg.sender] -= dailyCap;
            claimCooldown[msg.sender] = day;
            
        }
        else if (rewards[msg.sender] > userDayReward[msg.sender][day]){
           uint256 oknumber = rewards[msg.sender] - dailyCap; 
           if (oknumber > 0 && rewards[msg.sender] > dailyCap){
               userDayReward[msg.sender][day] -= oknumber;
               rewards[msg.sender] -= oknumber;
               earned = userDayReward[msg.sender][day];
               claimCooldown[msg.sender] = day;

           }else{
               userDayReward[msg.sender][day] = rewards[msg.sender];
               rewards[msg.sender] = 0;
               earned = userDayReward[msg.sender][day];

           
           }
        }
        if (balanceOf(address(this)) < earned) {
            autoMintIfLow();
            require(balanceOf(address(this)) >= earned, "Insufficient contract balance");
        }
        rewards[msg.sender] -= earned; 
        userDayReward[msg.sender][day] -= earned;

        _transfer(address(this), msg.sender, earned);
        emit RewardClaimed(msg.sender, earned);
    }

    // === Admin Functions ===
    function setFeePercent(uint256 newFee) external onlyAdmin {
        require(newFee <= 10, "Fee too high");
        feePercent = newFee;
        emit FeePercentUpdated(newFee);
    }

    function setRewardRate(uint256 newRate) external onlyAdmin {
        rewardRatePerDay = newRate;
        emit RewardRateUpdated(newRate);
    }

    // keep receive rejecting ETH to avoid accidental sends (safe choice)


    // Safe token-token liquidity add (contract must already hold tokenA & tokenB)
    function addLiquidityTokens(
        address tokenA,
        address tokenB,
        uint256 amountTokenA,
        uint256 amountTokenB,
        uint256 minTokenA,
        uint256 minTokenB,
        address to,
        uint256 deadline
    ) external  nonReentrant whenNotPaused onlyAdmin returns (uint256 liquidity) {
        require(block.timestamp <= deadline, "Transaction expired");
        require(amountTokenA > 0 && amountTokenB > 0, "Amounts must be > 0");
        require(minTokenA <= amountTokenA && minTokenB <= amountTokenB, "Invalid min amounts");
        require(to != address(0), "Invalid recipient");

        uint256 beforeA = IERC20(tokenA).balanceOf(address(this));
        uint256 beforeB = IERC20(tokenB).balanceOf(address(this));
        require(beforeA >= amountTokenA && beforeB >= amountTokenB, "Insufficient token balances in contract");

        IERC20(tokenA).safeIncreaseAllowance(routerAddress, amountTokenA);
        IERC20(tokenB).safeIncreaseAllowance(routerAddress, amountTokenB);

        (uint256 actualA, uint256 actualB, uint256 liq) = IUniswapV2Router(routerAddress).addLiquidity(
            tokenA,
            tokenB,
            amountTokenA,
            amountTokenB,
            minTokenA,
            minTokenB,
            to,
            deadline
        );

        require(liq > 0, "Failed to add liquidity");

        uint256 afterA = IERC20(tokenA).balanceOf(address(this));
        uint256 afterB = IERC20(tokenB).balanceOf(address(this));
        require(beforeA - afterA >= actualA - 1, "TokenA transfer shortfall");
        require(beforeB - afterB >= actualB - 1, "TokenB transfer shortfall");

        emit LiquidityAdded(msg.sender, tokenA, tokenB, actualA, actualB, liq);
        return liq;
    }
    function addLiquidityONC(
        address tokenB,
        uint256 amountTokenONC,
        uint256 amountTokenB,
        uint256 minTokenONC,
        uint256 minTokenB,
        address to,
        uint256 deadline
    ) external   nonReentrant whenNotPaused onlyAdmin returns (uint256 liquidity) {
        require(block.timestamp <= deadline, "Transaction expired");
        require(amountTokenONC > 0 && amountTokenB > 0, "Amounts must be > 0");
        require(minTokenONC <= amountTokenONC && minTokenB <= amountTokenB, "Invalid min amounts");
        require(to != address(0), "Invalid recipient");

        uint256 beforeA = IERC20(this).balanceOf(address(this));
        uint256 beforeB = IERC20(tokenB).balanceOf(address(this));
        require(beforeA >= amountTokenONC && beforeB >= amountTokenB, "Insufficient token balances in contract");

        IERC20(this).safeIncreaseAllowance(routerAddress, amountTokenONC);
        IERC20(tokenB).safeIncreaseAllowance(routerAddress, amountTokenB);

        (uint256 actualA, uint256 actualB, uint256 liq) = IUniswapV2Router(routerAddress).addLiquidity(
            address(this),
            tokenB,
            amountTokenONC,
            amountTokenB,
            minTokenONC,
            minTokenB,
            to,
            deadline
        );

        require(liq > 0, "Failed to add liquidity");

        uint256 afterA = IERC20(this).balanceOf(address(this));
        uint256 afterB = IERC20(tokenB).balanceOf(address(this));
        require(beforeA - afterA >= actualA - 1, "TokenA transfer shortfall");
        require(beforeB - afterB >= actualB - 1, "TokenB transfer shortfall");

        emit LiquidityAdded(msg.sender, address(this), tokenB, actualA, actualB, liq);
        return liq;
    }
    // Safe removal between any two ERC20 tokens (admin-only)
    function removeLiquidityTokens(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 minTokenAOut,
        uint256 minTokenBOut,
        address to,
        uint256 deadline

    ) external  nonReentrant whenNotPaused onlyAdmin returns (uint256 amountA, uint256 amountB) {

        require(block.timestamp <= deadline, "Transaction expired");
        require(liquidity > 0, "Zero liquidity");
        require(tokenA != address(0) && tokenB != address(0), "Invalid tokens");
        require(to != address(0), "Invalid recipient");

        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        address pair = factory.getPair(t0, t1);
        require(pair != address(0), "Pair not exists");

        IERC20 lpToken = IERC20(pair);
        uint256 lpBalance = lpToken.balanceOf(address(this));
        require(lpBalance >= liquidity, "Insufficient LP balance");

        // use SafeERC20 to approve (approve-reset pattern)
        lpToken.safeDecreaseAllowance(routerAddress, lpToken.allowance(address(this), routerAddress));
        lpToken.safeIncreaseAllowance(routerAddress, liquidity);
        (amountA, amountB) = IUniswapV2Router(routerAddress).removeLiquidity(
            tokenA,
            tokenB,
            liquidity,
            minTokenAOut,
            minTokenBOut,
            to,
            deadline
        );

        require(amountA >= minTokenAOut, "Received less tokenA than min");
        require(amountB >= minTokenBOut, "Received less tokenB than min");

        emit LiquidityRemoved(to, tokenA, tokenB, amountA, amountB, liquidity);
    }
    function removeLiquidityONC(
        address tokenB,
        uint256 liquidity,
        uint256 minTokenONCOut,
        uint256 minTokenBOut,
        address to,
        uint256 deadline

    ) external nonReentrant whenNotPaused onlyAdmin returns (uint256 amountA, uint256 amountB) {

        require(block.timestamp <= deadline, "Transaction expired");
        require(liquidity > 0, "Zero liquidity");
        require(address(this) != address(0) && tokenB != address(0), "Invalid tokens");
        require(to != address(0), "Invalid recipient");

        (address t0, address t1) = address(this) < tokenB ? (address(this), tokenB) : (tokenB, address(this));
        address pair = factory.getPair(t0, t1);
        require(pair != address(0), "Pair not exists");

        IERC20 lpToken = IERC20(pair);
        uint256 lpBalance = lpToken.balanceOf(address(this));
        require(lpBalance >= liquidity, "Insufficient LP balance");

        // use SafeERC20 to approve (approve-reset pattern)
        lpToken.safeDecreaseAllowance(routerAddress, lpToken.allowance(address(this), routerAddress));
        lpToken.safeIncreaseAllowance(routerAddress, liquidity);
        (amountA, amountB) = IUniswapV2Router(routerAddress).removeLiquidity(
            address(this),
            tokenB,
            liquidity,
            minTokenONCOut,
            minTokenBOut,
            to,
            deadline
        );

        require(amountA >= minTokenONCOut, "Received less tokenA than min");
        require(amountB >= minTokenBOut, "Received less tokenB than min");

        emit LiquidityRemoved(to, address(this), tokenB, amountA, amountB, liquidity);
    }

    // Admin withdraw ETH if any (some router interactions might send ETH)
    function withdrawETH(address to, uint256 amount) external nonReentrant whenNotPaused onlyAdmin {
        require(to != address(0), "invalid to");
        uint256 bal = address(this).balance;
        require(bal >= amount && amount > 0, "Insufficient ETH");
        (bool sent, ) = payable(to).call{value: amount}("");
        require(sent, "ETH transfer failed");
    }

    // Admin withdraw tokens (useful for rescue)
    function withdrawTokens(address _token, uint256 amount) external nonReentrant whenNotPaused onlyAdmin {
        require(_token != address(0), "invalid token");
        require(amount > 0, "Amount must be > 0");
        IERC20(_token).safeTransfer(msg.sender, amount);
    }
    function setDailyCap(uint256 _cap) external onlyAdmin {
        dailyCap = _cap;
    }


}
