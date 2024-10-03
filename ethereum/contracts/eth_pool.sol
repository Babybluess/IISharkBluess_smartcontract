// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import "./IError.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@pythnetwork/pyth-sdk-solidity/IPyth.sol";
import "@pythnetwork/pyth-sdk-solidity/PythStructs.sol";

contract ETHPool is IError {
    IPyth pyth;
    
    address private owner;
    uint16 default_uint = 1000;
    uint16 health_ratio_thread = 1200;
    enum PoolStatus {PENDING, STARTING, ENDING}
    enum LiquidationType {DEPOSITE, REPAY}

    constructor (address pythContract) {
        owner = msg.sender;
        pyth = IPyth(pythContract);
    }

    struct Pool {
        uint8 poolId;
        string name;
        string lend_token_symbol;
        string collateral_token_symbol;
        address creator;
        address borrower;
        uint256 lend_amount;
        uint256 collateral_amount;
        uint256 expire;
        uint8 profit;
        bool isDeleted;
        PoolStatus pool_status;
        ERC20 lend_token;
        ERC20 collateral_token;
    }

    struct NewPool {
        uint8 poolId;
        string name;
        string lend_token_symbol;
        string collateral_token_symbol;
        uint256 lend_amount;
        uint256 expire;
        uint8 profit;
        ERC20 lend_token;
        ERC20 collateral_token;
    }

    /**
     * @dev store pool list
     */
    Pool[] poolList;

    /**
     * @dev store token's balance according to wallet address
     */
    mapping (address => mapping (ERC20 => uint256)) ownBalances; 

    /**
     * @dev only allow owner
     */
    modifier onlyOwner {
        if (owner != msg.sender) {
           revert IsNotOwner();
        }
        _;
    }

    /**
     * @dev pool is not exist
     * @param poolIndex is pool's index in poolList
     */
    modifier isNotExistPool(uint8 poolIndex) {
        if (poolIndex < 0 || poolIndex >= poolList.length) {
            revert IsNotExistPool();
        }
        _;
    }

    event CreatePool(Pool pool, uint256[2] tokenPrice);
    event Borrow(uint8 indexed poolIndex, Pool pool, uint256[2] tokenPrice);
    event EditPool(uint8 indexed poolIndex, Pool pool, uint256 lend_amount, uint8 profit, uint256[2] tokenPrice);
    event CancelPool(uint8 indexed poolIndex, bool isDeleted);
    event Repay(uint8 indexed poolIndex,uint256 balance);
    event WithdrawColateral(IERC20 token, uint8 amount, uint256 balance);
    event Liquidation(uint8 indexed poolIndex, LiquidationType healthRatioStatus, uint256[2] tokenPrice);

    /**
     * @dev create a new pool
     * @param newPool contains information of new pool 
     * @param tokenPrice contains lend and collateral token price
     */
    function createPool(NewPool memory newPool, uint256[2] memory tokenPrice) public {
        uint256[3] memory tokenInfor = [newPool.lend_amount, tokenPrice[0], tokenPrice[1]];
        uint8[2] memory decimals = [newPool.lend_token.decimals(), newPool.collateral_token.decimals()];
        uint256 collateral_amount = calculateCollateral(tokenInfor, decimals);
        
        poolList.push(Pool(
            newPool.poolId,
            newPool.name,
            newPool.lend_token_symbol,
            newPool.collateral_token_symbol,
            msg.sender,
            address(0),
            newPool.lend_amount * newPool.lend_token.decimals(),
            collateral_amount,
            newPool.expire,
            newPool.profit,
            false,
            PoolStatus.PENDING,
            newPool.lend_token,
            newPool.collateral_token
        ));
        uint8 poolIndex = getPoolIndex(newPool.poolId);
        newPool.lend_token.approve(address(this), newPool.lend_amount);

        emit CreatePool(poolList[poolIndex - 1], tokenPrice);
    }

    /**
     * @dev borrow offer in poolList
     * @param poolIndex is pool's index sender borrows
     * @param tokenPrice contains lend and collateral token price
     */
    function borrow(uint8 poolIndex, uint256[2] memory tokenPrice) public payable {
        Pool memory pool = poolList[poolIndex];
        address creator = pool.creator;

        ERC20 lend_token = pool.collateral_token;
        ERC20 collateral_token = pool.lend_token;

        uint256[3] memory tokenInfor = [pool.lend_amount, tokenPrice[0], tokenPrice[1]];
        uint8[2] memory decimals = [pool.lend_token.decimals(), pool.collateral_token.decimals()];
        uint256 collateral_amount = calculateCollateral(tokenInfor, decimals);
        uint256 balance = poolList[poolIndex].collateral_token.balanceOf(msg.sender) * (10 ** pool.collateral_token.decimals());

        if (msg.sender == pool.creator) {
            revert IsCreator();
        }
        if (balance < collateral_amount) {
            revert Isinsufficient();
        }

        ownBalances[creator][collateral_token] += collateral_amount;
        ownBalances[msg.sender][lend_token] += pool.lend_amount;

        poolList[poolIndex].borrower = msg.sender;
        poolList[poolIndex].pool_status = PoolStatus.STARTING;

        emit Borrow(poolIndex, pool, tokenPrice);
    }

    /**
     * @dev edit exist pool
     * @param poolIndex is pool's index creator edit
     * @param lend_amount is token amount of pool borrower can borrow
     * @param profit is interest rate creator receive
     * @param tokenPrice contains lend and collateral token price
     */
    function editPool(uint8 poolIndex, uint256 lend_amount, uint8 profit, uint256[2] memory tokenPrice) public isNotExistPool(poolIndex) {
        Pool memory pool = poolList[poolIndex];

        uint256[3] memory tokenInfor = [pool.lend_amount, tokenPrice[0], tokenPrice[1]];
        uint8[2] memory decimals = [pool.lend_token.decimals(), pool.collateral_token.decimals()];
        uint256 collateral_amount = calculateCollateral(tokenInfor, decimals);
        
        pool.lend_amount = lend_amount * ( 10 ** pool.lend_token.decimals());
        pool.collateral_amount = collateral_amount;
        pool.profit = profit;

        emit EditPool(poolIndex, poolList[poolIndex], lend_amount, profit, tokenPrice);
    }

    /**
     * @dev cancel exist pool
     * @param poolIndex is pool's index creator cancel
     */
    function cancelPool (uint8 poolIndex) public isNotExistPool(poolIndex) {
        poolList[poolIndex].isDeleted = true;

        emit CancelPool(poolIndex, poolList[poolIndex].isDeleted);
    }

    /**
     * @dev borrower repay lend token and profit
     * @param poolIndex is pool's index borrower repaies
     */
    function repay(uint8 poolIndex) public isNotExistPool(poolIndex) {
        address creator = poolList[poolIndex].creator;
        uint256 lend_value = poolList[poolIndex].lend_amount + poolList[poolIndex].lend_amount * poolList[poolIndex].profit / 100;
        
        ERC20 lend_token = poolList[poolIndex].lend_token;
        
        ownBalances[creator][lend_token] += lend_value;
        lend_token.transfer(payable (address(this)), lend_value);
        poolList[poolIndex].pool_status = PoolStatus.ENDING;

        emit Repay(poolIndex, ownBalances[creator][lend_token] );
    }

    /**
     * @dev withdraw token from account balance
     * @param token is token sender withdraws
     * @param amount is token amount sender withdraws
     */
    function withdrawColateral(ERC20 token, uint8 amount) public {
        if (amount > token.balanceOf(msg.sender)) {
            revert Isinsufficient();
        }
        
        payable (msg.sender).transfer(amount * (10 ** token.decimals()));

        emit WithdrawColateral(token, amount, token.balanceOf(msg.sender));
    }

    /**
     * @dev liquidation token if health ratio is less than 1.2 percent
     * @param poolIndex is pool's index 
     * @param healthRatioStatus is flag enum that contains option 1: borrower deposites additional collateral token, option 2: borrower repaies a part of lend token
     * @param tokenPrice contains lend and collateral token price
     */
    function liquidation(uint8 poolIndex, LiquidationType healthRatioStatus, uint256[2] memory tokenPrice) public {
        Pool memory pool = poolList[poolIndex];
        bool isValid = isValidHealthRatio(poolIndex, tokenPrice);

        if (msg.sender != pool.borrower) {
            revert IsNotBorrower();
        }
        
        if (!isValid) {    
            if (healthRatioStatus == LiquidationType.DEPOSITE) {
                uint256 deposite_amount = getAdditionalCollateral(poolIndex, tokenPrice);
                
                ownBalances[pool.creator][pool.collateral_token] += deposite_amount;
                
                pool.collateral_token.transfer(payable (address(this)), deposite_amount);
            } else if (healthRatioStatus == LiquidationType.REPAY) {
                uint256 repay_amount = getRepayLendToken(poolIndex, tokenPrice);

                ownBalances[pool.creator][pool.lend_token] += repay_amount;
                ownBalances[msg.sender][pool.lend_token] -= repay_amount;

                pool.lend_token.transfer(payable (address(this)), repay_amount);
            }
        }

        emit Liquidation(poolIndex, healthRatioStatus, tokenPrice);
    }

    /**
     * @dev get pool's index acorrding to pool's id
     * @param poolId is pool's id
     */
    function getPoolIndex (uint8 poolId) public view returns (uint8 poolIndex) {
        uint8 poolLength = uint8(poolList.length - 1);
        for (uint8 i = 0; i < poolLength; i++) {
            if (poolList[i].poolId == poolId) {
                return i + 1;
            }
        }
    }

    /**
     * @dev check that lending time of pool is expire
     * @param poolIndex is pool's index in poolList
     */
    function expireLendingTime (uint8 poolIndex) public view isNotExistPool(poolIndex) returns (bool) {
        if (poolList[poolIndex].expire < block.timestamp) {
            return false;
        }
        return true;
    }

    /**
     * @dev check that health ratio is greater than 1.2
     * @param poolIndex is pool's index
     * @param tokenPrice contains lend and collateral token price
     */
    function isValidHealthRatio (uint8 poolIndex, uint256[2] memory tokenPrice) public view returns (bool) {
        uint256 lend_value = poolList[poolIndex].lend_amount * tokenPrice[0] / poolList[poolIndex].lend_token.decimals();
        uint256 collateral_value = poolList[poolIndex].collateral_amount * tokenPrice[1] / poolList[poolIndex].collateral_token.decimals();
        
        uint256 health_ratio = collateral_value * default_uint / lend_value;
        if (health_ratio < health_ratio_thread) {
            return false;
        }
        return true;
    }

    /**
     * @dev calculate amount of additional collateral token borrower deposites when health ratio is less than 1.2
     * @param poolIndex is pool's index
     * @param tokenPrice contains lend and collateral token price
     */
    function getAdditionalCollateral (uint8 poolIndex, uint256[2] memory tokenPrice) public view returns (uint256) {
        Pool storage pool = poolList[poolIndex];
        uint256[3] memory tokenInfo = [pool.lend_amount, tokenPrice[0], tokenPrice[1]];
        uint8[2] memory decimals = [pool.lend_token.decimals(), pool.collateral_token.decimals()];

        uint256 validCollateral = calculateCollateral(tokenInfo, decimals);
        uint256 additionalCollateral = validCollateral - pool.collateral_amount;

        return additionalCollateral;
    }
    
    /**
     * @dev calculate amount of lend token borrower repaies when health ratio is less than 1.2
     * @param poolIndex is pool's index
     * @param tokenPrice contains lend and collateral token price 
     */
    function getRepayLendToken (uint8 poolIndex, uint256[2] memory tokenPrice) public view returns (uint256) {
        Pool storage pool = poolList[poolIndex];
        uint256[3] memory tokenInfo = [pool.collateral_amount, tokenPrice[0], tokenPrice[1]];
        uint8[2] memory decimals = [pool.lend_token.decimals(), pool.collateral_token.decimals()];

        uint256 validCollateral = calculateLend(tokenInfo, decimals);
        uint256 additionalCollateral = validCollateral - pool.collateral_amount;

        return additionalCollateral;
    }

    /**
     * @dev get specific pool information in poolList
     * @param poolIndex is pool's index
     */
    function getPool(uint8 poolIndex) public view isNotExistPool(poolIndex) returns (Pool memory) {
        return poolList[poolIndex];
    }

    /**
     * @dev list pool in poolList
     */
    function listPools() public view returns (Pool[] memory) {
        return poolList;
    }

    /**
     * @dev calculate amount of collateral token is valid (health ratio is greater than 1.2)
     * @param tokenInfo: [0] lend_amount, [1] lend_price, [2] collateral_price && decimals: [0] lend_decimals, [1] collateral_decimals
     * @param decimals contain lend and collateral token's decimal
     */
    function calculateCollateral (uint256[3] memory tokenInfo, uint8[2] memory decimals) public view returns (uint256) {
        uint256 collateral_amount = tokenInfo[0] * tokenInfo[2] * ( 10 **  decimals[1]) * health_ratio_thread / tokenInfo[1] / default_uint / ( 10 **  decimals[0]); 
        return collateral_amount;
    }

    /**
     * @dev calculate amount of lend token is valid (health ratio is greater than 1.2)
     * @param tokenInfo: [0] collateral_amount, [1] lend_price, [2] collateral_price && decimals: [0] lend_decimals, [1] collateral_decimals
     * @param decimals contain lend and collateral token's decimal
     */
    function calculateLend (uint256[3] memory tokenInfo, uint8[2] memory decimals) public view returns (uint256) {
        uint256 collateral_amount = tokenInfo[0] * tokenInfo[1] * (10 ** decimals[0]) * health_ratio_thread / tokenInfo[1] / default_uint / (10 ** decimals[1]); 
        return collateral_amount;
    }

    /**
     * @dev get token amount in sender's account 
     * @param token is token sender check
     */
    function getBalance(ERC20 token) public view returns (uint256) {
        return ownBalances[msg.sender][token];
    }
}