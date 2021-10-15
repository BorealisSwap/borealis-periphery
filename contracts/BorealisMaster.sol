pragma solidity =0.6.6;

import '@borealisswap/borealis-swap-lib/contracts/math/SafeMath.sol';
import '@borealisswap/borealis-swap-lib/contracts/token/ERC20/IERC20.sol';
import '@borealisswap/borealis-swap-lib/contracts/token/ERC20/SafeERC20.sol';
import '@borealisswap/borealis-swap-lib/contracts/access/Ownable.sol';

import './BorealisToken.sol';

contract BorealisMaster is Ownable {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;
    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        //
        // We do some fancy math here. Basically, any point in time, the amount of bores
        // entitled to a user but is pending to be distributed is:
        //
        //   pending reward = (userInfo.amount * pool.accborePerShare) - userInfo.rewardDebt
        //
        // Whenever a user deposits or withdraws LP tokens to a pool. Here's what happens:
        //   1. The pool's `accborePerShare` (and `lastRewardBlock`) gets updated.
        //   2. User receives the pending reward sent to his/her address.
        //   3. User's `amount` gets updated.
        //   4. User's `rewardDebt` gets updated.
    }

    // Info of each pool.
    struct PoolInfo {
        uint256 allocPoint; // How many allocation points assigned to this pool. bores to distribute per block.
        uint256 lastRewardBlock; // Last block number that bores distribution occurs.
        uint256 accborePerShare; // Accumulated bores per share, times 1e12. See below.
        bool exists; //
    }
    // bore tokens created first block.
    uint256 public boreStartBlock;
    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;
    // The block number when bore mining starts.
    uint256 public startBlock;
    // Block number when bonus bore period ends.
    uint256 public bonusEndBlock;
    // how many block size will change the common difference before bonus end.
    uint256 public bonusBeforeBulkBlockSize;
    // how many block size will change the common difference after bonus end.
    uint256 public bonusEndBulkBlockSize;
    // bore tokens created at bonus end block.
    uint256 public boreBonusEndBlock;
    // max reward block
    uint256 public maxRewardBlockNumber;
    // bonus before the common difference
    uint256 public bonusBeforeCommonDifference;
    // bonus after the common difference
    uint256 public bonusEndCommonDifference;
    // Accumulated bores per share, times 1e12.
    uint256 public accborePerShareMultiple = 1E12;
    // The bore TOKEN!
    BorealisToken public bore;
    // Dev address.
    address public devAddr;
    address[] public poolAddresses;
    // Info of each pool.
    mapping(address => PoolInfo) public poolInfoMap;
    // Info of each user that stakes LP tokens.
    mapping(address => mapping(address => UserInfo)) public poolUserInfoMap;

    event Deposit(address indexed user, address indexed poolAddress, uint256 amount);
    event Withdraw(address indexed user, address indexed poolAddress, uint256 amount);
    event EmergencyWithdraw(address indexed user, address indexed poolAddress, uint256 amount);

    constructor(
        BorealisToken _bore,
        address _devAddr,
        uint256 _boreStartBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock,
        uint256 _bonusBeforeBulkBlockSize,
        uint256 _bonusBeforeCommonDifference,
        uint256 _bonusEndCommonDifference
    ) public {
        bore = _bore;
        devAddr = _devAddr;
        boreStartBlock = _boreStartBlock;
        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;
        bonusBeforeBulkBlockSize = _bonusBeforeBulkBlockSize;
        bonusBeforeCommonDifference = _bonusBeforeCommonDifference;
        bonusEndCommonDifference = _bonusEndCommonDifference;
        bonusEndBulkBlockSize = bonusEndBlock.sub(startBlock);
        // bore created when bonus end first block.
        // (boreStartBlock - bonusBeforeCommonDifference * ((bonusEndBlock-startBlock)/bonusBeforeBulkBlockSize - 1)) * bonusBeforeBulkBlockSize*(bonusEndBulkBlockSize/bonusBeforeBulkBlockSize) * bonusEndBulkBlockSize
        boreBonusEndBlock = boreStartBlock
            .sub(bonusEndBlock.sub(startBlock).div(bonusBeforeBulkBlockSize).sub(1).mul(bonusBeforeCommonDifference))
            .mul(bonusBeforeBulkBlockSize)
            .mul(bonusEndBulkBlockSize.div(bonusBeforeBulkBlockSize))
            .div(bonusEndBulkBlockSize);
        // max mint block number, _boreInitBlock - (MAX-1)*_commonDifference = 0
        // MAX = startBlock + bonusEndBulkBlockSize * (_boreInitBlock/_commonDifference + 1)
        maxRewardBlockNumber = startBlock.add(
            bonusEndBulkBlockSize.mul(boreBonusEndBlock.div(bonusEndCommonDifference).add(1))
        );
    }

    // *** POOL MANAGER ***
    function poolLength() external view returns (uint256) {
        return poolAddresses.length;
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(
        uint256 _allocPoint,
        address _pair,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        PoolInfo storage pool = poolInfoMap[_pair];
        require(!pool.exists, 'pool already exists');
        uint256 lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        pool.allocPoint = _allocPoint;
        pool.lastRewardBlock = lastRewardBlock;
        pool.accborePerShare = 0;
        pool.exists = true;
        poolAddresses.push(_pair);
    }

    // Update the given pool's bore allocation point. Can only be called by the owner.
    function set(
        address _pair,
        uint256 _allocPoint,
        bool _withUpdate
    ) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        PoolInfo storage pool = poolInfoMap[_pair];
        require(pool.exists, 'pool not exists');
        totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(_allocPoint);
        pool.allocPoint = _allocPoint;
    }

    function existsPool(address _pair) external view returns (bool) {
        return poolInfoMap[_pair].exists;
    }

    // (_from,_to]
    function getTotalRewardInfoInSameCommonDifference(
        uint256 _from,
        uint256 _to,
        uint256 _boreInitBlock,
        uint256 _bulkBlockSize,
        uint256 _commonDifference
    ) public view returns (uint256 totalReward) {
        if (_to < startBlock || maxRewardBlockNumber <= _from) {
            return 0;
        }
        if (_from < startBlock) {
            _from = startBlock;
        }
        if (maxRewardBlockNumber < _to) {
            _to = maxRewardBlockNumber;
        }
        uint256 currentBulkNumber = _to.sub(startBlock).div(_bulkBlockSize).add(
            _to.sub(startBlock).mod(_bulkBlockSize) > 0 ? 1 : 0
        );
        if (currentBulkNumber < 1) {
            currentBulkNumber = 1;
        }
        uint256 fromBulkNumber = _from.sub(startBlock).div(_bulkBlockSize).add(
            _from.sub(startBlock).mod(_bulkBlockSize) > 0 ? 1 : 0
        );
        if (fromBulkNumber < 1) {
            fromBulkNumber = 1;
        }
        if (fromBulkNumber == currentBulkNumber) {
            return _to.sub(_from).mul(_boreInitBlock.sub(currentBulkNumber.sub(1).mul(_commonDifference)));
        }
        uint256 lastRewardBulkLastBlock = startBlock.add(_bulkBlockSize.mul(fromBulkNumber));
        uint256 currentPreviousBulkLastBlock = startBlock.add(_bulkBlockSize.mul(currentBulkNumber.sub(1)));
        {
            uint256 tempFrom = _from;
            uint256 tempTo = _to;
            totalReward = tempTo
                .sub(tempFrom > currentPreviousBulkLastBlock ? tempFrom : currentPreviousBulkLastBlock)
                .mul(_boreInitBlock.sub(currentBulkNumber.sub(1).mul(_commonDifference)));
            if (lastRewardBulkLastBlock > tempFrom && lastRewardBulkLastBlock <= tempTo) {
                totalReward = totalReward.add(
                    lastRewardBulkLastBlock.sub(tempFrom).mul(
                        _boreInitBlock.sub(fromBulkNumber > 0 ? fromBulkNumber.sub(1).mul(_commonDifference) : 0)
                    )
                );
            }
        }
        {
            // avoids stack too deep errors
            uint256 tempboreInitBlock = _boreInitBlock;
            uint256 tempBulkBlockSize = _bulkBlockSize;
            uint256 tempCommonDifference = _commonDifference;
            if (currentPreviousBulkLastBlock > lastRewardBulkLastBlock) {
                uint256 tempCurrentPreviousBulkLastBlock = currentPreviousBulkLastBlock;
                // sum( [fromBulkNumber+1, currentBulkNumber] )
                // 1/2 * N *( a1 + aN)
                uint256 N = tempCurrentPreviousBulkLastBlock.sub(lastRewardBulkLastBlock).div(tempBulkBlockSize);
                if (N > 1) {
                    uint256 a1 = tempBulkBlockSize.mul(
                        tempboreInitBlock.sub(
                            lastRewardBulkLastBlock.sub(startBlock).mul(tempCommonDifference).div(tempBulkBlockSize)
                        )
                    );
                    uint256 aN = tempBulkBlockSize.mul(
                        tempboreInitBlock.sub(
                            tempCurrentPreviousBulkLastBlock.sub(startBlock).div(tempBulkBlockSize).sub(1).mul(
                                tempCommonDifference
                            )
                        )
                    );
                    totalReward = totalReward.add(N.mul(a1.add(aN)).div(2));
                } else {
                    totalReward = totalReward.add(
                        tempBulkBlockSize.mul(tempboreInitBlock.sub(currentBulkNumber.sub(2).mul(tempCommonDifference)))
                    );
                }
            }
        }
    }

    // Return total reward over the given _from to _to block.
    function getTotalRewardInfo(uint256 _from, uint256 _to) public view returns (uint256 totalReward) {
        if (_to <= bonusEndBlock) {
            totalReward = getTotalRewardInfoInSameCommonDifference(
                _from,
                _to,
                boreStartBlock,
                bonusBeforeBulkBlockSize,
                bonusBeforeCommonDifference
            );
        } else if (_from >= bonusEndBlock) {
            totalReward = getTotalRewardInfoInSameCommonDifference(
                _from,
                _to,
                boreBonusEndBlock,
                bonusEndBulkBlockSize,
                bonusEndCommonDifference
            );
        } else {
            totalReward = getTotalRewardInfoInSameCommonDifference(
                _from,
                bonusEndBlock,
                boreStartBlock,
                bonusBeforeBulkBlockSize,
                bonusBeforeCommonDifference
            )
                .add(
                getTotalRewardInfoInSameCommonDifference(
                    bonusEndBlock,
                    _to,
                    boreBonusEndBlock,
                    bonusEndBulkBlockSize,
                    bonusEndCommonDifference
                )
            );
        }
    }

    // View function to see pending bores on frontend.
    function pendingbore(address _pair, address _user) external view returns (uint256) {
        PoolInfo memory pool = poolInfoMap[_pair];
        if (!pool.exists) {
            return 0;
        }
        UserInfo storage userInfo = poolUserInfoMap[_pair][_user];
        uint256 accborePerShare = pool.accborePerShare;
        uint256 lpSupply = IERC20(_pair).balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0 && pool.lastRewardBlock < maxRewardBlockNumber) {
            uint256 totalReward = getTotalRewardInfo(pool.lastRewardBlock, block.number);
            uint256 boreReward = totalReward.mul(pool.allocPoint).div(totalAllocPoint);
            accborePerShare = accborePerShare.add(boreReward.mul(accborePerShareMultiple).div(lpSupply));
        }
        return userInfo.amount.mul(accborePerShare).div(accborePerShareMultiple).sub(userInfo.rewardDebt);
    }

    // Update reward vairables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolAddresses.length;
        for (uint256 i = 0; i < length; ++i) {
            updatePool(poolAddresses[i]);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(address _pair) public {
        PoolInfo storage pool = poolInfoMap[_pair];
        if (!pool.exists || block.number <= pool.lastRewardBlock) {
            return;
        }
        uint256 lpSupply = IERC20(_pair).balanceOf(address(this));
        if (lpSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }
        if (pool.lastRewardBlock >= maxRewardBlockNumber) {
            return;
        }
        uint256 totalReward = getTotalRewardInfo(pool.lastRewardBlock, block.number);
        uint256 boreReward = totalReward.mul(pool.allocPoint).div(totalAllocPoint);
        bore.mintTo(devAddr, boreReward.div(100));
        bore.mintTo(address(this), boreReward);
        pool.accborePerShare = pool.accborePerShare.add(boreReward.mul(accborePerShareMultiple).div(lpSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to boreryMaster for bore allocation.
    function deposit(address _pair, uint256 _amount) public {
        PoolInfo storage pool = poolInfoMap[_pair];
        UserInfo storage userInfo = poolUserInfoMap[_pair][msg.sender];
        updatePool(_pair);
        if (userInfo.amount > 0) {
            uint256 pending = userInfo.amount.mul(pool.accborePerShare).div(accborePerShareMultiple).sub(
                userInfo.rewardDebt
            );
            if (pending > 0) {
                safeboreTransfer(msg.sender, pending);
            }
        }
        IERC20(_pair).safeTransferFrom(address(msg.sender), address(this), _amount);
        userInfo.amount = userInfo.amount.add(_amount);
        userInfo.rewardDebt = userInfo.amount.mul(pool.accborePerShare).div(accborePerShareMultiple);
        emit Deposit(msg.sender, _pair, _amount);
    }

    // Withdraw LP tokens from boreryMaster.
    function withdraw(address _pair, uint256 _amount) public {
        PoolInfo storage pool = poolInfoMap[_pair];
        UserInfo storage userInfo = poolUserInfoMap[_pair][msg.sender];
        require(userInfo.amount >= _amount, 'withdraw: not good');
        updatePool(_pair);
        uint256 pending = userInfo.amount.mul(pool.accborePerShare).div(accborePerShareMultiple).sub(
            userInfo.rewardDebt
        );
        if (pending > 0) {
            safeboreTransfer(msg.sender, pending);
        }
        if (_amount > 0) {
            userInfo.amount = userInfo.amount.sub(_amount);
            IERC20(_pair).safeTransfer(address(msg.sender), _amount);
        }
        userInfo.rewardDebt = userInfo.amount.mul(pool.accborePerShare).div(accborePerShareMultiple);
        emit Withdraw(msg.sender, _pair, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(address _pair) public {
        UserInfo storage userInfo = poolUserInfoMap[_pair][msg.sender];
        IERC20(_pair).safeTransfer(address(msg.sender), userInfo.amount);
        emit EmergencyWithdraw(msg.sender, _pair, userInfo.amount);
        userInfo.amount = 0;
        userInfo.rewardDebt = 0;
    }

    // Safe bore transfer function, just in case if rounding error causes pool to not have enough bores.
    function safeboreTransfer(address _to, uint256 _amount) internal {
        uint256 boreBal = bore.balanceOf(address(this));
        if (_amount > boreBal) {
            bore.transfer(_to, boreBal);
        } else {
            bore.transfer(_to, _amount);
        }
    }

    // Update dev address by the previous dev.
    function dev(address _devAddr) public {
        require(msg.sender == devAddr, 'dev: wut?');
        devAddr = _devAddr;
    }
}
